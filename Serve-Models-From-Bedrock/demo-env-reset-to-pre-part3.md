# Demo Environment Reset — back to "MaaS installed, no external models"

**Purpose:** revert the demo cluster to the same state as the customer cluster — RHOAI 3.5 with the MaaS platform fully configured and healthy (**Part 1 of the install guide complete**), but with **no external models, no Bedrock credential, and no governance objects** (nothing from Parts 3–4). From that state you can practice the install guide from Part 2 onward, exactly as it will run on site.

**Internal document — not for the customer.**

---

## What gets removed vs. what stays

| Removed (Parts 3–4 artifacts) | Stays (Part 1 platform — customer has this too) |
|---|---|
| Minted MaaS API keys | RHCL operator, Kuadrant CR, Authorino (incl. TLS config), Limitador |
| `MaaSAuthPolicy` + all `MaaSSubscription`s (incl. `demo-limited`) | `maas-default-gateway` + its options ConfigMap |
| `MaaSModelRef`s and `ExternalModel`s (and their generated HTTPRoutes) | PostgreSQL (`maas-db` project) + `maas-db-config` secret |
| `ExternalProvider` (and its ServiceEntry/DestinationRule/Service) | DSC `aigateway`/`modelsAsAService: Managed`, `maas-api`, AITenant, MaasTenantConfig |
| Secret `bedrock-api-key` | User workload monitoring, dashboard feature flags, namespace labels |
| Namespace `external-models` | DSC `trustyai: Managed` (base install, harmless without a guardrails CR) |
| NeMo guardrails: namespace `guardrails` with the `NemoGuardrails` CR, `nemo-config`/`nemo-ca-bundle` ConfigMaps, `nemo-upstream-key` Secret | **The AWS ABSK key itself** — nothing on the AWS side is touched; keep the key locally, you need it to practice Part 2 |

> **Do not delete** `MaasTenantConfig`, `AITenant`, or anything in `redhat-ai-gateway-infra` / `openshift-ingress` / `kuadrant-system`. Those are Part 1. The tenant resources in particular are bootstrapped once and are not automatically recreated.

Set the working variables:

```bash
export MODEL_NS="external-models"
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
```

---

## Step 0 — Inventory what will be deleted

Look before deleting — this is also your record of what the demo had:

```bash
oc get maasauthpolicy,maassubscription -n models-as-a-service
oc get maasmodelref,externalmodels.inference.opendatahub.io,externalprovider -n ${MODEL_NS}
oc get httproute,secret,serviceentry,destinationrule,svc -n ${MODEL_NS}
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" | jq -r '.data[].id'
```

If anything unexpected appears (resources you did not create in Parts 3–4), stop and identify it before proceeding — the deletes below are broad (`--all` within these namespaces).

Also check for guardrails leftovers from earlier demo work (the customer install has none):

```bash
oc get nemoguardrails -A 2>/dev/null
oc get guardrailsorchestrator -A 2>/dev/null
```

---

## Step 1 — Revoke minted MaaS API keys

Deleting the subscriptions (Step 2) invalidates every key bound to them, so this step is belt-and-braces — but do it anyway to keep the key store clean: **Gen AI studio → API keys** → delete `install-verify`, `demo-standard`, `demo-limited`, **`nemo-guardrails`**, and anything else listed.

The `nemo-guardrails` key matters most: unlike the 24-hour test keys, it was minted with `expiresIn: 720h`, so it does not die of old age any time soon.

---

## Step 2 — Delete governance

Removes who-may-call and quota objects. After this, any surviving key gets `403` and the models drop back to `Pending` — which is fine, they are deleted next.

```bash
oc delete maasauthpolicy --all -n models-as-a-service
oc delete maassubscription --all -n models-as-a-service

oc get maasauthpolicy,maassubscription -n models-as-a-service    # both: No resources found
```

> `--all` here is safe for these two kinds only. It does not touch `MaasTenantConfig`, which is a different kind in the same namespace — verify it survived: `oc get maastenantconfig -n models-as-a-service` → still `READY True`.

---

## Step 3 — Delete the model and provider objects

Reverse order of creation: exposure → model → provider.

```bash
oc delete maasmodelref --all -n ${MODEL_NS}
oc delete externalmodels.inference.opendatahub.io --all -n ${MODEL_NS}
oc delete externalprovider --all -n ${MODEL_NS}
```

Deleting the `ExternalModel`s removes their generated HTTPRoutes; deleting the `ExternalProvider` removes the ServiceEntry, DestinationRule, and ExternalName Service it owned. Confirm nothing generated is left behind:

```bash
oc get maasmodelref,externalmodels.inference.opendatahub.io,externalprovider -n ${MODEL_NS}
oc get httproute,serviceentry,destinationrule -n ${MODEL_NS}
# all: No resources found
```

If an HTTPRoute lingers after a minute, it has a stuck finalizer — check `oc get httproute <name> -n ${MODEL_NS} -o jsonpath='{.metadata.finalizers}'` before forcing anything.

---

## Step 4 — Delete the credential Secret and the namespace

```bash
oc delete secret bedrock-api-key -n ${MODEL_NS}

# The credential watcher should log the removal within seconds
oc logs -n openshift-ingress -l app=payload-processing --since=1m | grep -i secret
```

Then remove the namespace itself — the customer cluster does not have it; the install guide's §3.1 creates it:

```bash
oc delete namespace ${MODEL_NS}
oc get namespace ${MODEL_NS}    # Error from server (NotFound) — after a short Terminating phase
```

> If the namespace hangs in `Terminating` for more than a couple of minutes, something in Step 3 left a resource with a finalizer — `oc api-resources --verbs=list --namespaced -o name | xargs -n1 oc get -n ${MODEL_NS} --no-headers 2>/dev/null` shows what is still inside. Delete that resource properly rather than stripping finalizers.

The AWS key is untouched by all of this — it lives on in your password manager / shell, ready for practicing Part 2.

---

## Step 5 — Remove the NeMo guardrails deployment

The customer install has no guardrails; the demo env does. Everything guardrails-related lives in the `guardrails` namespace:

| Resource | Created by |
|---|---|
| `NemoGuardrails/nemo-guardrails` CR | You (runbook §5.4) — its pod, Service, and reencrypt Route are operator-created and go with it |
| ConfigMaps `nemo-config`, `nemo-ca-bundle` | You (§5.3) |
| Secret `nemo-upstream-key` | You (§5.2) — holds the 720h MaaS key revoked in Step 1 |
| Namespace label `maas.opendatahub.io/gateway-access` | You (§5.2) |

```bash
export GR_NS="guardrails"

# See what is there first
oc get nemoguardrails,pods,svc,route,configmap,secret -n ${GR_NS}

# CR first, so the operator tears down its children cleanly, then the namespace
# (takes the ConfigMaps, the Secret, and the label with it)
oc delete nemoguardrails --all -n ${GR_NS}
oc get pods,svc,route -n ${GR_NS}          # wait until the operator-created children are gone
oc delete namespace ${GR_NS}
```

Two things guardrails work may have touched **outside** this namespace — check both:

```bash
# 1. Bypass-closing (§5.6): if the direct-lane MaaSAuthPolicy was ever scoped to
#    NeMo's identity, that policy object was already deleted in Step 2 — but a
#    dedicated group created to hold NeMo's ServiceAccount would remain:
oc get group 2>/dev/null | grep -i nemo

# 2. DSC: trustyai stays Managed — leave it. It is part of the base RHOAI install,
#    harmless without a NemoGuardrails CR, and reverting DSC components is not
#    worth the churn for practice parity.
```

---

## Step 6 — Verify the end state matches the customer cluster

The platform must still be fully healthy — this is the §1.0 assessment from the install guide, and every line must be OK:

```bash
printf "%-48s" "RHCL operator:";                oc get csv -n openshift-operators 2>/dev/null | grep -qi 'rhcl' && echo OK || echo MISSING
printf "%-48s" "Authorino + Limitador pods:";   [ "$(oc get pods -n kuadrant-system --no-headers 2>/dev/null | grep -cE 'authorino|limitador')" -ge 2 ] && echo OK || echo MISSING
printf "%-48s" "Authorino TLS listener:";       oc logs -n kuadrant-system deployment/authorino 2>/dev/null | head -5 | grep -q '"tls":true' && echo OK || echo MISSING
printf "%-48s" "User workload monitoring:";     oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -q prometheus-user-workload && echo OK || echo MISSING
printf "%-48s" "MaaS gateway:";                 oc get gateway maas-default-gateway -n openshift-ingress >/dev/null 2>&1 && echo OK || echo MISSING
printf "%-48s" "Database secret:";              oc get secret maas-db-config -n redhat-ai-gateway-infra >/dev/null 2>&1 && echo OK || echo MISSING
printf "%-48s" "maas-api running:";             oc get pods -n redhat-ai-gateway-infra --no-headers 2>/dev/null | grep -q 'maas-api.*Running' && echo OK || echo MISSING
printf "%-48s" "Gateway health endpoint:";      [ "$(curl -sk -o /dev/null -w '%{http_code}' ${MAAS_GW}/maas-api/health)" = "200" ] && echo OK || echo MISSING
```

And the model layer must be empty:

```bash
oc get namespace ${MODEL_NS} 2>&1 | grep -q NotFound && echo "namespace gone: OK"
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" | jq '.data'
# []  — an empty catalogue
```

**Both conditions met = the demo env now mirrors the customer cluster.** Practice runs start at the install guide's Part 2 (validate the AWS key), then Part 3 onward.

---

## Practicing repeatedly

The whole Parts 3–4 build and this reset are cheap to cycle:

- **One full practice round** ≈ install guide Parts 2–4 (~30 min) + this reset (~5 min).
- The reset is idempotent — re-running any step on an already-clean cluster just reports "not found".
- Between rounds nothing on the AWS side changes; the same ABSK key is reused every time.
- If inference starts throwing intermittent `503`s during a practice round after all this churn, that is the stale-gateway-replica behavior — restart and re-verify:

  ```bash
  oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
  oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
  ```
