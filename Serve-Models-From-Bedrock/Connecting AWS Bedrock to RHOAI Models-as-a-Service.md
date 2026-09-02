# Connecting AWS Bedrock to RHOAI Models-as-a-Service

**Status: ✅ Verified** on RHOAI 3.5.0 GA with Bedrock Mantle in `us-east-1`.

**Starting point:** a working cluster with RHOAI installed, MaaS enabled, and the MaaS gateway serving. If `curl -sk "${MAAS_GW}/maas-api/health"` does not return `{"status":"healthy"}`, stop and fix that first — nothing below will work.

---

## What you are building

```
analyst  →  MaaS gateway  →  AWS Bedrock
              |
              ├─ Authorino  validates the analyst's key, STRIPS the header
              ├─ Limitador  enforces the token quota
              └─ IPP        injects the AWS credential from a Secret
```

**The analyst's key never reaches AWS. The AWS key never reaches the analyst.** That swap is the entire point of the exercise.

### The object model

3.5 splits connection from presentation. Four resources per model, but the first is shared:

| Resource | Group | Answers |
|---|---|---|
| `ExternalProvider` | `inference.opendatahub.io` | **Where** and **how** to connect — endpoint, credential |
| `ExternalModel` | `inference.opendatahub.io` | **What** clients ask for — maps a friendly name to a provider's model id |
| `MaaSModelRef` | `maas.opendatahub.io` | **Expose** it through the MaaS gateway |
| `MaaSAuthPolicy` + `MaaSSubscription` | `maas.opendatahub.io` | **Who** may call it and **how much** |

One `ExternalProvider` serves every model in that region. Adding a model later is two CRs and two patches — no new AWS credential.

---

# Step 0 — Working variables

```bash
export AWS_REGION="us-east-1"
export MODEL_NS="external-models"
export MAAS_GW="https://maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"

echo "$MAAS_GW"
curl -sk "${MAAS_GW}/maas-api/health"; echo      # {"status":"healthy"}
```

If health fails, the gateway is not ready. Do not continue.

---

# Step 1 — AWS: create a Bedrock API key

## 1a. Pick a Mantle region

RHOAI talks to Bedrock's **OpenAI-compatible** endpoint, `bedrock-mantle.<region>.api.aws` — **not** `bedrock-runtime`. Mantle is not in every region.

Available: US East (N. Virginia, Ohio), US West (Oregon), Asia Pacific (Jakarta, Mumbai, Sydney, Tokyo), Europe (Frankfurt, Ireland, London, Milan, Stockholm), South America (São Paulo).

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models"
# 401 or 403 = endpoint exists, you just have no key yet
# 000 or 404 = wrong region
```

> **Settle data residency before building anything.** This is the question that kills these projects late, not early.

## 1b. Understand the IAM implication

A long-term Bedrock API key is an IAM **service-specific credential**, so it must attach to an IAM **user**. Generating one from the AWS console silently creates a user named `BedrockAPIKey-xxxx`.

Two consequences: it fails outright if an SCP forbids IAM user creation, and a security team will later find the phantom user and ask what it is. Create it deliberately from the CLI instead.

## 1c. Create the user and key

```bash
aws iam create-user --user-name rhoai-maas-bedrock \
  --tags Key=Purpose,Value=RHOAI-MaaS-Gateway Key=Owner,Value=platform-team

aws iam attach-user-policy --user-name rhoai-maas-bedrock \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockLimitedAccess

aws iam create-service-specific-credential \
  --user-name rhoai-maas-bedrock \
  --service-name bedrock.amazonaws.com \
  --credential-age-days 90
```

**The key is the field whose value starts with `ABSK`.** AWS has renamed this field across API versions — you may see `ServiceCredentialSecret`, `ServiceApiKeyValue`, or a legacy `ServicePassword`. **Go by content, not field name.** It is shown once.

## 1d. Capture and validate — do not skip this

```bash
read -rs BEDROCK_API_KEY && export BEDROCK_API_KEY     # paste, Enter; nothing echoes
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4} tail=${BEDROCK_API_KEY: -6}"
```

| Check | Expected | If wrong |
|---|---|---|
| `prefix` | `ABSK` | You copied the wrong field |
| `len` | **132** | **131 or fewer = truncated copy** |
| `tail` | matches the source | Mid-string mangle — re-copy |

> **A 131-character key looks completely legitimate.** Right prefix, plausible length — and AWS rejects it with `permission_denied_error`, which sends you off investigating IAM policies and SCPs for an hour. Check the length first.

Confirm it registered:

```bash
aws iam list-service-specific-credentials \
  --user-name rhoai-maas-bedrock --service-name bedrock.amazonaws.com
```

`Status: Active`. Note the `ServiceSpecificCredentialId` — you need it to reset or delete later. Newly created credentials are not instantly consistent; if a call fails within the first minute, wait and retry.

## 1e. Test from your laptop — before touching OpenShift

If this fails, nothing downstream will work and you will debug the wrong layer.

```bash
# What models are available in this region?
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  | jq -r '.data[] | select(.status=="available") | .id' | sort

export TARGET_MODEL="mistral.mistral-large-3-675b-instruct"

curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${TARGET_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

A successful response has a `choices` array with non-null `message.content`.

| Failure | Meaning |
|---|---|
| `invalid_api_key` / "Invalid bearer token" | **Check the key length first.** Then: wrong field copied, not yet propagated, or an SCP denying `bedrock-mantle:CallWithBearerToken` |
| `403` | IAM policy too narrow, or an SCP blocking Bedrock |
| `404` | Wrong endpoint (`bedrock-runtime` instead of `bedrock-mantle`), or the model is not on Mantle here |
| `400 ... does not support the '/v1/chat/completions' API` | Wrong API for that model family — see the model-choice note below |

> **Choosing a model.** Use `max_tokens: 300`, not 20. Reasoning models emit reasoning tokens before content; with a small budget you get `finish_reason: "length"` and `content: null`, which looks broken but is only truncated.
>
> Prefer a **non-reasoning** model for a first integration — `mistral.mistral-large-3-675b-instruct` answered a three-word greeting in 15 tokens, where `openai.gpt-oss-20b` used 214. The difference muddies any metering story.
>
> **Anthropic models on Mantle reject `/v1/chat/completions`.** They need a different API path that this guide does not resolve. Use an OpenAI-format model.

---

# Step 2 — Namespace

```bash
oc create namespace ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -
oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite
oc get namespace ${MODEL_NS} --show-labels
```

**The label matters.** The MaaS gateway admits namespaces by label; without it the Gateway silently rejects the HTTPRoute — no error, no event, the model simply never becomes reachable.

Confirm your gateway actually selects by label:

```bash
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector}' | jq .
```

If it selects namespaces by **name** rather than by label, add `external-models` to that list instead.

---

# Step 3 — The credential Secret

Three requirements, all mandatory:

1. Same namespace as the `ExternalProvider`
2. Data key exactly **`api-key`**
3. Label **`inference.llm-d.ai/ipp-managed=true`**

```bash
# Re-validate before it goes into the cluster
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"     # 132 / ABSK

oc create secret generic bedrock-api-key \
  --from-literal=api-key="${BEDROCK_API_KEY}" -n ${MODEL_NS}

oc label secret bedrock-api-key -n ${MODEL_NS} \
  inference.llm-d.ai/ipp-managed=true --overwrite
```

> ## ⚠ The label is `inference.llm-d.ai/ipp-managed`
>
> Older community guides say `inference.networking.k8s.io/bbr-managed`. That label is **inert** — the payload processor's credential watcher ignores the Secret, and every inference call fails with:
>
> ```
> HTTP 500  inference error: Internal - authType 'apikey' credentials not found
> ```
>
> No RBAC error, no warning. The `ExternalProvider` still reports `Ready`.

**Confirm the watcher picked it up** — this line must appear within seconds:

```bash
oc logs -n openshift-ingress -l app=payload-processing --since=1m | grep -i 'Secret added'
# "Secret added/updated in store" ... "key":"external-models/bedrock-api-key"
```

If that line is absent, nothing downstream will work. Verify contents:

```bash
oc get secret bedrock-api-key -n ${MODEL_NS} --show-labels
oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' | base64 -d | wc -c   # 132
```

> Use plain `oc create secret`, not `--dry-run | oc apply` — the latter writes the base64 key into a `last-applied-configuration` annotation, exposing it in plaintext to anyone with namespace read access.

---

# Step 4 — ExternalProvider

One provider per region, shared by every model.

```bash
cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
metadata:
  name: bedrock-${AWS_REGION}
  namespace: ${MODEL_NS}
spec:
  provider: aws-bedrock
  endpoint: bedrock-mantle.${AWS_REGION}.api.aws
  auth:
    type: apikey
    secretRef:
      name: bedrock-api-key
EOF

oc get externalprovider -n ${MODEL_NS}
```

Expect `PHASE: Ready`. `spec.endpoint` is the **hostname only** — no scheme, no path.

Check what it created:

```bash
oc get serviceentry,destinationrule,svc -n ${MODEL_NS}
```

You should see an `ExternalName` Service, a `ServiceEntry` (MESH_EXTERNAL) and a `DestinationRule` for TLS origination. The provider owns the network plumbing; the model owns the routing.

> **`Ready` does not mean the credential works.** The CR reports that its resources were created, not that AWS accepted anything. That is proven in Step 8.
>
> **Note on auth type:** Red Hat's documentation specifies `sigv4` for Bedrock, using AWS access keys rather than a bearer token. This guide uses `apikey` with an ABSK key, which is verified working for OpenAI-format models. `sigv4` would remove the long-lived credential entirely and is worth investigating for production.

---

# Step 5 — ExternalModel

```bash
export MODEL_NAME="mistral-large"        # what clients will ask for

cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${MODEL_NAME}
  namespace: ${MODEL_NS}
spec:
  modelName: ${MODEL_NAME}
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: ${TARGET_MODEL}
      weight: 100
EOF

oc get externalmodels.inference.opendatahub.io -n ${MODEL_NS}
```

| Field | Meaning |
|---|---|
| `modelName` | The name clients put in the request body |
| `targetModel` | The provider's own model id |
| `apiFormat` | `openai-chat` for `/v1/chat/completions`; `messages` for Anthropic's API |
| `path` | The outgoing request path sent to the provider |
| `weight` | Traffic split when several providers back one model name |

`externalProviderRefs` is an array, so one client-facing name can fan out across regions or vendors with no client change.

> Two CRDs share the name `externalmodels`. Use the fully-qualified `externalmodels.inference.opendatahub.io`; the `maas.opendatahub.io` one is legacy.

## Verify the route attached

```bash
oc get httproute ${MODEL_NAME} -n ${MODEL_NS} \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
```

Want:

```
Accepted=True
ResolvedRefs=True
kuadrant.io/AuthPolicyAffected=True
kuadrant.io/TokenRateLimitPolicyAffected=True
```

`Accepted=False` almost always means the namespace label from Step 2 is missing. The two Kuadrant conditions confirm Authorino and Limitador attached — if `AuthPolicyAffected` is absent, the endpoint may be unprotected.

---

# Step 6 — ⚠ Patch the generated HTTPRoute

**Required. Without this every request returns `404 route_not_found`.**

The controller generates a catch-all rule matching header `X-Gateway-Model-Name` against **`targetModel`**. But the pre-processing filter sets that header from the request body's `model` field, which is **`modelName`**. They never match.

```bash
oc patch httproute ${MODEL_NAME} -n ${MODEL_NS} --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/3/matches/0/headers/0/value\",\"value\":\"${MODEL_NAME}\"}]"

oc get httproute ${MODEL_NAME} -n ${MODEL_NS} \
  -o jsonpath='{.spec.rules[3].matches[0].headers[0].value}'; echo    # must equal $MODEL_NAME
```

Confirm rule 3 is the right index first if the layout differs:

```bash
oc get httproute ${MODEL_NAME} -n ${MODEL_NS} -o jsonpath='{.spec.rules}' \
  | python3 -m json.tool | grep -n 'X-Gateway-Model-Name' -A2
```

> ## This patch does not persist
>
> It is reverted by the operator. Observed triggers:
>
> - **Time** — held one hour, reverted within 24
> - **Any DSCI or DSC change** — reverted within ~60 seconds
> - **Operator installs**
>
> **Re-apply and re-verify before any demo, and after any platform change.** A working system breaks with no action from you, and nothing links the cause to the effect.

---

# Step 7 — MaaSModelRef, policy and subscription

## 7a. Expose the model

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${MODEL_NAME}
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${MODEL_NAME}
EOF

oc get maasmodelref -n ${MODEL_NS}
```

**Expect `PHASE: Pending` with an empty ENDPOINT.** That is correct and it will not clear on its own:

```bash
oc describe maasmodelref ${MODEL_NAME} -n ${MODEL_NS} | grep -A3 Conditions
```

```
GovernanceAttached  False  NoPairingFound   "No active subscription and auth policy pairing found"
RuntimeReady        True   RuntimeHealthy   "Backend is healthy"
Ready               False  BackendNotReady  "Awaiting governance pairing"
```

**MaaS refuses to expose a model until both an auth policy and a subscription reference it.** Ungoverned exposure is not possible by construction — a good line for the customer conversation.

`RuntimeReady: True` is the useful signal here: it means your provider, Secret and endpoint are all correct. If it is `False`, fix Steps 3–4 before touching governance.

## 7b. Who may call it, and how much

These live in the **`models-as-a-service`** namespace.

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: bedrock-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
  subjects:
    groups:
      - name: "system:authenticated"
  meteringMetadata:
    costCenter: "demo-cc"
    organizationId: "demo-org"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: analysts-standard
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: "system:authenticated"
  priority: 100
  tokenMetadata:
    costCenter: "analysts"
    organizationId: "demo-org"
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100000
          window: "1h"
EOF

sleep 20
oc get maasauthpolicy,maassubscription -n models-as-a-service      # PHASE Active
oc get maasmodelref -n ${MODEL_NS}                                  # now Ready, ENDPOINT populated
```

- **`MaaSAuthPolicy`** — *who may call*, enforced by Authorino
- **`MaaSSubscription`** — *how many tokens*, enforced by Limitador

For production, replace `system:authenticated` with real groups and create one subscription per department, each with its own `costCenter`. That is your chargeback boundary.

---

# Step 8 — Test it end to end

## 8a. Get an OpenShift token

The MaaS admin API sits behind an auth proxy, so certificate-based kubeconfig auth is not enough.

```bash
oc whoami -t || echo "no token — oc login -u <user> -p <password>, or console → Copy login command → Display Token"
```

> **Two different credentials.** The OpenShift token authenticates *you* to the MaaS admin API. The MaaS API key it returns is what an *analyst* uses to call models.

## 8b. Catalogue and key

```bash
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" \
  | jq -r '.data[] | "\(.id)  ready=\(.ready)  subs=\([.subscriptions[].name]|join(","))"'

API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"demo-key","subscription":"analysts-standard","expiresIn":"24h"}' | jq -r '.key')
echo "${API_KEY:0:12}..."
```

## 8c. Inference

**Call the gateway root with the model in the body — OpenAI style.**

```bash
curl -sk -m 120 "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

Expected shape:

```json
{"choices":[{"finish_reason":"stop","message":{"content":"Hey there, friend!","role":"assistant"}}],
 "model":"mistral.mistral-large-3-675b-instruct",
 "usage":{"prompt_tokens":68,"completion_tokens":45,"total_tokens":113}}
```

`model` in the response is the **targetModel** — proof the gateway substituted it. `usage.total_tokens` is what gets metered.

> **Do not use `${MAAS_GW}/<namespace>/<model>/v1/chat/completions`.** It routes to AWS but delivers the full path prefix, and Bedrock returns 404 — recognisable by an `x-amzn-requestid` header on the response.

## 8d. Stability

```bash
for i in $(seq 1 6); do
  curl -sk -o /dev/null -w "call $i: %{http_code} in %{time_total}s\n" -m 60 \
    "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}"
done
```

Want six 200s around 1s each.

> **Intermittent 503s mean a stale gateway replica.** Two forms depending on how the gateway is exposed: a 60s hang with `UC,DC` in the Envoy log, or a sub-second 503 that does not appear in the Envoy log at all (the router failing fast). Fix:
>
> ```bash
> oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
> oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
> ```
>
> Observed three times: after a Service-type change, overnight at 25h uptime, and after operator installs. Always re-run the six-call loop after any platform change.

## 8e. Prove the governance works

```bash
# Forged key → 403
curl -sk -o /dev/null -w "forged:  %{http_code}\n" "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-NOTREAL" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"

# No credential → 401
curl -sk -o /dev/null -w "no auth: %{http_code}\n" "${MAAS_GW}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"

# A model outside the subscription → 403 with a reason
curl -sk -D- -o /dev/null "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"anthropic.claude-sonnet-5","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' \
  | grep -i 'x-ext-auth-reason'
# x-ext-auth-reason: model_not_in_subscription
```

That last one is the one people do not expect: a valid key is not a licence to use any model.

---

# Adding more models later

No new AWS resource, no new credential — the existing `ExternalProvider` is reused.

```bash
export M2="gpt-oss"
export M2_TARGET="openai.gpt-oss-20b"

# 1. Test the target model against Bedrock directly FIRST
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${M2_TARGET}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}" \
  | jq '{content: .choices[0].message.content, tokens: .usage.total_tokens}'

# 2. Register
cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${M2}
  namespace: ${MODEL_NS}
spec:
  modelName: ${M2}
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: ${M2_TARGET}
      weight: 100
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${M2}
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${M2}
EOF

# 3. Governance — or it stays Pending
oc patch maasauthpolicy bedrock-access -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2}\",\"namespace\":\"${MODEL_NS}\"}}]"

oc patch maassubscription analysts-standard -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2}\",\"namespace\":\"${MODEL_NS}\",\"tokenRateLimits\":[{\"limit\":100000,\"window\":\"1h\"}]}}]"

# 4. The HTTPRoute patch — every new model needs it
sleep 20
oc patch httproute ${M2} -n ${MODEL_NS} --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/3/matches/0/headers/0/value\",\"value\":\"${M2}\"}]"

# 5. Verify
sleep 10
oc get maasmodelref -n ${MODEL_NS}
curl -sk -m 60 "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${M2}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}" \
  | jq -r '.choices[0].message.content'
```

Roughly 50 models are reachable through the one credential. Adding one is two CRs and two patches, and every analyst on that subscription can use it by changing one string.

---

# Troubleshooting

| Symptom | Where it failed | Fix |
|---|---|---|
| `500 authType 'apikey' credentials not found` | IPP credential store | Secret label must be `inference.llm-d.ai/ipp-managed=true` (Step 3) |
| `404`, Envoy logs `route_not_found` | Envoy — never left the cluster | HTTPRoute header patch (Step 6) |
| `404` **with `x-amzn-requestid`** | AWS — wrong path | Use the gateway root, not the namespaced URL (Step 8c) |
| `400 ... does not support the '/v1/chat/completions' API` | AWS — wrong apiFormat | Use an OpenAI-format model |
| `403 x-ext-auth-reason: model_not_in_subscription` | Authorino, working correctly | Use `modelName`, not `targetModel`, in the request body |
| `401` on a previously working key | The MaaS API key expired | Mint a new one |
| `503` on ~10–50% of calls | Stale gateway replica | Restart the gateway deployment (Step 8d) |
| `MaaSModelRef` Pending, `NoPairingFound` | No policy + subscription pair | Step 7b |
| `MaaSModelRef` Pending, `RuntimeReady=False` | Provider, Secret or endpoint | Fix Steps 3–4 first |
| `invalid_api_key` from AWS | Truncated ABSK key | Check it is 132 bytes (Step 1d) |

Logs, in the order the request travels:

```bash
oc logs -n kuadrant-system deployment/authorino --tail=50           # auth decision
oc logs -n openshift-ingress -l app=payload-processing --tail=50    # model resolution, credential injection
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --tail=20
```

The payload-processing log names each stage: `maas-headers-guard` → `model-provider-resolver` → `api-translation` → `apikey-injection`. Whichever stage logs last is where it failed.

---

# Operational notes

- **The ABSK key expires** — 90 days as created above. An IAM user can hold two, so create the second, roll the Secret, then delete the first for zero-downtime rotation.
- **MaaS API keys expire** per their `expiresIn`. Expiry looks like an auth bug rather than an expiry.
- **Re-check the HTTPRoute patch** before demos and after any platform change.
- **Re-run the six-call loop** after any gateway or operator change.
- **Tighten the IAM policy** for production. `AmazonBedrockLimitedAccess` also grants provisioned-throughput creation, model customisation, guardrail deletion and marketplace subscription — more than a gateway needs. `AmazonBedrockMantleInferenceAccess` is the narrow alternative, but **whatever you use must include `bedrock-mantle:CallWithBearerToken`**, or every call fails identically to a truncated key.