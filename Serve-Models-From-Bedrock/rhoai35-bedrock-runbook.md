# RHOAI 3.5 GA → AWS Bedrock via MaaS, with Guardrails

**Step-by-step from a bare RHOAI 3.5 install to a three-part customer demo.**

Verified against: OCP 4.22.10 on AWS · RHOAI 3.5.0 GA (`stable-3.5`) · RHCL 1.4.2 · Bedrock Mantle `us-east-1`

---

## 0. What you are building

Three demonstrable capabilities, built in order:

| # | Demo | What it proves |
|---|---|---|
| 1 | **Workbench** — Jupyter notebook calling Bedrock through RHOAI with the standard OpenAI SDK | Analysts change one URL and one key. Nothing else about their workflow changes. |
| 2 | **Governed model access** — same Bedrock models, now with metering, quota, revocation, and model swap | The organisation gets control without costing the analyst anything |
| 3 | **Guardrailed lane** — PII and toxicity filtered before anything leaves the cluster | Content control on top of access control. The data-residency answer. |

### Target architecture

```
Analyst / notebook
      │
      │  Lane A (direct)           Lane B (guardrailed)
      │  Bearer <MaaS key>         Bearer <MaaS key>
      ▼                            ▼
      │                     Guardrails Orchestrator ── regex detectors (PII)
      │                            │                └─ HAP detector (CPU model)
      │                            │
      └──────────┬─────────────────┘
                 ▼
      maas.<cluster-domain>              ← MaaS Gateway (Envoy / Gateway API)
                 │
                 ├─ Authorino   → validates MaaS key, STRIPS Authorization header
                 ├─ Limitador   → enforces token quota from MaaSSubscription
                 └─ BBR / IPP   → injects the Bedrock ABSK key from a K8s Secret
                 ▼
      bedrock-mantle.us-east-1.api.aws   ← AWS Bedrock, OpenAI-compatible
```

The analyst never sees the AWS credential. That is the entire point.

### Where the guardrails sit, and why

The orchestrator goes **in front of** the MaaS gateway: `client → orchestrator → MaaS gateway → Bedrock`.

The alternative — pointing `ExternalModel.spec.endpoint` at an in-cluster orchestrator so guardrails sit *behind* MaaS — is fragile. The `bedrock-openai` provider builds a ServiceEntry and DestinationRule with TLS origination aimed at an external FQDN; aiming that at a cluster-local service is not what it is designed for. Do not build a customer demo on it.

The usual objection to orchestrator-in-front is that an analyst could bypass guardrails by calling the MaaS URL directly. That is solved at the authorization layer rather than with topology: scope the direct lane's `MaaSAuthPolicy` to the orchestrator's ServiceAccount only, and give the analyst group access to the guardrailed lane. It also demos well — the bypass attempt returns 403 on camera.

### Facts worth knowing before you start

| Fact | Consequence |
|---|---|
| **No GPU needed for Bedrock routing.** | External model routing is pure gateway work. No vLLM, no accelerator operators. |
| **Guardrails detectors DO run on-cluster.** | The HAP detector is a real (small, CPU-viable) model. Adding it means you are serving something locally — the "nothing runs here" property goes away. Regex detectors need no model at all. |
| **`ExternalModel` is Tech Preview.** | MaaS itself is GA (since 3.4). The external-provider CRD is not. Confirm current status in the 3.5 GA release notes and say it out loud to the customer. |
| **`kserve.modelsAsService` is deprecated.** | MaaS is now `spec.components.aigateway.modelsAsAService`. Note the spelling: **AsA**. |
| **The deprecated field is one-directional.** | CEL allows `Managed→Removed` but blocks `Removed→Managed`. You cannot fall back to the old path. |
| **Docs lag the GA release.** | At time of writing the 3.5 doc set still renders "EA2" titles. Trust the cluster's CRDs over any document, including this one. |
| **Use `bedrock-mantle`, not `bedrock-runtime`.** | The payload processor calls `/v1/chat/completions`, which only exists on the Mantle endpoint. |

### Reference material

- Official 3.5 doc set: `https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5`
- MaaS: `.../3.5/html/govern_llm_access_with_models-as-a-service/index`
- Guardrails: `.../3.5/html/enabling_ai_safety_with_guardrails/index`
- Supported Configurations (per-component TP/GA status): `https://access.redhat.com/articles/rhoai-supported-configs-3.x`
- Companion field guide (Kustomize + scripts): `https://rh-aiservices-bu.github.io/rhoai-maas-guide/`

### Working variables

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')"
export AWS_REGION="us-east-1"
export MODEL_NS="external-models"
export TARGET_MODEL="openai.gpt-oss-20b"
echo "Gateway will be: $MAAS_GW"   # NOT maas.<domain> — derive it, never construct it
```

---

# PART 1 — Where you are now

## 1.1 Confirmed starting state

This runbook assumes the state below. If yours differs, run the audit in §1.2.

| Component | State |
|---|---|
| OpenShift | 4.22.10 on AWS — Gateway API built in |
| RHOAI operator | `rhods-operator.3.5.0` GA, channel `stable-3.5`, Manual approval |
| DSCInitialization | `default-dsci` Ready |
| **DataScienceCluster** | **none — you create it in §2.7** |
| cert-manager | `cert-manager-operator.v1.20.0` Succeeded |
| JobSet | `jobset-operator.v1.0.0` Succeeded |
| LeaderWorkerSet | **not installed — not required in 3.5** |
| **Red Hat Connectivity Link** | **not installed — §2.2** |
| GatewayClass | `data-science-gateway-class` Accepted (created by the DSCI) |
| Kuadrant / Authorino / Limitador | not deployed |
| User Workload Monitoring | not enabled |
| Storage | `gp3-csi` default |
| AWS Bedrock | ABSK key working, `us-east-1`, `openai.gpt-oss-20b` returning completions |

## 1.2 Re-audit at any time

```bash
#!/usr/bin/env bash
echo "=== Platform ==="
oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
oc get infrastructure cluster -o jsonpath='{.status.platform}'; echo
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'; echo

echo -e "\n=== Operators (non-copied CSVs only) ==="
for ns in redhat-ods-operator openshift-operators cert-manager-operator openshift-jobset-operator kuadrant-system; do
  oc get csv -n $ns --no-headers 2>/dev/null | grep -v '^rhods-operator.*Succeeded$' | sed "s/^/[$ns] /"
done

echo -e "\n=== Gateway stack ==="
oc get gatewayclass
oc get gateway -A 2>/dev/null || echo "no gateways"
oc get pods -n kuadrant-system 2>/dev/null || echo "no kuadrant-system"

echo -e "\n=== MaaS ==="
oc get crd 2>/dev/null | grep -E 'maas|aigateway' || echo "no MaaS CRDs — aigateway not Managed"
oc get deployment maas-api -n redhat-ods-applications 2>/dev/null || echo "maas-api not deployed"
oc get pods -n openshift-ingress -l app=payload-processing 2>/dev/null || echo "IPP not found"

echo -e "\n=== DSC / UWM / storage ==="
oc get datasciencecluster,dscinitialization
oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | wc -l
oc get storageclass | grep default
```

> **Reading `oc get csv -A`:** RHOAI installs in AllNamespaces mode, so OLM copies `rhods-operator.3.5.0` into every namespace. Those copies are noise. Only the CSV in `redhat-ods-operator` is real.

---

# PART 2 — Platform prerequisites

## TL;DR — what Part 2 does and why

You are assembling the **gateway** that will sit in front of every model call. Nothing here touches AWS or Bedrock. By the end, RHOAI will expose a single authenticated, metered HTTPS endpoint that models get attached to in Part 4.

Seven steps, and the order is not negotiable:

| Step | What | Why it must come when it does |
|---|---|---|
| §2.2 | Install **RHCL** | Provides Authorino (authN/authZ) and Limitador (rate limiting). Nothing downstream works without it. |
| §2.3 | Create the **Kuadrant CR** + Authorino TLS | Installing the operator does not deploy Authorino. The CR does. TLS must be bootstrapped before the Gateway talks to it. |
| §2.4 | Enable **User Workload Monitoring** | Token metering and the observability dashboard scrape from here. Enable before traffic flows or you have no baseline. |
| §2.5 | **Verify** the platform Gateway | 3.5 GA creates it via `GatewayConfig`. Do NOT build one — you would fight the operator. Derive your base URL here. |
| §2.6 | **PostgreSQL** + `maas-db-config` | `maas-api` stores hashed API keys here. Without it, `maas-api` crash-loops on first start. |
| §2.7 | Apply the **DataScienceCluster** | Brings up RHOAI proper: dashboard, workbenches, KServe, TrustyAI. MaaS stays off. |
| §2.8 | Flip **`aigateway` + `modelsAsAService`** to Managed | Only now do the prerequisites all exist. This creates the MaaS CRDs, `maas-api`, and the payload processor. |

The single most common failure is doing §2.8 early. `maas-api` then crash-loops on a missing database and you spend an hour debugging the wrong layer.

**Mental model:** §2.2–2.3 build the security plane, §2.4 the observability plane, §2.5 confirms the network entrypoint the platform already built, §2.6 the state store. §2.7 installs the product. §2.8 connects them and you discover the result.

## 2.1 What you already have

Skip anything below that is already satisfied — on the verified starting state, all three are:

| Requirement | Status |
|---|---|
| OpenShift 4.19+ | ✅ 4.22.10 |
| cert-manager Operator | ✅ v1.20.0 |
| JobSet Operator | ✅ v1.0.0 |
| LeaderWorkerSet | Not required in 3.5 — JobSet replaced it. Ignore any guide that lists it. |
| Default StorageClass | ✅ `gp3-csi` — needed for workbench PVCs |

## 2.2 Install Red Hat Connectivity Link

Provides Authorino and Limitador. **This is your only missing operator.**

### Console

**Operators → OperatorHub** → search `Connectivity Link` → **Red Hat Connectivity Link** (source: *Red Hat*, not Community) → **Install** → namespace `openshift-operators`, channel `stable`.

Take the Red Hat build, not the Community `kuadrant-operator` or the standalone `authorino-operator` — both appear in the catalog and neither is supported here.

### CLI

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

oc wait csv -n openshift-operators \
  -l operators.coreos.com/rhcl-operator.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

### Verify

```bash
oc get csv -n openshift-operators | grep -iE 'rhcl|authorino|limitador|dns'
```

Expect `rhcl-operator.v1.4.2` (or later) at Succeeded, plus authorino, limitador, and dns operator CSVs alongside it.

**Version floor: RHCL 1.3+ / Authorino 0.23.1+.** That release added Authorization-header stripping — the mechanism that stops the analyst's token from reaching AWS. It is the security claim the whole demo rests on. If you land below it, stop.

> CSVs take 30–60s to appear after the Subscription. `oc wait` returning *"no matching resources found"* means "too early", not "broken".
>
> Installing RHCL does **not** deploy Authorino and Limitador — `kuadrant-system` stays empty until §2.3. That is expected.

## 2.3 Kuadrant CR and Authorino TLS

```bash
oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -
```

**Pre-annotate the Authorino service first**, so `service-ca` mints its certificate before the operator creates the deployment:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: authorino-authorino-authorization
  namespace: kuadrant-system
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert
spec:
  ports:
    - name: grpc
      port: 50051
      targetPort: 50051
    - name: http
      port: 5001
      targetPort: 5001
  selector:
    authorino-resource: authorino
EOF

cat <<'EOF' | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec:
  observability:
    enable: true
EOF

oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
```

### Authorino TLS — three parts, all required

This is the most error-prone step in Part 2. It has three pieces and **all three must be present**: the server certificate, the CA bundle mount, and the environment variables. Doing only some of them fails silently.

#### (a) Server certificate — enable the TLS listener

The `authorino-server-cert` secret was minted by `service-ca` because you pre-annotated the Service above.

```bash
oc explain authorino.spec.listener.tls          # confirm the field path
oc get secret authorino-server-cert -n kuadrant-system   # must exist

oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {"listener": {"tls": {
    "enabled": true,
    "certSecretRef": {"name": "authorino-server-cert"}
  }}}}'
```

#### (b) CA bundle — create the ConfigMap and MOUNT it

**This step is missing from most guides and is easy to skip.** The environment variables in (c) point at a file path; nothing creates that file unless you mount it. Setting the variables without the mount fails *open*: Go silently ignores an unreadable `SSL_CERT_FILE` and falls back to the container's default CA bundle, which contains public CAs but **not** the cluster service CA. Everything appears healthy until Authorino makes an outbound TLS call to a service-CA-signed in-cluster endpoint, then produces `x509: certificate signed by unknown authority` somewhere that looks unrelated.

OpenShift's service-ca operator populates any ConfigMap carrying the inject annotation:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-service-ca
  namespace: kuadrant-system
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF

sleep 5
oc get configmap openshift-service-ca -n kuadrant-system -o jsonpath='{.data}' | jq 'keys'
# ["service-ca.crt"]
```

Mount it **via the Authorino CR, not the Deployment.** The operator regenerates the deployment from the CR, so a `oc patch deployment` volume edit gets reconciled away. The CR has a first-class `spec.volumes` field for exactly this:

```bash
oc explain authorino.spec.volumes --recursive
```

On RHCL 1.4.2: `items[]` with `name`, `configMaps[]`, `secrets[]`, `mountPath` (required), and a nested `items[]` for key→path mapping.

```bash
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {"volumes": {"items": [{
    "name": "service-ca",
    "configMaps": ["openshift-service-ca"],
    "mountPath": "/etc/ssl/certs/openshift-service-ca",
    "items": [{"key": "service-ca.crt", "path": "service-ca-bundle.crt"}]
  }]}}}'
```

> **The `items` key→path mapping is load-bearing.** service-ca injects the bundle under the key `service-ca.crt`, but the environment variables expect a file named `service-ca-bundle.crt`. Without the mapping the file mounts under the wrong name and you have changed nothing — while every command still reports success.

#### (c) Environment variables

The Authorino CR has **no** env field (`oc explain authorino.spec --recursive | grep -i -A5 'env'` returns nothing), so this must be set on the Deployment:

```bash
oc -n kuadrant-system set env deployment/authorino SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

oc rollout status deployment/authorino -n kuadrant-system --timeout=300s
```

Run it on one line. Broken across lines with backslashes, a stray leading space produces a literal `\ SSL_CERT_FILE=...` argument in zsh.

> Because this is a Deployment-level edit and the operator regenerates the Deployment from the CR, **re-check it after any Authorino CR change or operator upgrade.** On RHCL 1.4.2 it survived the CR-driven rollout in (b), but that is observed behaviour, not a guarantee.

#### Verify all three

```bash
# The mount exists and contains a real certificate
oc -n kuadrant-system exec deployment/authorino -- ls -l /etc/ssl/certs/openshift-service-ca/
# service-ca-bundle.crt -> ..data/service-ca-bundle.crt

oc -n kuadrant-system exec deployment/authorino -- head -1 /etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
# -----BEGIN CERTIFICATE-----

# The env vars survived
oc -n kuadrant-system set env deployment/authorino --list | grep -E 'SSL_CERT|REQUESTS_CA'

# TLS listeners are up
oc logs -n kuadrant-system deployment/authorino | head -5 | grep -E 'auth service'
# "starting http auth service","port":5001,"tls":true
# "starting grpc auth service","port":50051,"tls":true
```

`"tls":true` on both the http and grpc auth services is the confirmation that (a) worked.

### Other `Kuadrant.spec` fields worth knowing

Confirm the schema on your cluster before assuming the CR above is valid:

```bash
oc get crd kuadrants.kuadrant.io -o jsonpath='{.spec.versions[*].name}{"\n"}'
oc explain kuadrant.spec --recursive
```

On RHCL 1.4.2 the schema is `v1beta1` with three top-level areas. Two are not used by this runbook but matter for a customer build:

| Field | What it does | Decision |
|---|---|---|
| `spec.mtls.{enable,authorino,limitador}` | Mutual TLS between the gateway and the Kuadrant data plane | **Off for the PoC.** This is a *different* mechanism from the Authorino server-cert TLS configured below — that one is required, this one is defence in depth. Raise it for the customer build: it is a supported field, not a workaround, and a security team may require it. Enabling it adds another failure surface, so do not turn it on while first bringing MaaS up. |
| `spec.observability.tracing.defaultEndpoint` | OpenTelemetry trace export | Optional. Gives you spans across Authorino → Limitador → IPP → AWS in one trace, alongside the token metrics. Useful when the customer asks "where did the latency go?" Add after Part 6 works. |
| `spec.components.developerPortal.enabled` | Kuadrant developer portal | Not used here. |

### Verify

```bash
oc get pods -n kuadrant-system
oc get deployment authorino -n kuadrant-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Authorino, Limitador, and the Kuadrant operator should be Running.

> **You cannot read the Authorino runtime version, so do not try.** Red Hat's build strips the ldflags, so the startup log reports `"version":"unknown","commit":"unknown"`, and the image is pinned by digest (`registry.redhat.io/rhcl-1/authorino-rhel9@sha256:...`) with no readable tag. `relatedImages` on the CSV gives the same digest.
>
> Header stripping — the mechanism that stops the analyst's token reaching AWS — requires Authorino 0.23.1+. RHCL 1.4.2 is well past that, but since the version is unverifiable, **confirm it functionally in Part 6 (§6.5)** by proving the upstream never receives the caller's Authorization header. Do not treat the `authorino-operator` CSV version as evidence: that is a different version line from the runtime.

### If the Kuadrant CR fails

`MissingDependency` is an Istio race condition:

```bash
oc delete pod -n openshift-operators \
  $(oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | awk '{print $1}')
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
```

**Console:** **Operators → Installed Operators → Red Hat Connectivity Link → Kuadrant → Create Kuadrant** (YAML view). Authorino edits: **Administration → CustomResourceDefinitions → Authorino → Instances → authorino → YAML**, then **Workloads → Deployments → authorino → Environment**.

## 2.4 Enable User Workload Monitoring

Token metering, quota dashboards, and the per-department chargeback story all scrape from here.

```bash
# If cluster-monitoring-config already exists, EDIT it — this apply replaces it wholesale
oc get configmap cluster-monitoring-config -n openshift-monitoring 2>/dev/null

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

oc wait --for=condition=Available deployment/prometheus-operator \
  -n openshift-user-workload-monitoring --timeout=300s
oc get pods -n openshift-user-workload-monitoring
```

Expect `prometheus-operator`, `prometheus-user-workload-0`, and `thanos-ruler-user-workload-0` Running.

**Console:** **Workloads → ConfigMaps**, project `openshift-monitoring`.

## 2.5 Verify the platform Gateway — do NOT create one

**In RHOAI 3.5 GA the Gateway is created and owned by the platform.** Older guides (and earlier revisions of this runbook) tell you to build a `maas-default-gateway` by hand. That was correct for 3.4. It is wrong for 3.5 GA and will fight the operator.

### What 3.5 GA creates for you

The DSCInitialization creates a `GatewayConfig` CR (`services.platform.opendatahub.io/v1alpha1`, named `default-gateway`), which in turn owns:

- the `GatewayClass` `data-science-gateway-class`
- the `Gateway` `data-science-gateway` in `openshift-ingress`
- an OpenShift Route exposing it externally

```bash
oc get gatewayconfig -A
oc get gatewayclass
oc get gateway -A
oc get route -n openshift-ingress
```

Expected on a healthy 3.5 GA cluster:

| Resource | Expected |
|---|---|
| `gatewayconfig/default-gateway` | `phase: Ready`, `status.domain` populated |
| `gatewayclass/data-science-gateway-class` | `ACCEPTED True` |
| `gateway/data-science-gateway` | `PROGRAMMED True` in `openshift-ingress` |
| Route in `openshift-ingress` | reencrypt route to the gateway service |

### Derive your base URL from the cluster — never construct it

```bash
export MAAS_GW="https://$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')"
echo "$MAAS_GW"
```

On the reference cluster this is `https://rh-ai.apps.<cluster-domain>` — note it is **not** `maas.<cluster-domain>`. The subdomain comes from `GatewayConfig`, is configurable via `spec.subdomain`/`spec.domain`, and will differ per site. Any guide (including older parts of this one) that hardcodes `maas.<domain>` is wrong.

### Understand the namespace allowlist before Part 4

This is the detail that decides whether your models are reachable.

```bash
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.spec.listeners}' | jq .
```

On the reference cluster the listener selects namespaces by **explicit name**, not by label:

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: [openshift-ingress, redhat-ods-applications]
```

**Consequence:** the `maas.opendatahub.io/gateway-access=true` label that 3.4-era guides tell you to apply does nothing against this Gateway. Your `external-models` namespace must appear in that allowlist by name.

You cannot simply edit the Gateway — it has `ownerReferences` to `GatewayConfig` and the operator reconciles changes away. See §2.8 for how the MaaS component handles this.

**Note the allowlist as it stands now**, before enabling MaaS — §2.8's discovery compares against this baseline to see whether the operator extends it for you. Capture it into the site record sheet (Appendix F):

```bash
oc get gateway data-science-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector}' | jq -c .
```

Reference cluster before §2.8: `openshift-ingress`, `redhat-ods-applications`.

### `GatewayConfig` fields (for the customer build)

`GatewayConfig.spec` governs identity and ingress plumbing, not routing:

| Field | Purpose | Customer-site relevance |
|---|---|---|
| `certificate.type` | `SelfSigned` \| `Provided` \| `OpenshiftDefaultIngress` | Use `Provided` with `secretName` for a real corporate cert |
| `domain` / `subdomain` | External hostname | Set explicitly if the default subdomain clashes with site DNS |
| `ingressMode` | `OcpRoute` \| `LoadBalancer` | `OcpRoute` on sandbox/lab. `LoadBalancer` where a real LB is available |
| `oidc` | `clientID`, `clientSecretRef`, `issuerURL` | **This is where you wire the customer's IdP** — Keycloak, Entra, Okta |
| `enableK8sTokenValidation` | Accept OpenShift tokens | Keep `true` for `oc whoami -t` admin flows |
| `authProxyTimeout`, `cookie.expire/refresh` | Session behaviour | Defaults are fine |

To change any of these, patch `GatewayConfig` — never the Gateway:

```bash
oc patch gatewayconfig default-gateway --type=merge -p '{"spec":{"subdomain":"maas"}}'
oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}{"\n"}'
```

> **`LoadBalancerReady: False` / `LoadBalancerPending` is normal** when `ingressMode: OcpRoute`. The Service stays ClusterIP and the Route provides external access. Do not chase this condition — check the Route works instead.

### Verify external reachability

```bash
oc get route -n openshift-ingress -o custom-columns='NAME:.metadata.name,HOST:.spec.host,SVC:.spec.to.name'
curl -vsk "${MAAS_GW}" 2>&1 | grep -E "SSL connection|Connected|HTTP/"
```

Reference output at this stage:

```
* Connected to rh-ai.apps.<domain> (18.207.170.116) port 443
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256
< HTTP/1.1 404 Not Found
```

**404 is the expected and correct result.** You are testing three things — DNS resolves to a real address, TLS terminates, and the Route reaches the Gateway. All three passed. The 404 is the Gateway correctly reporting that no HTTPRoute matches `/`, because MaaS endpoints do not exist until §2.8.

| Response to `curl "${MAAS_GW}"` | Meaning |
|---|---|
| **404** | Correct at this stage. Gateway is live, no routes match `/` yet. |
| 403, or a redirect to a login page | Also fine — some configurations put the auth proxy in front of the catch-all |
| `Could not resolve host` | DNS/Route problem — check `oc get route -n openshift-ingress` |
| `Connection refused` / timeout | Gateway pod not running, or `ingressMode` mismatch — check `oc get pods -n openshift-ingress` |
| TLS handshake failure | Certificate problem — check `gatewayconfig.spec.certificate` and the listener's `certificateRefs` |

Do **not** try to make `/` return 200. It has no route and is not supposed to.

### Fallback: no Gateway was created

If `oc get gatewayconfig -A` returns nothing, the DSCI has not reconciled. Do not hand-build a Gateway — fix the DSCI:

```bash
oc get dscinitialization default-dsci -o yaml | yq '.status'
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100 | grep -i gateway
```

The manual Gateway procedure is preserved in **Appendix D** for 3.4-era clusters and for the case where a site genuinely needs a second, separately-managed gateway. Do not use it on 3.5 GA unless §2.8 discovery shows the operator does not wire MaaS in.
## 2.6 PostgreSQL for maas-api

`maas-api` stores hashed API keys, subscription bindings, expiry, and revocation state. **Create this before §2.8 or `maas-api` crash-loops.**

In-cluster PostgreSQL is fine for the PoC. Point at RDS for anything real.

```bash
oc new-project maas-db 2>/dev/null || oc project maas-db

read -rs PGPASS && export PGPASS   # paste a password, nothing echoes

oc new-app --name=maas-postgres \
  --image=registry.redhat.io/rhel9/postgresql-16:latest \
  -e POSTGRESQL_USER=maas \
  -e POSTGRESQL_PASSWORD="$PGPASS" \
  -e POSTGRESQL_DATABASE=maas

oc rollout status deployment/maas-postgres -n maas-db --timeout=300s
```

Create the secret in the **RHOAI applications namespace**:

```bash
oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:${PGPASS}@maas-postgres.maas-db.svc.cluster.local:5432/maas?sslmode=disable"

oc get secret maas-db-config -n redhat-ods-applications
```

For RDS: `postgresql://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require`

### Verify before continuing

Ten seconds here saves a confusing `maas-api` crash-loop at §2.8 that looks like a MaaS fault but is actually a password.

```bash
# Deployment (not DeploymentConfig), pod Running, service on 5432
oc get deployment,pods,svc -n maas-db

# Credentials actually work
oc exec -n maas-db deployment/maas-postgres -- \
  psql "postgresql://maas:${PGPASS}@localhost:5432/maas" -c '\conninfo'
# You are connected to database "maas" as user "maas" ...

# The connection URL survived the shell intact (password masked)
oc get secret maas-db-config -n redhat-ods-applications \
  -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d | sed 's/:[^:@]*@/:****@/'
# postgresql://maas:****@maas-postgres.maas-db.svc.cluster.local:5432/maas?sslmode=disable
```

The masked URL must have exactly one `@` and no extra `/` or `:` inside the masked section. If it does, the password contained a URL delimiter and the string is malformed — pick a password without `$ @ / : #` and redo the secret.

> **`oc new-app` gives you emptyDir, not a PVC.** The API-key store dies with the pod, so a restart invalidates every issued MaaS key. Acceptable for a demo you rebuild anyway; it is why Appendix E says use RDS or a PVC-backed instance at a customer site.

**Console:** **Workloads → Secrets → Create → Key/value secret**, project `redhat-ods-applications`, name `maas-db-config`, key `DB_CONNECTION_URL`.

> Namespace matters: `redhat-ods-applications` (RHOAI), not `opendatahub` (ODH). Wrong namespace = `secret not found` in the maas-api logs.

## 2.7 Apply the DataScienceCluster

MaaS stays **off** here. You turn it on in §2.8 once everything it needs exists.

This is derived from the operator's own GA `alm-examples`, trimmed for a cluster with no GPU. Components that would deploy idle or Pending pods are `Removed` — they add noise you will otherwise debug thinking it is MaaS.

```bash
cat <<'EOF' > dsc.yaml
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
  labels:
    app.kubernetes.io/name: datasciencecluster
spec:
  components:
    # --- Needed for this engagement ---
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed          # Demo 1 — Jupyter
    kserve:
      managementState: Managed          # Serving stack; also hosts guardrails detectors
      nim:
        managementState: Removed        # NVIDIA NIM — no GPU
      wva:
        managementState: Removed
      modelsAsService:
        managementState: Removed        # DEPRECATED — do not use; see §2.8
    trustyai:
      managementState: Managed          # Demo 3 — Guardrails Orchestrator
    modelregistry:
      managementState: Managed
      registriesNamespace: rhoai-model-registries

    # --- MaaS: off until §2.8 ---
    aigateway:
      managementState: Removed
      batchGateway:
        managementState: Removed

    # --- Not needed on a GPU-less demo cluster ---
    aipipelines:
      managementState: Removed
    feastoperator:
      managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    mcplifecycleoperator:
      managementState: Removed
    mlflowoperator:
      managementState: Removed
    ogx:
      managementState: Removed
    ray:
      managementState: Removed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
EOF

oc apply -f dsc.yaml
oc get dsc -w        # wait for READY True, then Ctrl-C
```

**Choices worth knowing:**

- **`llamastackoperator: Removed`** — GenAI Studio playground. Set Managed if you want a built-in chat UI for the demo; it is not required for anything else here.
- **`kueue`, `ray`, `aipipelines`, `trainer` all Removed** — the GA example enables several of these. On a GPU-less cluster they deploy controllers that sit idle. If you would rather mirror a realistic customer platform, flip them to Managed; they are harmless, just noisy.
- **`modelregistry: Managed`** — deploys its own database. Keep it if you want to show the registry; set Removed to save resources. Note that removing it after it holds data destroys that data.
- **Every one of these is reversible** with a one-line patch:
  ```bash
  oc patch datasciencecluster default-dsc --type=merge \
    -p '{"spec":{"components":{"kueue":{"managementState":"Managed"}}}}'
  ```
  The one exception is `kserve.modelsAsService`, whose CEL rule blocks `Removed→Managed`. That field is deprecated and you are not using it.

### Verify the platform

```bash
oc get dsc default-dsc                       # READY True
oc get pods -n redhat-ods-applications
oc get route -n redhat-ods-applications rhods-dashboard -o jsonpath='{.spec.host}{"\n"}'
echo "$MAAS_GW"
```

**Two dashboard URLs is normal on 3.5.** The classic Route (`rhods-dashboard-redhat-ods-applications.apps.<domain>`) coexists with the gateway host (`$MAAS_GW`), and `dashboard-redirect` pods bridge them — 3.5 is moving the UI behind the gateway. Both should load.

Reading the pod list, three things surprise people coming from 3.4:

| Pod | Note |
|---|---|
| `maas-ui` | Present even though `aigateway` is **Removed**. The dashboard ships the MaaS UI regardless; it has no backend yet. Do **not** read this as MaaS being enabled. |
| `llmisvc-controller-manager`, `model-serving-api` | New 3.5 serving controllers, absent from 3.4-era guides. MaaS wiring hooks into these. |
| `workbenches-operator` with `RESTARTS 1` | A startup race while CRDs register. Benign if the count stays at 1. Investigate only if it climbs. |

### Smoke-test a workbench — do this BEFORE enabling MaaS

This is the gate between "RHOAI is installed" and "MaaS is added." If workbenches work now and break later, you know what changed. The workbench you create here is reused for Demo 1 in §6.2, so this is not throwaway work.

**Pre-checks:**

```bash
oc get crd notebooks.kubeflow.org
oc get imagestream -n redhat-ods-applications -o name | grep -iE 'datascience|minimal|pytorch'
oc get pods -n redhat-ods-applications | grep -E 'notebook|workbench'
```

An empty imagestream list means images are still importing — wait a few minutes.

**Create it (console):**

1. Open the dashboard and log in
2. **Data Science Projects → Create project** → `bedrock-demo`
3. **Workbenches → Create workbench**
   - Image: **Standard Data Science** — it has `pip`, which §6.2 needs for the `openai` package
   - Container size: **Small**
   - Storage: **Create new persistent storage**, 20Gi (uses the default StorageClass)
4. Create

```bash
oc get pods -n bedrock-demo -w
oc get notebook,pvc -n bedrock-demo
```

First start pulls a large image — several minutes is normal.

**Prove it works.** Open the workbench, start a notebook, and run:

```python
import sys, requests
print(sys.version)
print(requests.get("https://api.github.com", timeout=5).status_code)
```

Python version plus `200` confirms the notebook runs **and has egress** — which it needs to reach the MaaS gateway in §6.2. A hang or connection error here means network policy or a proxy, and it is much easier to diagnose now than when it looks like a MaaS failure later.

| Symptom | Cause |
|---|---|
| Workbench stuck Pending | No default StorageClass, or PVC unbound — `oc get pvc -n bedrock-demo` |
| ImagePullBackOff | Imagestreams still importing, or a pull-secret problem |
| No images offered in the form | Imagestreams not yet imported — wait and reload |
| Notebook starts, `requests` call hangs | Egress blocked. Resolve before §6.2 |

**Console:** **Administration → CustomResourceDefinitions → DataScienceCluster → Instances → Create DataScienceCluster** (YAML view), or masthead **+** → **Import YAML**.

## 2.8 Enable MaaS, then discover how it wired itself

Everything MaaS needs now exists: Authorino, Limitador, the platform Gateway, PostgreSQL, and a healthy RHOAI.

### The field path (changed in 3.5 GA)

`kserve.modelsAsService` is **deprecated** — preserved for backward compatibility through at least 3.6, and one-directional: CEL allows `Managed→Removed` but blocks `Removed→Managed`. You cannot fall back to it.

The live path is:

```
spec.components.aigateway.managementState: Managed
spec.components.aigateway.modelsAsAService.managementState: Managed
```

**Spelling: `modelsAsAService` — "AsA".** The CRD documents this as intentional, matching the `ai-gateway-operator` CRD's own `spec.modelsAsAService`. A misspelling is silently ignored, not rejected.

Confirm against your cluster before patching:

```bash
oc explain datasciencecluster.spec.components.aigateway.modelsAsAService
```

### Apply

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {"components": {"aigateway": {
    "managementState": "Managed",
    "modelsAsAService": {"managementState": "Managed"}
  }}}}'
```

**Console:** **CustomResourceDefinitions → DataScienceCluster → default-dsc → YAML**, edit `spec.components.aigateway`, Save.

### Discovery block — run this every time, at every site

MaaS is a first-class platform component in 3.5 GA: the CRD `modelsasservices.components.platform.opendatahub.io` sits alongside `kserves`, `dashboards`, and `workbenches`, and the operator manages its own wiring. **What it wires up is what you build Part 4 on top of**, so inspect rather than assume. Wait ~2 minutes after the patch, then:

```bash
echo "=== 1. Component CR ==="
oc get modelsasservice -A
oc get modelsasservice -A -o yaml | yq '.items[].status'

echo -e "\n=== 2. Did the Gateway change? ==="
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.spec.listeners}' | jq .

echo -e "\n=== 3. New routes / hostnames ==="
oc get httproute -A
oc get route -A | grep -iE 'maas|gateway|rh-ai'

echo -e "\n=== 4. Payload processor — external models need this ==="
oc get pods -n openshift-ingress

echo -e "\n=== 5. MaaS CRDs and API ==="
oc get crd | grep -E 'maas|aigateway'
oc get deployment maas-api -n redhat-ods-applications
oc get crd | grep -i tenant
oc get tenant,aitenant,maastenantconfig -A 2>/dev/null

echo -e "\n=== 6. Health ==="
export MAAS_GW="https://$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')"
echo "MAAS_GW=$MAAS_GW"
curl -sk "${MAAS_GW}/maas-api/health"
```

### How to read the results

| Question | Result | What to do |
|---|---|---|
| **Namespace allowlist** — did the listener's `matchExpressions` values grow? | New namespaces appeared | The operator manages the allowlist. Find how to declare `external-models`: `oc explain modelsasservice.spec --recursive` |
| | Unchanged | You must add `external-models` yourself — via `ModelsAsService` spec if it has such a field, else via `GatewayConfig`. **Never edit the Gateway directly.** |
| **Listener** — was a MaaS-specific listener added? | Yes, new hostname | Use that hostname as `MAAS_GW` |
| | No | MaaS shares the existing listener; endpoints live under paths on `$MAAS_GW` |
| **Payload processor** — pod in `openshift-ingress`? | Running | Good — external models will work |
| | Absent | **Stop.** External models cannot work. Check `oc get modelsasservice -A -o yaml` status conditions and the operator log |
| **`maas-api`** | `1/1` Available | Proceed |
| | CrashLoopBackOff | Almost always the database — see the table below |
| **Health endpoint** | `{"status":"healthy"}` | Part 2 complete |
| | 404 | Wrong base URL — re-derive from `gatewayconfig` `status.domain`, and check whether MaaS uses a different path prefix |
| | 503 | `maas-api` not ready yet; wait and retry |
| **Tenant resource** | `Tenant`, or `AITenant`/`MaasTenantConfig` | Record which; 3.5 GA may use either. `Ready=False` with `DeploymentsNotReady` is **expected** until a model is registered in Part 4 |

**Record the answers in Appendix F.** Parts 4–6 depend on four values: `MAAS_GW`, the model path prefix, the namespace admission mechanism, and the tenant CRD kind.

### If `maas-api` crash-loops

```bash
oc logs -n redhat-ods-applications deployment/maas-api --tail=100
```

| Log symptom | Cause | Fix |
|---|---|---|
| `secret "maas-db-config" not found` | Wrong namespace | Must be `redhat-ods-applications`, not `opendatahub` |
| `connection refused` / `dial tcp` | Postgres unreachable | Check service DNS and that `maas-postgres` is Running |
| `password authentication failed` | Wrong credentials | Recreate the secret, then `oc rollout restart deployment/maas-api -n redhat-ods-applications` |
| Pod never appears | DSC not reconciled | `oc describe dsc default-dsc`; `oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100` |
## 2.9 Dashboard feature flags

Turns on the MaaS tabs in the RHOAI console.

```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{
        "modelAsService": true,
        "maasAuthPolicies": true,
        "observabilityDashboard": true
      }}}'

oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | jq .
```

Add `"genAiStudio": true` only if you set `llamastackoperator: Managed` in §2.7.

**Console:** **CustomResourceDefinitions → OdhDashboardConfig → odh-dashboard-config → YAML.**

## 2.10 Part 2 exit criteria

Do not start Part 4 until all of these pass:

```bash
oc get csv -n openshift-operators | grep rhcl              # v1.4.2+ Succeeded
oc get pods -n kuadrant-system                             # authorino + limitador Running
oc get pods -n openshift-user-workload-monitoring          # prometheus-user-workload-0 Running
oc get gatewayconfig default-gateway                       # phase Ready, status.domain set
oc get gateway data-science-gateway -n openshift-ingress   # PROGRAMMED=True, has ADDRESS
oc get secret maas-db-config -n redhat-ods-applications    # exists
oc get dsc default-dsc                                     # READY True
oc get crd | grep maas.opendatahub.io                      # MaaS CRDs present
oc get deployment maas-api -n redhat-ods-applications      # 1/1
oc get pods -n openshift-ingress -l app=payload-processing # 1/1 Running
curl -sk "${MAAS_GW}/maas-api/health"                      # healthy
```

---

# PART 3 — AWS Bedrock setup

## 3.1 Choose a Mantle region

The Mantle endpoint is not in every region. Currently offered in:

**US East** (N. Virginia, Ohio) · **US West** (Oregon) · **Asia Pacific** (Jakarta, Mumbai, Sydney, Tokyo) · **Europe** (Frankfurt, Ireland, London, Milan, Stockholm) · **South America** (São Paulo)

For an Israeli customer, **`eu-central-1` (Frankfurt)** or **`eu-west-1` (Ireland)** are the usual picks for production. This runbook uses **`us-east-1`**, which is where the PoC key was validated. Confirm the data-residency answer with their compliance people before you build anything — this is the question that kills these projects late.

Verify your region is live:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models"
# 401/403 = endpoint exists (you just have no key yet). 000/404 = wrong region.
```

## 3.2 Model access

Bedrock now grants **automatic access to serverless models** in your Region — the old per-model "Model access" enablement page is retired, along with the `PutFoundationModelEntitlement` IAM permission. Models still blocked by IAM policies or SCPs remain blocked.

**Exception:** a subset of models offered through AWS Marketplace still require a subscription before first use. If a specific model 403s, check the Marketplace subscription status on its model card.

**Console:** **Bedrock → Model catalog** — review each model's card, EULA, Regional availability, and whether it is Marketplace-gated.

## 3.3 Understanding the IAM user question

You said you're not sure about IAM users. Here is what actually happens.

A **long-term Bedrock API key** is an IAM *service-specific credential*, which means it must be attached to an **IAM user**. There is no way around this — it is how the credential type works.

When you generate one from the Bedrock console, AWS **silently creates a new IAM user** for you, named `BedrockAPIKey-xxxx`, and attaches the `AmazonBedrockLimitedAccess` managed policy. You will see the ABSK key and the generated username in the result, but there is no separate confirmation step for the user creation.

**This matters for two reasons:**

1. **If the customer has an SCP banning IAM user creation** (common in mature AWS orgs), console generation will fail. Fallback: attach the service-specific credential to an *existing* IAM user instead (§3.5 CLI path).
2. **Their security team will find the phantom user in an audit** and ask what it is. Get ahead of it — name it deliberately via the CLI path, tag it, and document it.

Check whether you can create IAM users at all:

```bash
aws iam create-user --user-name bedrock-scp-test --dry-run 2>&1 || true
aws sts get-caller-identity
aws organizations describe-organization 2>/dev/null   # are you in an Org with SCPs?
```

Three governance condition keys exist if the customer wants to constrain this centrally: `iam:ServiceSpecificCredentialServiceName` (which services may have service-specific credentials), `iam:ServiceSpecificCredentialAgeDays` (max key lifetime), and one governing key type.

## 3.4 Generate the key — Console

1. Sign in and open **Amazon Bedrock** → left nav → **API keys**
2. Choose the tab:
   - **Short-term API keys** — expires with your console session, max 12 hours. Good for a quick test, useless for a running gateway.
   - **Long-term API keys** — what you need here.
3. On the Long-term tab, **Generate long-term API keys**
4. Set an **expiration** (90 days is a reasonable default; shorter is better)
5. Optionally expand **Advanced permissions** to attach additional policies
6. **Generate**
7. **Copy the key immediately** — it starts with `ABSK` and is shown once
8. **Validate it** using the length/prefix check in §3.5 before doing anything else

## 3.5 Generate the key — CLI

This path gives you control over the IAM username, which is what you want for a customer engagement.

```bash
# Create a deliberately-named user
aws iam create-user \
  --user-name rhoai-maas-bedrock \
  --tags Key=Purpose,Value=RHOAI-MaaS-Gateway Key=Owner,Value=platform-team

# Attach the managed policy (tighten this in §3.6)
aws iam attach-user-policy \
  --user-name rhoai-maas-bedrock \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockLimitedAccess

# Generate the long-term ABSK key
aws iam create-service-specific-credential \
  --user-name rhoai-maas-bedrock \
  --service-name bedrock.amazonaws.com \
  --credential-age-days 90
```

### Which field is the key

The ABSK key is in **`ServiceSpecificCredential.ServiceCredentialSecret`**. **It is shown once.**

> **Field name warning.** AWS has renamed this field across API versions and the docs lag behind the API. Depending on your CLI version you may see `ServiceCredentialSecret`, `ServiceApiKeyValue` (what the current AWS docs and Python examples show), or a legacy `ServicePassword` inherited from the CodeCommit-era version of this API. **Do not go by field name — go by content.** The key is the one value in the response that begins with `ABSK`. Some responses contain more than one secret-looking field, and picking the wrong one produces a valid-looking string that Bedrock rejects with `invalid_api_key` / *"Invalid bearer token"*.

Other fields in the response are metadata, not the key: `ServiceCredentialAlias` (e.g. `rhoai-maas-bedrock-at-<account-id>`), `ServiceSpecificCredentialId` (starts with `ACCA`, used for reset/delete), `Status`, `CreateDate`, `ExpirationDate`.

### Capture and validate the key

Copy the `ABSK...` value from the output, then:

```bash
read -rs BEDROCK_API_KEY && export BEDROCK_API_KEY   # paste, press Enter; nothing echoes
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4} tail=${BEDROCK_API_KEY: -6}"
```

**Validate all three before going any further:**

| Check | Expected | If wrong |
|---|---|---|
| `prefix` | `ABSK` | You copied the wrong field. Find the `ABSK` value. |
| `len` | **132** | **131 or fewer = truncated copy.** Re-copy. This is the single most common failure in this whole procedure. |
| `tail` | matches the last 6 chars of the source | Mid-string mangle — re-copy. |

> **A 131-character key looks completely legitimate.** Right prefix, plausible length, and AWS rejects it with a `permission_denied_error`, which sends you off investigating IAM policies and SCPs. Check the length first; it costs one second and it is the answer more often than anything else.
>
> Prefix and length together still pass on a key that had a character *substituted* rather than dropped, which is why the `tail` comparison is worth the extra look.

Confirm the credential registered:

```bash
aws iam list-service-specific-credentials \
  --user-name rhoai-maas-bedrock \
  --service-name bedrock.amazonaws.com
```

Expect `Status: Active`. Note the `ServiceSpecificCredentialId` — you need it to reset or delete the key later. Newly created credentials are not instantly consistent; if a call fails within the first minute of creation, wait and retry before assuming anything is broken.

### If you lost the key or it was truncated

The value cannot be retrieved after creation. Reset it in place:

```bash
aws iam reset-service-specific-credential \
  --user-name rhoai-maas-bedrock \
  --service-specific-credential-id <ServiceSpecificCredentialId>
```

This returns a fresh secret. Re-run the validation above.

> An IAM user can hold **up to two** long-term Bedrock keys. That is deliberate — it lets you rotate without downtime: create the second, roll the cluster Secret, then delete the first.

## 3.6 Tighten permissions

**Skip this for a throwaway PoC account.** `AmazonBedrockLimitedAccess` already grants everything Mantle needs (see §3.3), so a working key keeps working and you avoid re-breaking the one thing that functions. Come back here before anything touches a real account.

### Why it matters on a real account

`AmazonBedrockLimitedAccess` is far broader than "call a model." Read the current policy document and the gateway user also gets:

| Granted action | Risk |
|---|---|
| `bedrock:CreateProvisionedModelThroughput` | Commits real hourly spend |
| `bedrock:CreateModelCustomizationJob`, `CreateModelImportJob`, `CreateEvaluationJob` | Training / evaluation spend |
| `bedrock:DeleteGuardrail`, `UpdateGuardrail` | Can dismantle safety controls the customer built |
| `aws-marketplace:Subscribe` | Can subscribe the account to paid third-party models |
| `ec2:DescribeVpcs`, `DescribeSubnets`, `DescribeSecurityGroups`, `iam:ListRoles` | Network and identity reconnaissance |

Now recall where this credential lives: a long-lived key in a Kubernetes Secret, readable by anyone with RBAC on that namespace, valid for up to 90 days. That is exactly the credential you want minimally scoped, and it is the first thing a security review will raise.

### Use the AWS-managed Mantle policy

`AmazonBedrockMantleInferenceAccess` was created specifically for this and is the narrowest managed policy sufficient for Mantle inference. It covers both SigV4 and API-key auth:

```json
{
  "Sid": "BedrockMantleInference",
  "Effect": "Allow",
  "Action": ["bedrock-mantle:Get*", "bedrock-mantle:List*", "bedrock-mantle:CreateInference"],
  "Resource": "arn:aws:bedrock-mantle:*:*:project/*"
},
{
  "Sid": "BedrockMantleCallWithBearerToken",
  "Effect": "Allow",
  "Action": ["bedrock-mantle:CallWithBearerToken"],
  "Resource": "*"
}
```

**Attach first, detach second.** Reversing the order leaves the key with zero permissions in between.

```bash
aws iam attach-user-policy \
  --user-name rhoai-maas-bedrock \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockMantleInferenceAccess

aws iam detach-user-policy \
  --user-name rhoai-maas-bedrock \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockLimitedAccess

# Confirm the key still works BEFORE walking away
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" | jq -r '.data[0].id'
```

**Console:** **Bedrock → API keys → Long-term API keys →** select the key **→ Manage in IAM Console → Permissions →** add `AmazonBedrockMantleInferenceAccess`, then remove `AmazonBedrockLimitedAccess`.

### Hand-rolled policy

If the customer wants the account and region pinned:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "MantleInference",
      "Effect": "Allow",
      "Action": ["bedrock-mantle:CreateInference", "bedrock-mantle:Get*", "bedrock-mantle:List*"],
      "Resource": "arn:aws:bedrock-mantle:us-east-1:<ACCOUNT-ID>:project/*" },
    { "Sid": "BearerTokenAuth",
      "Effect": "Allow",
      "Action": ["bedrock-mantle:CallWithBearerToken"],
      "Resource": "*" }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name rhoai-maas-bedrock \
  --policy-name RhoaiMaasBedrockInference \
  --policy-document file://bedrock-inline.json
```

> **`bedrock-mantle:CallWithBearerToken` is mandatory and easy to miss.** It authorizes using an API key as a bearer token at all. Omit it and every call fails with `invalid_api_key` / *"Invalid bearer token"* — indistinguishable from a truncated key, and you will waste an afternoon on it. It is also not resource-scopable; it must stay on `Resource: "*"`.
>
> `bedrock-mantle:Get*` and `List*` are needed for `/v1/models`. Drop them and model discovery breaks while inference still works.

### Two related decisions

**Marketplace-gated models.** The managed policy contains no `aws-marketplace:Subscribe`, so a third-party model may 403 on first call. Do **not** add that action to the gateway user — subscribe once, out of band, with an admin identity. A credential living in a cluster Secret should never be able to commit the account to paid services.

**Never leave `iam:CreateServiceSpecificCredential` on this user.** A principal holding that permission plus `bedrock-mantle:CreateInference` can mint itself a service-specific credential and reach models that SCP-based restrictions were meant to block — a documented SCP-bypass path. The gateway user does not need it; you created its key from your admin identity.


## 3.7 Test the key from your laptop

**Do this before touching OpenShift.** If this fails, nothing downstream will work and you will waste an hour debugging the wrong layer.

**Re-validate the key before you test.** If this check does not pass, fix it here — everything below will fail in ways that look like other problems.

```bash
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"
# len=132 prefix=ABSK
```

```bash
export AWS_REGION="us-east-1"

# List available models in this region
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" | jq -r '.data[] | "\(.id)  [\(.status)]"'

# Pick one from the list above
export TARGET_MODEL="openai.gpt-oss-20b"

curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${TARGET_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

A successful response has a `choices` array with non-null `message.content`.

> **`max_tokens` must be generous — 300, not 20.** Reasoning models such as `gpt-oss-20b` emit a `reasoning` field before `content`, and those tokens count against `max_tokens`. With a small budget you get `finish_reason: "length"` and `content: null`, which looks like a broken integration but is only a truncated answer. Check `usage.completion_tokens` — if it exactly equals your `max_tokens`, that is what happened.

### Reading the model list

Each entry carries a `status` (`available` / `unavailable`) and a `data_retention` block with `allowed_modes` of `none`, `default`, and `provider_data_share`. Some models are `unavailable` specifically because they are not offered under the account's current retention mode.

That field is the concrete answer to *"where do our prompts go?"* — which means **model availability is partly a governance decision, not just a technical one**. Surface this with the customer early, especially anywhere data residency is in play. Confirm whether retention mode can be pinned per model via the `ExternalModel` CR or the payload processor, or whether it always inherits the account default.

| Failure | Meaning |
|---|---|
| `invalid_api_key` / *"Invalid bearer token"* | **Check key length first (§3.5).** A truncated 131-char key gives exactly this. Then: wrong field copied, key expired, credential not yet propagated, or an SCP denying `bedrock-mantle:CallWithBearerToken`. |
| `403` | IAM policy too narrow, or an SCP is blocking Bedrock |
| `404` | Wrong endpoint (`bedrock-runtime` instead of `bedrock-mantle`), or the model is not on Mantle in this region |
| `400` | Model ID not available in this region — re-check the `/v1/models` output |
| `<UnknownOperationException/>` | That operation does not exist at that path. Not an auth failure — the request never reached authentication. |
| `choices[0].message.content` is `null` | Not a failure. Reasoning model ran out of `max_tokens` — raise it. |

### Isolating a stubborn auth failure

If the key validates but calls still fail, work down this ladder. Each step rules out a layer:

1. **Confirm the credential is `Active`** and note its age — `aws iam list-service-specific-credentials`. Under a minute old? Wait and retry.
2. **Re-extract the key** via `reset-service-specific-credential` and re-validate length. Do this *before* investigating anything more exotic.
3. **Try another region** (`us-east-1` is the safest) to rule out regional enablement.
4. **Check who you are** — `aws sts get-caller-identity`. Note that `AWS_BEARER_TOKEN_BEDROCK` with the AWS CLI may be ignored in favour of ambient SigV4 credentials, so a *successful* CLI call does not prove your bearer token works. Test bearer tokens with `curl`, not the CLI.
5. **Suspect an SCP only after the above.** In an AWS Organization, this published guardrail denies exactly this and produces identical symptoms to a bad key:
   ```json
   { "Effect": "Deny",
     "Action": ["bedrock:CallWithBearerToken", "bedrock-mantle:CallWithBearerToken"],
     "Resource": "*",
     "Condition": { "StringEquals": { "bedrock:bearerTokenType": "LONG_TERM" } } }
   ```
   Confirm by generating a **short-term** key (Bedrock console → API keys → Short-term, or the `aws-bedrock-token-generator` package) and repeating the call. Short-term works while long-term fails ⇒ SCP. `organizations:DescribeOrganization` returning AccessDenied proves nothing — sandbox users rarely hold that permission either way.

   If an SCP is confirmed, no console workaround exists — SCPs are evaluated above IAM and apply to console sessions too. You need a different AWS account. Raise it with the customer: if their org runs the same guardrail, this integration pattern is blocked for them and that shapes the design.

---

---

# PART 4 — Wire Bedrock into RHOAI

Part 2 built the gateway. Part 3 proved the AWS credential. Now you attach one to the other.

Nothing here deploys a model. You are registering an external endpoint and declaring who may call it and how much.

## 4.1 Namespace

```bash
export MODEL_NS="external-models"
oc create namespace ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -

# Apply the label — harmless, and required if your Gateway selects by label
oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite

oc get namespace ${MODEL_NS} --show-labels

# CRITICAL on 3.5 GA: the platform Gateway may select namespaces by NAME, not label.
# Confirm external-models is admitted before going further:
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.spec.listeners}' | jq .
```

**Console:** **Home → Projects → Create Project**, then **Administration → Namespaces →** select → **Edit labels**.

> No error is raised if the namespace is not admitted. The `MaaSModelRef` simply never reaches Ready and the endpoint 404s. **This is the first thing to check when anything in Part 4 fails.**
>
> On 3.5 GA the reference cluster's Gateway used `matchExpressions` on `kubernetes.io/metadata.name` — an explicit namespace-name allowlist. The label does nothing there. Use the mechanism you recorded in §2.8 discovery.

## 4.2 Credential Secret

Three requirements, all mandatory:

1. Same namespace as the `ExternalModel`
2. Data key exactly `api-key`
3. Label `inference.networking.k8s.io/bbr-managed=true`

**Re-validate the key before it goes in.** A truncated key stored in a Secret surfaces later as an opaque 401 from AWS buried in payload-processor logs — far more expensive to diagnose here than in §3.5.

```bash
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"
# len=132 prefix=ABSK  — anything else, go back to §3.5
```

```bash
oc create secret generic bedrock-api-key \
  --from-literal=api-key="${BEDROCK_API_KEY}" \
  -n ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -

oc label secret bedrock-api-key -n ${MODEL_NS} \
  inference.networking.k8s.io/bbr-managed=true --overwrite

oc get secret bedrock-api-key -n ${MODEL_NS} --show-labels
oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' | base64 -d | wc -c
# 132
```

**Console:** **Workloads → Secrets → Create → Key/value secret** in `external-models`. Name `bedrock-api-key`, key `api-key`. Then **Actions → Edit labels**.

> Never commit this to Git. For GitOps, use External Secrets Operator or Sealed Secrets. The `ExternalModel` CR itself is safe to commit — it holds only a `credentialRef`.

## 4.3 ExternalModel + MaaSModelRef

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: bedrock-gpt-oss-20b
  namespace: ${MODEL_NS}
spec:
  provider: bedrock-openai
  targetModel: ${TARGET_MODEL}
  endpoint: bedrock-mantle.${AWS_REGION}.api.aws
  credentialRef:
    name: bedrock-api-key
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: bedrock-gpt-oss-20b
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: bedrock-gpt-oss-20b
EOF
```

Check the API version against your cluster first, since 3.5 GA moved other MaaS fields:

```bash
oc get crd externalmodels.maas.opendatahub.io -o jsonpath='{.spec.versions[*].name}{"\n"}'
oc explain externalmodel.spec
```

If `oc explain externalmodel.spec` shows `provider`, `endpoint`, `targetModel`, `credentialRef`, the YAML above is correct as written.

### Field reference

| Field | Value | Notes |
|---|---|---|
| `spec.provider` | `bedrock-openai` | Selects the BBR translator. Others: `openai`, `anthropic`, `azure-openai`, `vertex-openai` |
| `spec.endpoint` | `bedrock-mantle.us-east-1.api.aws` | **Hostname only — no scheme, no path.** |
| `spec.targetModel` | `openai.gpt-oss-20b` | Exactly as returned by `/v1/models` |
| `spec.credentialRef.name` | `bedrock-api-key` | Same namespace |

For `bedrock-openai` the translator is **pass-through** — no body translation, auth via `Authorization: Bearer`. This is why Bedrock-via-Mantle is the cleanest external provider to integrate.

### What the reconciler creates

`Service` (ExternalName) · `ServiceEntry` · `DestinationRule` (TLS origination) · `HTTPRoute`

### Verify

```bash
oc get externalmodel,maasmodelref -n ${MODEL_NS}
```

Want `PHASE: Ready` with an ENDPOINT, HTTPROUTE, and GATEWAY populated. If not:

```bash
oc describe externalmodel bedrock-gpt-oss-20b -n ${MODEL_NS}
oc describe maasmodelref bedrock-gpt-oss-20b -n ${MODEL_NS}
oc get httproute,serviceentry,destinationrule -n ${MODEL_NS}
```

**Console:** **CustomResourceDefinitions** → search `ExternalModel` → **Instances → Create**. Or masthead **+** → **Import YAML** and paste both documents at once.

## 4.4 Add a second model

Demo 2 is "swap models without touching the client." That needs at least two. Anthropic Claude through Bedrock is the compelling one — same commercial relationship, no separate vendor contract:

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: bedrock-claude-sonnet
  namespace: ${MODEL_NS}
spec:
  provider: bedrock-openai
  targetModel: anthropic.claude-sonnet-5
  endpoint: bedrock-mantle.${AWS_REGION}.api.aws
  credentialRef:
    name: bedrock-api-key
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: bedrock-claude-sonnet
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: bedrock-claude-sonnet
EOF
```

Confirm the model ID is available in your region first:

```bash
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  | jq -r '.data[] | select(.status=="available") | .id' | sort
```

> **Model choice for the demo.** `gpt-oss-20b` is a reasoning model — it emits reasoning tokens that count against `max_tokens` and against your metering. The analyst sees three words and the chargeback report shows hundreds of tokens, which muddies the metering story. Use `anthropic.claude-sonnet-5` or `anthropic.claude-haiku-4-5` for anything customer-facing; keep `gpt-oss-20b` for cheap plumbing tests.

## 4.5 Access policy and quota

These live in the **`models-as-a-service`** namespace, not the model namespace.

Two subscription tiers make the quota story visible — a generous one for the demo and a deliberately tiny one you can exhaust live.

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: bedrock-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: bedrock-gpt-oss-20b
      namespace: ${MODEL_NS}
    - name: bedrock-claude-sonnet
      namespace: ${MODEL_NS}
  subjects:
    groups:
      - name: "system:authenticated"
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
  modelRefs:
    - name: bedrock-gpt-oss-20b
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100000
          window: "1h"
    - name: bedrock-claude-sonnet
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100000
          window: "1h"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: analysts-trial
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: "system:authenticated"
  modelRefs:
    - name: bedrock-gpt-oss-20b
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 500
          window: "1h"
EOF

oc get maasauthpolicy,maassubscription -n models-as-a-service
```

- **`MaaSAuthPolicy`** — *who may call this model*. Enforced by Authorino.
- **`MaaSSubscription`** — *how many tokens they get*. Enforced by Limitador.

For the real engagement, replace `system:authenticated` with actual OpenShift or OIDC groups and create one subscription per department. That is the chargeback boundary.

**Console:** RHOAI dashboard → **Models as a Service** offers a subscription form with a *Create matching authorization policy* checkbox. Otherwise **Import YAML**.

## 4.6 Smoke test

```bash
export MAAS_GW="https://$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')"

# Model appears in the catalog
curl -sk "${MAAS_GW}/maas-api/v1/models" \
  -H "Authorization: Bearer $(oc whoami -t)" | jq -r '.data[].id'

# Mint an API key
API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"demo-key","subscription":"analysts-standard","expiresIn":"24h"}' | jq -r '.key')
echo "${API_KEY:0:12}..."

# Inference
curl -sk "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Say hello in 3 words."}],"max_tokens":300}' | jq .
```

Path structure: `https://maas.<domain>/<model-namespace>/<model-name>/v1/chat/completions`

> **`max_tokens` generously — 300, not 20.** Reasoning models spend the budget on reasoning tokens and return `finish_reason: "length"` with `content: null`, which looks like a broken integration but is only a truncated answer. If `usage.completion_tokens` equals your `max_tokens`, that is what happened.

Save the key — Part 5 and Part 6 use it.

---

# PART 5 — Guardrails

Part 4 gave you **access** control: who can call, how much, revocable. Part 5 adds **content** control: what may be sent and what may come back.

For a customer sending analyst queries from Israel to a US-region Bedrock endpoint, "PII never leaves the cluster" is a stronger data-residency answer than anything in Part 4.

## 5.1 How it fits together

```
Analyst → Guardrails Orchestrator → MaaS Gateway → Bedrock
              │
              ├── regex detectors  (sidecar, no model)     ← §5.3
              └── HAP detector     (CPU model on KServe)   ← §5.5
```

The orchestrator is a `GuardrailsOrchestrator` CR managed by the TrustyAI operator, built on IBM's open-source FMS-Guardrails Orchestrator. It runs detectors over the prompt and over the response, and blocks or flags.

It talks to the MaaS gateway as an ordinary OpenAI-compatible upstream, forwarding the caller's MaaS key via `passthrough_headers`. Red Hat documents this pattern explicitly for external providers — OpenAI, Azure OpenAI, Gemini, "or other MaaS providers".

**Two detector families, and you want both:**

| | Regex detectors | HAP detector |
|---|---|---|
| What | HTTP sidecars matching patterns | `ibm-granite/granite-guardian-hap-38m` classifier |
| Runs on | Sidecar in the orchestrator pod | KServe InferenceService, **CPU-viable at 38M params** |
| Catches | PII — emails, cards, IDs | Hate, abuse, profanity — semantic, not pattern |
| Cost | Nothing | One small pod |
| Demo value | "This ID number never left the building" | "This model refused a toxic prompt" |

Start with regex (§5.3). Add HAP (§5.5) once that works.

> **Prerequisite:** `trustyai: Managed` in the DSC (§2.7) and Part 4 working end to end. Do not debug guardrails and MaaS at the same time.

```bash
oc get pods -n redhat-ods-applications | grep -i trustyai
oc get crd | grep -i guardrails
```

## 5.2 Namespace

```bash
export GR_NS="guardrails"
oc create namespace ${GR_NS} --dry-run=client -o yaml | oc apply -f -
oc label namespace ${GR_NS} maas.opendatahub.io/gateway-access=true --overwrite
```

## 5.3 Orchestrator with regex detectors

The orchestrator reads a ConfigMap describing its generator (upstream LLM) and its detectors.

```bash
# Upstream host = the MaaS gateway host, WITHOUT the https:// scheme
export MAAS_HOST=$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')
echo "orchestrator will call: $MAAS_HOST"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fms-orchestr8-config-nlp
  namespace: ${GR_NS}
data:
  config.yaml: |
    passthrough_headers:
      - authorization
    openai:
      service:
        hostname: ${MAAS_HOST}
        port: 443
        tls: maas_upstream
    detectors:
      regex:
        type: text_contents
        service:
          hostname: "127.0.0.1"
          port: 8080
        chunker_id: whole_doc_chunker
        default_threshold: 0.5
    tls:
      maas_upstream:
        insecure: true
EOF
```

**`passthrough_headers: [authorization]`** is the critical line — it forwards the caller's MaaS key to the gateway. Without it the orchestrator calls MaaS unauthenticated and gets 401.

`insecure: true` is acceptable for a PoC on the default ingress certificate. For production, mount the cluster CA bundle and set `cert_path` instead.

Then the orchestrator itself, with the built-in detector and gateway sidecars enabled:

```bash
cat <<EOF | oc apply -f -
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: GuardrailsOrchestrator
metadata:
  name: guardrails-orchestrator
  namespace: ${GR_NS}
spec:
  replicas: 1
  orchestratorConfig: fms-orchestr8-config-nlp
  enableBuiltInDetectors: true
  enableGuardrailsGateway: true
  guardrailsGatewayConfig: fms-orchestr8-config-gateway
EOF
```

The **Guardrails Gateway** sidecar is what makes this demo-able: it presents a standard OpenAI `v1/chat/completions` API with named preset pipelines, so the client changes only its base URL — no API changes at all.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fms-orchestr8-config-gateway
  namespace: ${GR_NS}
data:
  config.yaml: |
    orchestrator:
      host: "localhost"
      port: 8032
    detectors:
      - name: regex
        input: true
        output: true
        detector_params:
          regex:
            - email
            - credit-card
            - ssn
    routes:
      - name: pii
        detectors:
          - regex
      - name: passthrough
        detectors: []
EOF
```

That gives you two endpoints on the same orchestrator: `/pii` (filtered) and `/passthrough` (not) — a clean side-by-side for the demo.

### Verify

```bash
oc get guardrailsorchestrator -n ${GR_NS}
oc get pods -n ${GR_NS}
oc logs -n ${GR_NS} deployment/guardrails-orchestrator --tail=50
```

> **Verify the CR shape against your cluster.** The GuardrailsOrchestrator API has moved across releases, and 3.5 GA docs still render EA2 titles. Run `oc explain guardrailsorchestrator.spec` and cross-check field names against `.../3.5/html/enabling_ai_safety_with_guardrails/index` before assuming the YAML above is exact. The architecture is right; the field names are what to confirm.
>
> **Guardrails AutoConfig is Development Preview.** Manual `orchestratorConfig` — what is above — is the supported path. Do not build a customer demo on autoConfig.

## 5.4 Expose the guardrailed lane

```bash
oc expose deployment guardrails-orchestrator -n ${GR_NS} \
  --name=guardrails-gateway --port=8090 2>/dev/null || true

oc get svc -n ${GR_NS}
```

Then either create an HTTPRoute on the MaaS Gateway, or a plain Route for the PoC:

```bash
oc create route reencrypt guardrails -n ${GR_NS} \
  --service=guardrails-gateway --port=8090 2>/dev/null || \
oc create route edge guardrails -n ${GR_NS} --service=guardrails-gateway --port=8090

export GR_URL="https://$(oc get route guardrails -n ${GR_NS} -o jsonpath='{.spec.host}')"
echo $GR_URL
```

### Test both lanes

```bash
# Clean prompt through the PII pipeline — should pass through to Bedrock
curl -sk "${GR_URL}/pii/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"What is the capital of France?"}],"max_tokens":300}' | jq .

# Prompt containing PII — should be blocked or redacted before leaving the cluster
curl -sk "${GR_URL}/pii/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Email john.smith@acme.com about card 4111-1111-1111-1111"}],"max_tokens":300}' | jq .
```

The second call is the demo moment. Show the customer that the request never reached AWS.

## 5.5 HAP detector on CPU

Regex catches patterns. This catches meaning. `ibm-granite/granite-guardian-hap-38m` is 38M parameters — genuinely CPU-viable, no GPU required.

### Serving runtime

```bash
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: guardrails-detector-runtime-hap
  namespace: ${GR_NS}
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
  containers:
    - name: kserve-container
      image: quay.io/rh-ee-mmisiura/guardrails-detector-huggingface-runtime:latest
      command: ["uvicorn", "app:app"]
      args:
        - "--workers=1"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--log-config=/common/log_conf.yaml"
      env:
        - name: MODEL_DIR
          value: /mnt/models
        - name: HF_HOME
          value: /tmp/hf_home
      ports:
        - containerPort: 8000
          protocol: TCP
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
  multiModel: false
  supportedModelFormats:
    - name: guardrails-detector-hf-runtime
      autoSelect: true
EOF
```

> Check the current runtime image reference in the 3.5 guardrails documentation before running this. Red Hat has shipped this runtime under several registry paths, and a stale image reference is the most likely reason this step fails.

### InferenceService

The model must be reachable — either an OCI ModelCar image or an S3/MinIO bucket via a storage-config secret. On this connected sandbox, the OCI route is simplest:

```bash
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: guardrails-detector-hap
  namespace: ${GR_NS}
  annotations:
    serving.knative.openshift.io/enablePassthrough: "true"
    sidecar.istio.io/inject: "true"
spec:
  predictor:
    model:
      runtime: guardrails-detector-runtime-hap
      modelFormat:
        name: guardrails-detector-hf-runtime
      storageUri: oci://quay.io/repository/rh-ee-mmisiura/granite-guardian-hap-38m:latest
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
EOF

oc get inferenceservice -n ${GR_NS} -w
```

Wait for `READY True`. If the model URI 404s, pull the current one from the 3.5 guardrails docs — Red Hat has moved these images between registries.

### Register it with the orchestrator

```bash
oc patch configmap fms-orchestr8-config-nlp -n ${GR_NS} --type=merge -p "$(cat <<'EOF'
{"data":{"config.yaml":"passthrough_headers:\n  - authorization\nopenai:\n  service:\n    hostname: MAAS_HOST\n    port: 443\n    tls: maas_upstream\ndetectors:\n  regex:\n    type: text_contents\n    service:\n      hostname: \"127.0.0.1\"\n      port: 8080\n    chunker_id: whole_doc_chunker\n    default_threshold: 0.5\n  hap:\n    type: text_contents\n    service:\n      hostname: guardrails-detector-hap-predictor\n      port: 80\n    chunker_id: whole_doc_chunker\n    default_threshold: 0.5\ntls:\n  maas_upstream:\n    insecure: true\n"}}
EOF
)"

# Substitute the real hostname
oc get configmap fms-orchestr8-config-nlp -n ${GR_NS} -o yaml \
  | sed "s/MAAS_HOST/${MAAS_HOST}/" | oc apply -f -

oc rollout restart deployment/guardrails-orchestrator -n ${GR_NS}
oc rollout status deployment/guardrails-orchestrator -n ${GR_NS} --timeout=300s
```

Add a `hap` route to the gateway ConfigMap alongside `pii`, then test:

```bash
curl -sk "${GR_URL}/hap/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Write something abusive about my coworker"}],"max_tokens":300}' | jq .
```

Blocked before it reaches AWS is the result you want.

## 5.6 Close the bypass

Right now an analyst can skip guardrails by calling the MaaS URL directly. Fix it at the authorization layer: restrict the direct lane to the orchestrator's ServiceAccount, and give analysts only the guardrailed lane.

```bash
oc get pods -n ${GR_NS} -l app=guardrails-orchestrator \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

Then narrow the `MaaSAuthPolicy` from §4.5:

```yaml
spec:
  subjects:
    serviceAccounts:
      - name: <orchestrator-sa>
        namespace: guardrails
```

Verify the field name first — `oc explain maasauthpolicy.spec.subjects` — since the schema may only support `groups` and `users`, in which case bind the orchestrator's SA to a dedicated group instead.

Demo it: the analyst's key against the direct MaaS URL now returns **403**, and against the guardrailed URL returns a completion. That is governance the customer can see.

---

# PART 6 — Verification and the demo

Run this end to end before showing anyone. Each check maps to a customer objection.

## 6.1 Platform health

```bash
oc get gateway -n openshift-ingress                          # PROGRAMMED=True
oc get pods -n kuadrant-system                               # authorino, limitador Running
oc get pods -n openshift-ingress -l app=payload-processing   # 1/1 Running
oc get externalmodel,maasmodelref -n ${MODEL_NS}             # PHASE Ready
oc get maasauthpolicy,maassubscription -n models-as-a-service
oc get guardrailsorchestrator -n ${GR_NS}
curl -sk "${MAAS_GW}/maas-api/health"
```

## 6.2 Demo 1 — Workbench

This is the strongest opener: it looks exactly like what the analysts already do.

**Use the workbench created in §2.7.** If you skipped that smoke test, create it now: RHOAI dashboard → **Data Science Projects → Create project** (`bedrock-demo`) → **Workbenches → Create workbench**. Image *Standard Data Science*, size Small, 20Gi storage.

```bash
oc get pods -n bedrock-demo    # notebook pod Running
```

**Mint a key for the notebook:**

```bash
curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"workbench-demo","subscription":"analysts-standard","expiresIn":"24h"}' | jq -r '.key'
```

**In the notebook:**

```python
!pip install openai --quiet

from openai import OpenAI

MAAS_GW = "https://maas.<cluster-domain>"
API_KEY = "<paste the MaaS key>"

client = OpenAI(
    base_url=f"{MAAS_GW}/external-models/bedrock-claude-sonnet/v1",
    api_key=API_KEY,
)

resp = client.chat.completions.create(
    model="bedrock-claude-sonnet",
    messages=[{"role": "user", "content": "Summarise the risks of long-lived API keys in three bullets."}],
    max_tokens=300,
)
print(resp.choices[0].message.content)
print("tokens:", resp.usage.total_tokens)
```

**The point to make out loud:** this is the standard OpenAI SDK, unmodified. Two lines changed — `base_url` and `api_key`. No AWS SDK, no AWS credential, no boto3, nothing region-specific. And `resp.usage.total_tokens` is now also a line in someone's chargeback report.

**Then swap the model** — change `bedrock-claude-sonnet` to `bedrock-gpt-oss-20b` in both places and re-run. Same code, different provider model, no client redeployment. That is Demo 2's punchline delivered from inside Demo 1.

## 6.3 Demo 2 — Governed access

Run these on camera:

```bash
# Bogus key → 403. Only org-issued credentials work.
curl -sk -o /dev/null -w "bogus key:  %{http_code}\n" \
  "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Authorization: Bearer sk-FAKE" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'

# No auth → 401. Nothing is anonymous.
curl -sk -o /dev/null -w "no auth:    %{http_code}\n" \
  "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'

# Quota headers — the consumer can see their own budget
curl -sk -D - -o /dev/null \
  "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' \
  | grep -i ratelimit
```

**Exhaust a quota live.** Mint a key on `analysts-trial` (500 tokens/hour) and loop until it 429s:

```bash
TRIAL=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"trial","subscription":"analysts-trial","expiresIn":"1h"}' | jq -r '.key')

for i in $(seq 1 10); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    "${MAAS_GW}/${MODEL_NS}/bedrock-gpt-oss-20b/v1/chat/completions" \
    -H "Authorization: Bearer ${TRIAL}" -H "Content-Type: application/json" \
    -d '{"model":"bedrock-gpt-oss-20b","messages":[{"role":"user","content":"Write a paragraph about clouds."}],"max_tokens":200}')
  echo "call $i: $code"
done
```

Watching it flip to 429 is far more persuasive than a slide claiming quotas exist.

**Revoke a key** — the point being that no AWS credential rotates:

```bash
curl -sk "${MAAS_GW}/maas-api/v1/api-keys" -H "Authorization: Bearer $(oc whoami -t)" | jq .
curl -sk -X DELETE "${MAAS_GW}/maas-api/v1/api-keys/<id>" -H "Authorization: Bearer $(oc whoami -t)"
```

**Observability:** RHOAI dashboard → **Observability**, showing per-team tokens, request rate, latency, errors.

## 6.4 Demo 3 — Guardrails

```bash
# Clean prompt, guardrailed lane → completion
curl -sk "${GR_URL}/pii/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"What is the capital of France?"}],"max_tokens":300}' | jq -r '.choices[0].message.content'

# PII prompt → blocked, never reaches AWS
curl -sk "${GR_URL}/pii/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Contact john.smith@acme.com re card 4111-1111-1111-1111"}],"max_tokens":300}' | jq .

# Toxic prompt → HAP classifier blocks it
curl -sk "${GR_URL}/hap/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Write something abusive about my coworker"}],"max_tokens":300}' | jq .

# Direct MaaS URL with the analyst key → 403 (bypass closed, §5.6)
curl -sk -o /dev/null -w "bypass attempt: %{http_code}\n" \
  "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'
```

## 6.5 The security proof — verify header stripping functionally

Authorino validates the caller's credential and **strips the Authorization header before forwarding**; the Bedrock ABSK key is injected separately from the Kubernetes Secret. The user's token never reaches AWS and the AWS key never reaches the user.

This requires Authorino 0.23.1+. **The runtime version is not readable** (see §2.3), so verify the behaviour rather than the version. This is a required gate, not an optional extra — the whole customer pitch rests on it.

```bash
# Watch what the payload processor forwards upstream
oc logs -n openshift-ingress -l app=payload-processing -f --tail=0 &

# Send a request with a recognisable key
curl -sk "${MAAS_GW}/${MODEL_NS}/bedrock-claude-sonnet/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' >/dev/null

sleep 3; kill %1
```

What you are checking: the outbound request carries the **ABSK** credential, not the caller's MaaS key. If IPP logs redact headers, prove it from the other end instead — temporarily point an `ExternalModel` at a request-echo service you control (`endpoint: <your-echo-host>`) and inspect what arrives. On a customer engagement this is worth doing once, with the security team watching.

**Negative control:** delete the `bedrock-api-key` Secret's `bbr-managed` label and re-run. AWS should reject the call, proving the ABSK key is injected by IPP from the Secret rather than passed through from the client. Re-label afterwards.

```bash
oc label secret bedrock-api-key -n ${MODEL_NS} inference.networking.k8s.io/bbr-managed- 
# re-run the curl → expect an auth failure from AWS
oc label secret bedrock-api-key -n ${MODEL_NS} inference.networking.k8s.io/bbr-managed=true --overwrite
```

## 6.6 Talking points

| Check | What it proves |
|---|---|
| 403 on bogus key | Only org-issued credentials work |
| 401 with no auth | The endpoint is not open |
| `X-RateLimit-Remaining` | Quota is enforced and visible to the consumer |
| Live 429 | Spend is capped before the AWS bill, not after |
| Key revoked, AWS key untouched | Per-analyst offboarding without disruption |
| Model swapped in the notebook | Provider portability is a CR change, not a desktop rollout |
| PII blocked | Sensitive data never crosses the region boundary |
| Bypass returns 403 | Guardrails are mandatory, not advisory |
| Token metrics per team | Chargeback is real, not aspirational |

---

# PART 7 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `MaaSModelRef` not Ready | Namespace missing gateway-access label | `oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite` |
| `404` from the gateway | `bedrock-runtime` instead of `bedrock-mantle` | Fix `spec.endpoint` |
| `404`, endpoint correct | Model not on Mantle in that region | Re-check `/v1/models` |
| `invalid_api_key` from AWS | **Truncated ABSK key (131 vs 132 chars)** | `oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' \| base64 -d \| wc -c` → must be 132 |
| `401` from AWS in IPP logs | Secret missing `bbr-managed` label or wrong data key | Label `inference.networking.k8s.io/bbr-managed=true`; key must be `api-key` |
| `403` from the gateway | No matching `MaaSAuthPolicy` for caller's groups | Check `modelRefs` and `subjects` |
| `429` unexpectedly | Subscription limit too low | Raise `tokenRateLimits.limit` |
| `content: null`, `finish_reason: length` | Reasoning model exhausted `max_tokens` — not a failure | Raise to 300+ |
| No Gateway at all | DSCI not reconciled | Fix the DSCI — do NOT hand-build a Gateway on 3.5 GA (§2.5) |
| Gateway edits keep reverting | Gateway is owned by `GatewayConfig` | Patch `gatewayconfig/default-gateway`, never the Gateway (§2.5) |
| `LoadBalancerReady: False` | Normal with `ingressMode: OcpRoute` | Ignore; verify the Route instead (§2.5) |
| 404 on `/maas-api/health` | Base URL constructed, not derived | `export MAAS_GW="https://$(oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}')"` |
| HTTPRoute never attaches | Namespace not in the Gateway's name-based allowlist | Label-based access does NOT apply on 3.5 GA — see §2.8 discovery |
| `maas-api` CrashLoopBackOff | Postgres unreachable or secret missing | §2.6, §2.8 |
| No MaaS CRDs | `aigateway`/`modelsAsAService` not Managed | §2.8 — note the **AsA** spelling |
| `modelsAsService` patch rejected | CEL blocks `Removed→Managed` on the deprecated field | Use `aigateway.modelsAsAService` |
| Kuadrant `MissingDependency` | Istio race | Restart kuadrant-operator pod (§2.3) |
| `x509: certificate signed by unknown authority` from Authorino | CA bundle env vars set but nothing mounted at that path — fails open, surfaces later | §2.3(b) — create the inject-cabundle ConfigMap and mount it via the Authorino CR |
| CA bundle mount disappears after an operator change | Volume was patched on the Deployment, not the CR | Patch `authorino.spec.volumes`; the operator regenerates the Deployment |
| Mounted file exists but has the wrong name | Missing key->path mapping | service-ca injects `service-ca.crt`; env vars expect `service-ca-bundle.crt` (§2.3b) |
| `SSL_CERT_FILE` missing after an Authorino CR change | CR has no env field; `set env` edits the Deployment | Re-apply §2.3(c) and re-verify |
| Orchestrator 401 to MaaS | `passthrough_headers` missing | Add `authorization` to the list (§5.3) |
| Orchestrator can't reach detector | Wrong service hostname | `oc get svc -n ${GR_NS}` and match exactly |
| HAP InferenceService not Ready | Stale runtime or model image | Pull current refs from the 3.5 guardrails docs |

### Logs

```bash
oc logs -n redhat-ods-applications deployment/maas-api --tail=100
oc logs -n openshift-ingress -l app=payload-processing --tail=100
oc logs -n kuadrant-system deployment/authorino --tail=100
oc logs -n kuadrant-system deployment/limitador-limitador --tail=100
oc logs -n ${GR_NS} deployment/guardrails-orchestrator --tail=100
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100
oc describe datasciencecluster default-dsc
```

---

# PART 8 — Cleanup

Remove the Bedrock integration, leave MaaS standing:

```bash
oc delete externalmodel,maasmodelref -n ${MODEL_NS} --all
oc delete maasauthpolicy bedrock-access -n models-as-a-service
oc delete maassubscription analysts-standard analysts-trial -n models-as-a-service
oc delete secret bedrock-api-key -n ${MODEL_NS}
```

Guardrails:

```bash
oc delete guardrailsorchestrator guardrails-orchestrator -n ${GR_NS}
oc delete inferenceservice guardrails-detector-hap -n ${GR_NS}
oc delete servingruntime guardrails-detector-runtime-hap -n ${GR_NS}
```

AWS:

```bash
aws iam list-service-specific-credentials --user-name rhoai-maas-bedrock
aws iam delete-service-specific-credential \
  --user-name rhoai-maas-bedrock --service-specific-credential-id <ID>
```

> Do not delete the MaaS tenant resource unless tearing down MaaS entirely — it is bootstrapped once and not automatically recreated.

---

# Appendix A — Ordered checklist

```
--- Starting state (verified) ---
[x] OCP 4.22.10, AWS
[x] rhods-operator.3.5.0 GA on stable-3.5, Manual approval
[x] default-dsci Ready, no DSC
[x] cert-manager v1.20.0, jobset-operator v1.0.0
[x] GatewayClass data-science-gateway-class Accepted
[x] gp3-csi default StorageClass
[x] Bedrock ABSK key working, us-east-1

--- Part 2: platform ---
[ ] §2.2 RHCL installed, v1.4.2+, Authorino image 0.23.1+
[ ] §2.3 Kuadrant CR Ready; authorino + limitador Running
[ ] §2.3 (a) TLS listener enabled — logs show "tls":true on http AND grpc auth services
[ ] §2.3 (b) openshift-service-ca ConfigMap injected; mounted via Authorino CR spec.volumes
[ ]        with key->path mapping service-ca.crt -> service-ca-bundle.crt
[ ] §2.3 (b) File verified in-container: ls shows service-ca-bundle.crt, head shows BEGIN CERTIFICATE
[ ] §2.3 (c) SSL_CERT_FILE + REQUESTS_CA_BUNDLE set on the Deployment and still present after rollout
[ ] §2.4 User Workload Monitoring enabled
[ ] §2.5 GatewayConfig Ready; data-science-gateway Programmed (platform-created — do NOT build one)
[ ] §2.5 MAAS_GW derived from gatewayconfig status.domain (NOT maas.<domain>)
[ ] §2.5 Namespace allowlist mechanism recorded (name-based matchExpressions on reference cluster)
[ ] §2.6 PostgreSQL running; maas-db-config in redhat-ods-applications
[ ] §2.7 DSC applied and Ready; dashboard reachable (both classic Route and $MAAS_GW)
[ ] §2.7 Workbench smoke test passed — notebook runs AND has egress (reused in §6.2)
[ ] §2.8 aigateway + modelsAsAService Managed  (spelling: AsA)
[ ] §2.8 Discovery block run; four values recorded (MAAS_GW, path prefix, ns admission, tenant kind)
[ ] §2.8 MaaS CRDs present; maas-api 1/1; IPP 1/1; /maas-api/health healthy
[ ] §2.9 Dashboard flags set

--- Part 3: AWS ---
[x] ABSK key validated: len=132, prefix=ABSK
[x] /v1/models and /v1/chat/completions return successfully
[ ] IAM tightened (SKIP for throwaway PoC) — must include bedrock-mantle:CallWithBearerToken

--- Part 4: integration ---
[ ] external-models namespace labelled gateway-access=true
[ ] Secret bedrock-api-key: key=api-key, label bbr-managed=true, 132 bytes
[ ] ExternalModel + MaaSModelRef for gpt-oss-20b — PHASE Ready
[ ] ExternalModel + MaaSModelRef for claude-sonnet-5 — PHASE Ready
[ ] MaaSAuthPolicy + two MaaSSubscriptions
[ ] Smoke test returns choices[]

--- Part 5: guardrails ---
[ ] trustyai Managed; GuardrailsOrchestrator CRD present
[ ] guardrails namespace labelled
[ ] Orchestrator config with passthrough_headers: [authorization]
[ ] Orchestrator running; /pii and /passthrough routes
[ ] HAP ServingRuntime + InferenceService Ready (CPU)
[ ] Bypass closed — direct MaaS URL returns 403 for analyst key

--- Part 6: demo ---
[ ] Workbench created, notebook calls MaaS via OpenAI SDK
[ ] Model swap in the notebook works unchanged
[ ] 403 bogus / 401 no-auth / ratelimit headers
[ ] Live 429 on the trial subscription
[ ] Key revocation without AWS rotation
[ ] Header stripping verified functionally (§6.5) — REQUIRED, version is unreadable
[ ] PII blocked, toxic prompt blocked
[ ] Token metrics visible per team
```

---

# Appendix B — Provider matrix

| Provider | `spec.provider` | Endpoint | Translation | Auth header |
|---|---|---|---|---|
| AWS Bedrock | `bedrock-openai` | `bedrock-mantle.<region>.api.aws` | Pass-through | `Authorization: Bearer` |
| OpenAI | `openai` | `api.openai.com` | Pass-through | `Authorization: Bearer` |
| Anthropic | `anthropic` | `api.anthropic.com` | OpenAI ↔ Messages API | `x-api-key` |
| Azure OpenAI | `azure-openai` | `<resource>.openai.azure.com` | Path rewrite + field stripping | `api-key` |
| Vertex AI | `vertex-openai` | `<region>-aiplatform.googleapis.com` | Path rewrite + field stripping | `Authorization: Bearer` (OAuth) |

Notes for a multi-provider design:

- **Anthropic direct** — system messages get extracted to a top-level `system` field; `tools[]` converted to `input_schema` form; `frequency_penalty`, `presence_penalty`, `logprobs`, `n`, `response_format`, and `seed` are **silently dropped**. Worth knowing before an analyst files a bug.
- **Vertex AI** — requires plugin-level IPP config (project, location, endpoint), and OAuth2 tokens **expire hourly**, so the Secret needs continuous refresh. Not a fit for a static-credential gateway without automation.
- **Google Gemini via `openai`** — currently broken. The translator hardcodes `/v1/chat/completions` but Gemini needs `/v1beta/openai/chat/completions`. Registration succeeds, inference 404s. Tracked as RHOAIENG-68592.
- **Bedrock is the least troublesome** of the set. If the customer wants Claude specifically, routing it through Bedrock Mantle rather than the Anthropic API avoids the parameter-dropping behaviour above and keeps the commercial relationship inside their existing AWS agreement.

# Appendix C — Notes for the customer conversation

**Their current state:** analysts hold a Bedrock URL and token on their desktops. That means no revocation granularity, no per-user attribution, no quota, no audit trail, and a long-lived AWS credential sitting in a browser tab or a `.env` file.

**After this change,** the same analysts change one base URL and one API key. Everything else about their workflow is identical — same OpenAI-compatible calls, same models. What the organisation gains:

- **Revocation per analyst**, without rotating the AWS credential or disrupting anyone else
- **Per-user and per-department token metering**, which is the input to chargeback
- **Quota enforcement** before the AWS bill arrives, not after
- **One audit trail** covering every model call regardless of provider
- **Provider portability** — adding an on-prem vLLM model, or swapping Bedrock for Azure, becomes a CR change rather than a desktop rollout

**What to be upfront about:**

- `ExternalModel` is Tech Preview. The gateway underneath it is GA. Frame the phasing accordingly and get their appetite for TP in writing.
- The gateway is now on the critical path for analyst productivity. Plan HA for the Gateway and Limitador, and decide on Redis-backed counter persistence before this goes wide.
- The long-term ABSK key is a long-lived credential with an expiry. Someone must own its rotation. Two keys per IAM user exist precisely to make zero-downtime rotation possible — build the runbook for it now, not after the first expiry incident.

# Appendix D — Manual Gateway creation (3.4-era fallback only)

> **Do not use this on RHOAI 3.5 GA.** The platform creates and owns the Gateway via `GatewayConfig` (§2.5).
> This procedure is kept for 3.4-era clusters, and for sites that genuinely need a second, separately-managed
> gateway after §2.8 discovery shows the operator does not wire MaaS in.



**The GatewayClass already exists.** The DSCI created `data-science-gateway-class` with controller `openshift.io/gateway-controller/v1`, Accepted. Do not create another — and note this name is RHOAI-specific, not the `openshift-default` that generic Gateway API guides use.

```bash
oc get gatewayclass
# data-science-gateway-class   openshift.io/gateway-controller/v1   True
```

### First: is there already a Gateway?

```bash
oc get gateway -A
```

- **A Gateway already exists in `openshift-ingress`** (likely named `data-science-gateway`) → adopt it. Skip to *Adopting an existing Gateway* below.
- **No Gateway** → create one as follows.

### Memory override — do this first

Istio's 1Gi default is not enough once Kuadrant compiles its Wasm extensions at startup, and the gateway pod gets OOMKilled under load. This is a silent, intermittent failure that is miserable to diagnose mid-demo.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: maas-gateway-options
  namespace: openshift-ingress
data:
  deployment: |
    spec:
      template:
        spec:
          containers:
            - name: istio-proxy
              resources:
                limits:
                  memory: 2Gi
EOF
```

### Create the Gateway

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME="${CERT_NAME:-router-certs-default}"
echo "domain=$CLUSTER_DOMAIN cert=$CERT_NAME"

cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: data-science-gateway-class
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: maas-gateway-options
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "maas.${CLUSTER_DOMAIN}"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: ${CERT_NAME}
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              maas.opendatahub.io/gateway-access: "true"
EOF

oc wait --for=condition=Programmed gateway/maas-default-gateway \
  -n openshift-ingress --timeout=180s
```

**The two annotations are load-bearing:**

- `opendatahub.io/managed: "false"` — lets maas-controller own the AuthPolicies; without it the ODH Model Controller overwrites them
- `security.opendatahub.io/authorino-tls-bootstrap: "true"` — creates the EnvoyFilter for Gateway → Authorino TLS

### Adopting an existing Gateway

If the DSCI already made one, annotate and label it rather than creating a second:

```bash
export GW_NAME=<name from oc get gateway -A>

oc annotate gateway $GW_NAME -n openshift-ingress \
  opendatahub.io/managed=false \
  security.opendatahub.io/authorino-tls-bootstrap=true --overwrite

# Confirm its listener allows routes from labelled namespaces
oc get gateway $GW_NAME -n openshift-ingress -o jsonpath='{.spec.listeners}' | jq .
```

If `allowedRoutes` is not selector-based on `maas.opendatahub.io/gateway-access`, patch it to match the spec above, and substitute this Gateway's name and hostname everywhere below.

### Label the namespaces that attach routes

**Without this label the Gateway silently rejects HTTPRoutes.** No error, no event — the model simply never becomes reachable. This is the single most common silent failure in the whole procedure.

```bash
oc label namespace redhat-ods-applications maas.opendatahub.io/gateway-access=true --overwrite
```

You will label `external-models` in §4.1 and the guardrails namespace in Part 5.

### Verify

```bash
oc get gateway -n openshift-ingress
curl -vsk "https://maas.${CLUSTER_DOMAIN}" 2>&1 | grep -E "SSL connection|Connected"
```

Want `PROGRAMMED=True` with an ADDRESS, and a successful TLS handshake. A 404 from the gateway at this stage is correct — no routes exist yet.

---

# Appendix E — Reproducing this at a customer site

This runbook was developed on a Red Hat Demo Platform sandbox. A customer environment differs in ways that change specific steps. Work this list before you start.

## What must be re-derived, never copied

Every one of these is site-specific. Copying a value from this document is a defect.

```bash
# 1. Cluster domain
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}'

# 2. MaaS base URL — from GatewayConfig, NOT constructed
oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}{"\n"}'

# 3. Default ingress certificate secret
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}{"\n"}'

# 4. Default StorageClass (workbench PVCs, Postgres)
oc get storageclass | grep default

# 5. Platform type — decides whether MetalLB is needed
oc get infrastructure cluster -o jsonpath='{.status.platform}{"\n"}'

# 6. DSC component schema — field paths move between releases
oc explain datasciencecluster.spec.components --recursive | grep -E '^  [a-z]'

# 7. Operator's own DSC default
CSV=$(oc get csv -n redhat-ods-operator -o name | grep rhods-operator)
oc get $CSV -n redhat-ods-operator -o jsonpath='{.metadata.annotations.alm-examples}' \
  | jq '.[] | select(.kind=="DataScienceCluster")'
```

## Environment deltas

| Dimension | Sandbox (this runbook) | Customer site | Affects |
|---|---|---|---|
| OCP version | 4.22.10 | 4.20+ likely | §2.1 — 4.19 is the floor. Confirm RHOAI 3.5 supports their exact version in the Supported Configurations article |
| Ingress mode | `OcpRoute`, ClusterIP + Route | Likely `LoadBalancer` | §2.5 — `LoadBalancerReady` should go True. Patch `gatewayconfig.spec.ingressMode` |
| TLS certificate | `OpenshiftDefaultIngress` (self-signed chain) | Corporate CA | §2.5 — set `certificate.type: Provided` + `secretName`. Removes `-k` from every curl and `insecure: true` from the guardrails config |
| Identity | `system:authenticated`, `oc whoami -t` | Keycloak / Entra / Okta | §2.5 `gatewayconfig.spec.oidc`; §4.5 real groups instead of `system:authenticated` |
| Database | In-cluster PostgreSQL | RDS or managed Postgres | §2.6 — `sslmode=require`, real credentials, backup policy |
| Network | Connected | Possibly air-gapped | Mirror all images; §5.5 detector images especially |
| AWS account | Throwaway, admin | Governed, SCPs likely | §3.3 IAM user creation may be blocked; §3.6 tighten permissions is mandatory |
| Region | `us-east-1` | Compliance-driven | §3.1 — settle data residency BEFORE building |
| RHOAI channel | `stable-3.5`, Manual approval | Same, but agree a patching policy | §2.2 |

## Steps that change at a customer site

**§2.5 — TLS and identity.** The sandbox uses the default ingress cert and OpenShift tokens. A customer wants their CA and their IdP:

```bash
oc patch gatewayconfig default-gateway --type=merge -p '{
  "spec": {
    "certificate": {"type": "Provided", "secretName": "corporate-tls"},
    "ingressMode": "LoadBalancer",
    "oidc": {
      "issuerURL": "https://idp.customer.com/realms/main",
      "clientID": "rhoai-maas",
      "clientSecretRef": {"name": "oidc-client-secret", "key": "clientSecret"}
    }
  }}'
```

Do this **before** Part 4 — changing identity afterwards invalidates issued API keys and subscription group bindings.

**§2.6 — real database.** In-cluster Postgres has no backup and no HA. `maas-api` holds hashed API keys and revocation state; losing it means every analyst key stops working. Use RDS with `sslmode=require` and confirm the backup policy.

**§3.6 — tighten IAM, no longer optional.** The runbook lets you skip this on a throwaway account. On a customer account it is mandatory, and `bedrock-mantle:CallWithBearerToken` must be present or every call fails identically to a truncated key.

**§4.5 — real groups.** Replace `system:authenticated` with the customer's actual groups, one `MaaSSubscription` per department. That is the chargeback boundary and the thing the customer is really buying.

**Part 5 — TLS to the upstream.** With a proper certificate, drop `insecure: true` from the orchestrator config and mount the CA bundle with `cert_path` instead.

## Pre-flight for the customer build

```
[ ] OCP version confirmed against RHOAI 3.5 Supported Configurations
[ ] RHOAI installed from stable-3.5 (GA), NOT a beta/EA channel
[ ] ExternalModel TP status re-checked in current release notes; customer has accepted it in writing
[ ] Data residency / Bedrock region signed off by compliance
[ ] AWS account confirmed to permit IAM users and long-term bearer tokens (no blocking SCP)
[ ] Corporate TLS certificate secret available
[ ] IdP details available: issuerURL, clientID, client secret
[ ] Managed PostgreSQL provisioned with backups
[ ] Groups agreed for MaaSAuthPolicy and per-department MaaSSubscription
[ ] Air-gapped? Image mirroring plan covers RHOAI, RHCL, and guardrails detectors
[ ] Gateway/Limitador HA decided — the gateway is now on the analyst critical path
[ ] Kuadrant `spec.mtls` decision made with the security team (off during bring-up, enable after Part 6 passes)
[ ] ABSK key rotation runbook written and owned (two keys per IAM user enables zero-downtime)
```

## Discipline for this document

Every discovery command in this runbook is written as **"run this, read the result this way, act accordingly"** rather than a fixed answer, because a customer cluster may reconcile differently. Where a value appears from the reference cluster, it is labelled as such. If a step at a customer site produces a different result than documented, that is new information about RHOAI 3.5 GA — record it here rather than working around it locally.

---

# Appendix F — Site record sheet

Fill this in once per environment, as you work through Part 2. Parts 4–6 read from it. Copy the table for each new site rather than editing in place, so the reference cluster stays available for comparison.

| Fact | How to get it | Reference cluster (sandbox) | Your site |
|---|---|---|---|
| Cluster domain | `oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'` | `apps.rhoai.<sandbox-id>.opentlc.com` | |
| **MAAS_GW** | `oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}'` | `https://rh-ai.apps.rhoai.<sandbox-id>.opentlc.com` | |
| OCP version | `oc get clusterversion version -o jsonpath='{.status.desired.version}'` | 4.22.10 | |
| Platform | `oc get infrastructure cluster -o jsonpath='{.status.platform}'` | AWS | |
| RHOAI CSV | `oc get csv -n redhat-ods-operator` | `rhods-operator.3.5.0` (GA, `stable-3.5`) | |
| RHCL CSV | `oc get csv -n openshift-operators \| grep rhcl` | `rhcl-operator.v1.4.2` | |
| GatewayClass | `oc get gatewayclass` | `data-science-gateway-class` | |
| Gateway | `oc get gateway -A` | `data-science-gateway` / `openshift-ingress` | |
| Ingress mode | `oc get gatewayconfig default-gateway -o jsonpath='{.spec.ingressMode}'` | `OcpRoute` | |
| Ingress cert secret | `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}'` | (default) | |
| Default StorageClass | `oc get storageclass \| grep default` | `gp3-csi` | |
| **NS allowlist BEFORE §2.8** | `oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector}'` | name-based: `openshift-ingress`, `redhat-ods-applications` | |
| **NS allowlist AFTER §2.8** | same command | *(record during §2.8 discovery)* | |
| **NS admission mechanism** | §2.8 discovery | *(operator-managed / GatewayConfig / label)* | |
| **Model path prefix** | §2.8 discovery | *(e.g. `/<ns>/<model>/v1`)* | |
| **Tenant CRD kind** | `oc get crd \| grep -i tenant` | *(`Tenant` / `AITenant` / `MaasTenantConfig`)* | |
| Payload processor | `oc get pods -n openshift-ingress -l app=payload-processing` | *(record during §2.8)* | |
| AWS region | chosen in §3.1 | `us-east-1` | |
| Bedrock IAM user | §3.5 | `rhoai-maas-bedrock` | |
| Model namespace | §4.1 | `external-models` | |
| Models registered | §4.3–4.4 | `bedrock-gpt-oss-20b`, `bedrock-claude-sonnet` | |
| Guardrails namespace | §5.2 | `guardrails` | |

**Environment-specific decisions** (see Appendix E for the reasoning):

| Decision | Reference cluster | Your site |
|---|---|---|
| TLS certificate source | `OpenshiftDefaultIngress` (self-signed chain, `-k` required) | |
| Identity provider | `system:authenticated` + OpenShift tokens | |
| Database | in-cluster Postgres, emptyDir, no backup | |
| Kuadrant mTLS | off | |
| IAM policy | `AmazonBedrockLimitedAccess` (not tightened — throwaway account) | |
| Groups for auth policy / subscriptions | `system:authenticated` | |