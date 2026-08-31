# RHOAI 3.5 → AWS Bedrock via MaaS External Model Routing

**Full runbook: prerequisite audit, remediation, AWS setup, integration, verification.**

---

## 0. Read this first

### What you are building

```
Analyst / app
     │  Authorization: Bearer <MaaS API key>
     ▼
maas.<cluster-domain>          ← MaaS Gateway (Envoy, Gateway API)
     │
     ├─ Authorino    → validates the MaaS key, STRIPS the Authorization header
     ├─ Limitador    → enforces token rate limits from MaaSSubscription
     └─ BBR / IPP    → injects the Bedrock ABSK key from the K8s Secret
     │
     ▼
bedrock-mantle.<region>.api.aws    ← AWS Bedrock, OpenAI-compatible endpoint
```

The analyst never sees the AWS credential. That is the entire point of the exercise.

### Things worth knowing before you start

| Fact | Why it matters |
|---|---|
| **No GPU required.** | External model routing is pure gateway work. No vLLM, no accelerator operators, no NFD, no NVIDIA GPU Operator. Skip every GPU step in the official guides. |
| **`ExternalModel` is Tech Preview** in RHOAI 3.4/3.5. | Not covered by production SLAs; API may change. Say this out loud to the customer before they build a roadmap on it. |
| **MaaS itself is GA** as of RHOAI 3.4. | The gateway, subscriptions, and auth policies are production-ready. Only the external-provider CRD is TP. |
| **Upstream docs have drifted ahead of 3.5.** | The `opendatahub-io/models-as-a-service` `main` branch now documents `aigateway.modelsAsAService`, `AITenant`, and `MaasTenantConfig`. RHOAI 3.5 still ships `modelsAsService` and `Tenant/default-tenant`. Use this runbook and the RHOAI 3.5 product docs; treat upstream `main` as a preview of 3.6+. |
| **You must use `bedrock-mantle`, not `bedrock-runtime`.** | The payload processor hardcodes the upstream path to `/v1/chat/completions`. That path only exists on the Mantle endpoint. `bedrock-runtime` returns 404. |

### Two reference guides worth bookmarking

- Official: [RHOAI 3.5 — Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index)
- Companion (Red Hat AI Services BU, opinionated Kustomize + scripts, covers 3.4/3.5 including external models): <https://rh-aiservices-bu.github.io/rhoai-maas-guide/>

If you want the fast path, clone the companion repo and run its script. This runbook explains what that script does so you can do it by hand, verify it, and explain it to a customer.

```bash
git clone https://github.com/rh-aiservices-bu/rhoai-maas-guide.git
cd rhoai-maas-guide
./scripts/setup-maas.sh            # all phases, idempotent
./scripts/setup-maas.sh --from-phase 4   # resume after a failure
```

### Set your working variables

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
export AWS_REGION="eu-central-1"        # see §3.1 for valid Mantle regions
export MODEL_NS="external-models"
echo "Gateway: $MAAS_GW"
```

---

# PART 1 — Prerequisite audit

Run this first. It tells you exactly what is missing before you change anything.

## 1.1 The one-shot audit script

```bash
#!/usr/bin/env bash
# save as maas-audit.sh, chmod +x, run as cluster-admin
echo "=== OCP version (need 4.19+) ==="
oc version | grep Server
oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo

echo -e "\n=== Platform type (AWS = no MetalLB needed) ==="
oc get infrastructure cluster -o jsonpath='{.status.platform}'; echo

echo -e "\n=== Operator subscriptions ==="
oc get subscriptions.operators.coreos.com -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CSV:.status.currentCSV,STATE:.status.state'

echo -e "\n=== Required CRDs ==="
for crd in datascienceclusters.datasciencecluster.opendatahub.io \
           kuadrants.kuadrant.io \
           certificates.cert-manager.io \
           leaderworkersetoperators.operator.openshift.io \
           gateways.gateway.networking.k8s.io; do
  printf "%-70s " "$crd"
  oc get crd "$crd" >/dev/null 2>&1 && echo "OK" || echo "MISSING"
done

echo -e "\n=== MaaS CRDs (present only when modelsAsService is Managed) ==="
oc get crd 2>/dev/null | grep maas.opendatahub.io || echo "NONE — MaaS is not enabled"

echo -e "\n=== Kuadrant / Authorino / Limitador ==="
oc get kuadrant -n kuadrant-system 2>/dev/null || echo "no Kuadrant CR"
oc get deployment authorino -n kuadrant-system 2>/dev/null || echo "no Authorino"
oc get secret authorino-server-cert -n kuadrant-system 2>/dev/null || echo "no Authorino TLS cert"
oc get pods -n kuadrant-system 2>/dev/null

echo -e "\n=== User Workload Monitoring ==="
oc get pods -n openshift-user-workload-monitoring 2>/dev/null || echo "UWM not enabled"

echo -e "\n=== GatewayClass + Gateway ==="
oc get gatewayclass 2>/dev/null
oc get gateway -A 2>/dev/null

echo -e "\n=== PostgreSQL secret for maas-api ==="
oc get secret maas-db-config -n redhat-ods-applications 2>/dev/null || echo "MISSING maas-db-config"

echo -e "\n=== DataScienceCluster ==="
oc get datasciencecluster 2>/dev/null
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions}' 2>/dev/null | jq '.[] | select(.type|test("Kserve|ModelController|ModelsAsService")) | {type,status,reason}' 2>/dev/null

echo -e "\n=== maas-api + tenant ==="
oc get deployment maas-api -n redhat-ods-applications 2>/dev/null || echo "maas-api not deployed"
oc get tenant -n models-as-a-service 2>/dev/null || echo "no tenant"

echo -e "\n=== Payload processor (BBR / IPP) ==="
oc get pods -n openshift-ingress -l app=payload-processing 2>/dev/null || echo "IPP not found"

echo -e "\n=== Dashboard feature flags ==="
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' 2>/dev/null | jq . 2>/dev/null || echo "no OdhDashboardConfig"
```

## 1.2 Interpreting the results

| Audit line | Expected | If wrong, go to |
|---|---|---|
| OCP version | 4.19+ | Upgrade the cluster. Non-negotiable — Gateway API GA landed in 4.19. |
| Platform | `AWS` | If `None`/`BareMetal`/`OpenStack` you also need MetalLB + a passthrough Route (§2.6). On AWS you can skip both. |
| Subscriptions | `rhods-operator`, `rhcl-operator`, `openshift-cert-manager-operator`, `leader-worker-set` all `AtLatestKnown` | §2.1 |
| RHCL version | `rhcl-operator.v1.3+` (v1.4.2 seen in the field) | §2.1 — MaaS v0.1.0+ needs RHCL 1.3+ / Kuadrant 1.4.2+ for Authorization-header stripping |
| Kuadrant CR | `Ready` | §2.2 |
| `authorino-server-cert` | exists | §2.3 |
| UWM pods | `prometheus-user-workload-0` Running | §2.4 |
| GatewayClass | `openshift-default` Accepted | §2.5 |
| Gateway | `maas-default-gateway` in `openshift-ingress`, `PROGRAMMED=True` | §2.6 |
| `maas-db-config` secret | exists in `redhat-ods-applications` | §2.7 |
| MaaS CRDs | 4 CRDs under `maas.opendatahub.io` | §2.8 — means `modelsAsService` is not Managed |
| `maas-api` deployment | `1/1` Available | §2.8, then §2.9 troubleshooting |
| IPP pods | `1/1 Running` in `openshift-ingress` | §2.10 |
| Dashboard flags | `modelAsService: true` | §2.11 |

### Console equivalent of the audit

| Check | Console path |
|---|---|
| OCP version | **Home → Overview → Cluster version** |
| Operators | **Operators → Installed Operators** (set project to *All Projects*) |
| CRDs | **Administration → CustomResourceDefinitions**, search `maas` / `kuadrant` / `gateway` |
| Kuadrant CR | **Operators → Installed Operators → Red Hat Connectivity Link → Kuadrant** tab |
| Gateway | **Networking → Gateways** (project `openshift-ingress`) |
| Secret | **Workloads → Secrets**, project `redhat-ods-applications`, search `maas-db-config` |
| DSC | **Administration → CustomResourceDefinitions → DataScienceCluster → Instances → default-dsc → YAML** |
| Pods | **Workloads → Pods**, projects `kuadrant-system`, `redhat-ods-applications`, `openshift-ingress` |

---

# PART 2 — Fixing the prerequisites

Work through only the sections your audit flagged. Order matters — later steps depend on earlier ones.

## 2.1 Operators

Four operators are required. **None of the GPU operators are needed for this use case.**

| Operator | Package name | Namespace | Purpose |
|---|---|---|---|
| Red Hat OpenShift AI | `rhods-operator` | `redhat-ods-operator` | Core platform, MaaS component |
| Red Hat Connectivity Link | `rhcl-operator` | `openshift-operators` | Authorino (auth) + Limitador (rate limiting) |
| cert-manager for OpenShift | `openshift-cert-manager-operator` | `cert-manager-operator` | TLS lifecycle; LWS depends on it |
| Leader Worker Set | `leader-worker-set` | `openshift-lws-operator` | Required dependency of the RHOAI serving stack |

### Console

1. **Operators → OperatorHub**
2. Search each operator by name, click it, **Install**
3. Leave the default install mode and namespace; channel `stable` unless you have a reason otherwise
4. Wait for **Status: Succeeded** on each before installing the next

### CLI

```bash
# Example: Red Hat Connectivity Link
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
```

Repeat for the others (each needs its own Namespace + OperatorGroup where the namespace does not already exist). The companion repo has all four ready to apply:

```bash
oc apply -k manifests/01-prerequisites/operators/
```

### Verify

```bash
oc wait csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n cert-manager-operator -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
oc wait csv -n openshift-lws-operator -l operators.coreos.com/leader-worker-set.openshift-lws-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

> **Gotcha:** CSVs take 30–60s to appear after the Subscription is created. `oc wait` returning *"no matching resources found"* usually means "too early", not "broken". Retry.

## 2.2 Kuadrant CR

Installing the RHCL operator does not deploy Authorino and Limitador. You must create the `Kuadrant` CR.

### CLI

```bash
oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -

# Pre-annotate the Authorino service so service-ca mints a TLS cert for it.
# Do this BEFORE creating the Kuadrant CR.
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

oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
```

### Console

**Operators → Installed Operators → Red Hat Connectivity Link → Kuadrant → Create Kuadrant.** Switch to YAML view and set `spec.observability.enable: true`.

### If it fails

`MissingDependency` is an Istio race condition. Restart the operator pod:

```bash
oc delete pod -n openshift-operators \
  $(oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | awk '{print $1}')
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
```

## 2.3 Authorino TLS

Required for Gateway → Authorino communication.

```bash
# 2.3a  Confirm service-ca generated the cert
oc get secret authorino-server-cert -n kuadrant-system

# 2.3b  Enable the TLS listener on Authorino
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": { "name": "authorino-server-cert" }
      }
    }
  }
}'

# 2.3c  Point Authorino at the cluster service CA bundle
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

# 2.3d  Verify
oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

**Console:** **Administration → CustomResourceDefinitions → Authorino → Instances → authorino → YAML**, add the `spec.listener.tls` block. Then **Workloads → Deployments → authorino → Environment** to add the two variables.

## 2.4 User Workload Monitoring

Needed for token metering and the observability dashboards.

### Console

**Administration → Cluster Settings → Configuration → ConfigMap** — or directly: **Workloads → ConfigMaps**, project `openshift-monitoring`, edit or create `cluster-monitoring-config`.

### CLI

```bash
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

Expect `prometheus-operator`, `prometheus-user-workload-0`, and `thanos-ruler-user-workload-0` all Running.

> If `cluster-monitoring-config` already exists with other keys, **edit** it rather than replacing — the apply above will clobber existing settings.

## 2.5 GatewayClass

```bash
cat <<'EOF' | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=120s
oc get gatewayclass openshift-default
```

Expected: `ACCEPTED = True`.

**Console:** **Networking → GatewayClasses → Create GatewayClass** (or use **+** → Import YAML).

## 2.6 MaaS Gateway

This is the single most common failure point. On AWS (your case) it is straightforward — no MetalLB, no passthrough Route.

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME="${CERT_NAME:-router-certs-default}"
echo "domain=$CLUSTER_DOMAIN cert=$CERT_NAME"
```

**First, the memory override ConfigMap.** The Istio default of 1Gi is not enough once Kuadrant compiles its Wasm extensions at startup, and the gateway pod gets OOMKilled.

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

**Then the Gateway.** Note: no `hostname` filter on the listener — hostname-based routing causes TLS/SNI problems.

```bash
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
  gatewayClassName: openshift-default
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

oc wait --for=condition=Programmed gateway/maas-default-gateway -n openshift-ingress --timeout=120s
```

**The two annotations matter:**

- `opendatahub.io/managed: "false"` — lets maas-controller own the AuthPolicies and stops the ODH Model Controller from overwriting them
- `security.opendatahub.io/authorino-tls-bootstrap: "true"` — triggers creation of the EnvoyFilter for Gateway → Authorino TLS

**Label every namespace that needs to attach routes.** Without this label the Gateway silently rejects the HTTPRoute and your model is unreachable.

```bash
oc label namespace redhat-ods-applications maas.opendatahub.io/gateway-access=true --overwrite
```

You will label `external-models` in §4.1.

**Non-cloud clusters only** (`platform` is `None`/`BareMetal`/`OpenStack`): install MetalLB, configure an IPAddressPool on an unused IP on the same L2 subnet — *not* the node's own IP — and create a passthrough Route. See Phase 1 and Phase 2 §5e of the companion guide. On AWS, skip.

### Verify

```bash
oc get gateway maas-default-gateway -n openshift-ingress
curl -vsk "https://maas.${CLUSTER_DOMAIN}" 2>&1 | grep -E "SSL connection|Connected"
```

Expected: `PROGRAMMED=True` with an ADDRESS, and a successful TLS handshake.

## 2.7 PostgreSQL for maas-api

`maas-api` stores hashed API keys, subscription bindings, expiry, and revocation state in PostgreSQL. **It will crash-loop until this exists.** Create it *before* enabling MaaS in the DSC.

For a PoC, an in-cluster PostgreSQL is fine. For the customer's real deployment, point at RDS.

```bash
# PoC: quick in-cluster Postgres
oc new-project maas-db 2>/dev/null || oc project maas-db
oc new-app --name=maas-postgres \
  --image=registry.redhat.io/rhel9/postgresql-16:latest \
  -e POSTGRESQL_USER=maas \
  -e POSTGRESQL_PASSWORD='<choose-a-password>' \
  -e POSTGRESQL_DATABASE=maas
oc rollout status deployment/maas-postgres -n maas-db --timeout=180s
```

Create the secret in the **RHOAI applications namespace**:

```bash
oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL='postgresql://maas:<password>@maas-postgres.maas-db.svc.cluster.local:5432/maas?sslmode=disable'
```

For RDS, use the real host and `sslmode=require`:

```
postgresql://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require
```

**Console:** **Workloads → Secrets → Create → Key/value secret**, project `redhat-ods-applications`, name `maas-db-config`, key `DB_CONNECTION_URL`.

> If you create this secret *after* MaaS is already enabled, restart the deployment:
> `oc rollout restart deployment/maas-api -n redhat-ods-applications`

## 2.8 Enable MaaS in the DataScienceCluster

This is the "is MaaS enabled?" question.

### Check the schema first

Field paths shifted between releases. Confirm against your actual CRD rather than trusting any document:

```bash
oc explain datasciencecluster.spec.components --recursive 2>/dev/null | grep -i -B3 -A3 'modelsAsService\|modelsAsAService\|aigateway'
```

### Apply

```bash
oc get datasciencecluster
# note the name; default-dsc is conventional
```

Patch the existing DSC (safer than replacing it):

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "kserve":            { "managementState": "Managed" },
      "modelsAsService":   { "managementState": "Managed" },
      "dashboard":         { "managementState": "Managed" },
      "llamastackoperator":{ "managementState": "Managed" }
    }
  }
}'
```

If `oc explain` showed the field nested differently, adjust the path accordingly. `llamastackoperator` is only needed for GenAI Studio — set it to `Removed` if you don't want the playground.

**Console:** **Administration → CustomResourceDefinitions → DataScienceCluster → Instances → default-dsc → YAML tab**, edit `spec.components`, Save.

### Verify

```bash
oc wait --for=jsonpath='{.status.conditions[?(@.type=="KserveReady")].status}'=True \
  datasciencecluster/default-dsc --timeout=300s
oc wait --for=jsonpath='{.status.conditions[?(@.type=="ModelControllerReady")].status}'=True \
  datasciencecluster/default-dsc --timeout=300s

# The four MaaS CRDs appear only when modelsAsService is Managed
oc get crd | grep maas.opendatahub.io
# maasauthpolicies.maas.opendatahub.io
# maasmodelrefs.maas.opendatahub.io
# maassubscriptions.maas.opendatahub.io
# tenants.maas.opendatahub.io

oc rollout status deployment/maas-api -n redhat-ods-applications --timeout=180s
oc get tenant default-tenant -n models-as-a-service
```

> `default-tenant` showing `Ready=False` with reason `DeploymentsNotReady` at this stage is **expected** — it clears once a model is registered.

### Health check

```bash
curl -sk "${MAAS_GW}/maas-api/health"
# {"status":"healthy"}
```

## 2.9 If maas-api is crash-looping

```bash
oc logs -n redhat-ods-applications deployment/maas-api --tail=100
```

| Log symptom | Cause | Fix |
|---|---|---|
| `connection refused` / `dial tcp` | Postgres unreachable | Check the connection URL, the service DNS name, and network policy |
| `password authentication failed` | Wrong credentials in the secret | Recreate `maas-db-config`, then `oc rollout restart deployment/maas-api -n redhat-ods-applications` |
| `secret "maas-db-config" not found` | Secret in the wrong namespace | Must be `redhat-ods-applications`, not `opendatahub` (that's ODH) |
| Pod never appears | DSC not reconciled | `oc describe datasciencecluster default-dsc`; check `oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100` |

## 2.10 Payload processor (BBR / IPP)

This component injects the provider credential and translates request formats. **External models will not work without it.**

```bash
oc get pods -n openshift-ingress -l app=payload-processing
```

Expected: one pod, `1/1 Running`.

When MaaS is deployed via the Tenant CR — the standard RHOAI path you just followed — IPP is deployed automatically as a subcomponent. If the pod is missing, MaaS has not fully reconciled. Check:

```bash
oc get tenant default-tenant -n models-as-a-service -o yaml | yq '.status'
oc logs -n redhat-ods-applications deployment/maas-controller --tail=100 2>/dev/null
```

Manual deployment (only if the operator path failed) is documented upstream under *External Model Setup → Step 1*.

## 2.11 Dashboard feature flags

Turns on the MaaS tabs in the RHOAI console.

```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{
        "modelAsService": true,
        "maasAuthPolicies": true,
        "genAiStudio": true,
        "observabilityDashboard": true
      }}}'

oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | jq .
```

| Flag | Effect | Depends on |
|---|---|---|
| `modelAsService` | Models as a Service tab | MaaS Managed |
| `maasAuthPolicies` | Auth policy management UI | MaaS Managed |
| `genAiStudio` | GenAI Studio / playground | `llamastackoperator` Managed |
| `observabilityDashboard` | Observability tab | COO + OTel + DSCI monitoring configured |

**Console:** **Administration → CustomResourceDefinitions → OdhDashboardConfig → Instances → odh-dashboard-config → YAML.**

> The operator recreates this resource with factory defaults if deleted, but does not overwrite your edits to existing fields.

---

# PART 3 — AWS Bedrock setup

## 3.1 Choose a Mantle region

The Mantle endpoint is not in every region. Currently offered in:

**US East** (N. Virginia, Ohio) · **US West** (Oregon) · **Asia Pacific** (Jakarta, Mumbai, Sydney, Tokyo) · **Europe** (Frankfurt, Ireland, London, Milan, Stockholm) · **South America** (São Paulo)

For an Israeli customer, **`eu-central-1` (Frankfurt)** or **`eu-west-1` (Ireland)** are the usual picks. Confirm the data-residency answer with their compliance people before you build anything — this is the question that kills these projects late.

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

# PART 4 — Wire Bedrock into RHOAI

## 4.1 Namespace

```bash
oc create namespace ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -

# REQUIRED — without this the Gateway silently rejects the HTTPRoute
oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite

oc get namespace ${MODEL_NS} --show-labels
```

**Console:** **Home → Projects → Create Project**, then **Administration → Namespaces →** select it **→ Edit labels**.

> This is the single most common silent failure in external model setup. No error is raised — the model simply never becomes reachable.

## 4.2 Credential Secret

Three requirements, all mandatory:

1. Same namespace as the `ExternalModel`
2. Data key must be exactly `api-key`
3. Label `inference.networking.k8s.io/bbr-managed=true`

```bash
oc create secret generic bedrock-api-key \
  --from-literal=api-key="${BEDROCK_API_KEY}" \
  -n ${MODEL_NS} \
  --dry-run=client -o yaml | oc apply -f -

oc label secret bedrock-api-key -n ${MODEL_NS} \
  inference.networking.k8s.io/bbr-managed=true --overwrite

# Verify
oc get secret bedrock-api-key -n ${MODEL_NS} --show-labels
oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data}' | jq 'keys'
# ["api-key"]
```

**Console:** **Workloads → Secrets → Create → Key/value secret** in project `external-models`. Name `bedrock-api-key`, key `api-key`, value = the ABSK string. Then **Actions → Edit labels** to add the bbr-managed label.

> Never commit this to Git. If you are doing GitOps, use External Secrets Operator or Sealed Secrets and reference the ABSK from a vault. The `ExternalModel` CR itself is safe to commit — it holds only a `credentialRef`.

**Validate the key one final time before it goes into the cluster.** A truncated key stored in a Secret fails later as an opaque `401` from AWS buried in payload-processor logs, which is far more expensive to diagnose than here:

```bash
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"
# len=132 prefix=ABSK  — anything else, go back to §3.5
```

Use `read -rs` to paste the key without it landing in shell history:

```bash
read -rs BEDROCK_API_KEY && export BEDROCK_API_KEY
```

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

### Field reference

| Field | Value | Notes |
|---|---|---|
| `spec.provider` | `bedrock-openai` | Selects the BBR translator. Others: `openai`, `anthropic`, `azure-openai`, `vertex-openai` |
| `spec.endpoint` | `bedrock-mantle.<region>.api.aws` | **Hostname only — no scheme, no path.** Must match your region. |
| `spec.targetModel` | e.g. `openai.gpt-oss-20b` | Exactly as returned by `/v1/models` |
| `spec.credentialRef.name` | `bedrock-api-key` | Secret must be in the same namespace |

For `bedrock-openai` the translator is **pass-through** — no request-body translation, auth via `Authorization: Bearer`. This is why Bedrock-via-Mantle is the cleanest of the external providers to integrate.

### What the reconciler creates for you

| Resource | Purpose |
|---|---|
| `Service` (ExternalName) | Maps an in-cluster DNS name to the AWS FQDN |
| `ServiceEntry` | Registers the external host in the Istio mesh |
| `DestinationRule` | TLS origination to the AWS endpoint |
| `HTTPRoute` | Routes gateway traffic to the provider |

### Verify

```bash
oc get externalmodel bedrock-gpt-oss-20b -n ${MODEL_NS}
oc get maasmodelref bedrock-gpt-oss-20b -n ${MODEL_NS}
```

Expected:

```
NAME                  PHASE   ENDPOINT                                                    HTTPROUTE             GATEWAY
bedrock-gpt-oss-20b   Ready   https://maas.<domain>/external-models/bedrock-gpt-oss-20b   bedrock-gpt-oss-20b   maas-default-gateway
```

If `PHASE` is not `Ready`:

```bash
oc describe externalmodel bedrock-gpt-oss-20b -n ${MODEL_NS}
oc describe maasmodelref bedrock-gpt-oss-20b -n ${MODEL_NS}
oc get httproute,serviceentry,destinationrule -n ${MODEL_NS}
```

**Console:** **Administration → CustomResourceDefinitions**, search `ExternalModel` → **Instances → Create ExternalModel** (YAML view). Repeat for `MaaSModelRef`. Or use the **+** icon in the masthead → **Import YAML** and paste both documents at once.

## 4.4 Access policy and quota

These two live in the **`models-as-a-service`** namespace, not the model namespace.

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
  subjects:
    groups:
      - name: "system:authenticated"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: bedrock-free
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
EOF
```

- **`MaaSAuthPolicy`** answers *who may call this model* — enforced by Authorino.
- **`MaaSSubscription`** answers *how many tokens they get* — enforced by Limitador.

For the real engagement, replace `system:authenticated` with actual OpenShift groups or OIDC groups, and create one subscription per department with distinct limits. That is your chargeback boundary.

```bash
oc get maasauthpolicy,maassubscription -n models-as-a-service
```

**Console:** RHOAI dashboard → **Models as a Service** (once `modelAsService: true` is set) offers a form for subscriptions, including a *Create matching authorization policy* checkbox that generates the AuthPolicy with the same groups and models. Otherwise use **Import YAML**.

---

# PART 5 — End-to-end verification

## 5.1 Model appears in the catalog

```bash
curl -sk "${MAAS_GW}/maas-api/v1/models" \
  -H "Authorization: Bearer $(oc whoami -t)" | jq -r '.data[].id'
```

`bedrock-gpt-oss-20b` should be in the list.

## 5.2 Mint an API key

```bash
API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"bedrock-test","subscription":"bedrock-free","expiresIn":"1h"}' \
  | jq -r '.key')

echo "${API_KEY:0:12}..."
```

## 5.3 Inference through the gateway

```bash
curl -sk "${MAAS_GW}/${MODEL_NS}/bedrock-gpt-oss-20b/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${TARGET_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

Path structure: `https://maas.<domain>/<model-namespace>/<model-name>/v1/chat/completions`

## 5.4 Prove the controls work — the demo

This is what you show the customer. Each check maps to a business objection.

```bash
# Bogus key → 403 (authorization enforced)
curl -sk -o /dev/null -w "bogus key: %{http_code}\n" \
  "${MAAS_GW}/${MODEL_NS}/bedrock-gpt-oss-20b/v1/chat/completions" \
  -H "Authorization: Bearer sk-FAKE-KEY" -H "Content-Type: application/json" \
  -d '{"model":"'"${TARGET_MODEL}"'","messages":[{"role":"user","content":"hi"}]}'

# No auth → 401 (nothing is anonymous)
curl -sk -o /dev/null -w "no auth:    %{http_code}\n" \
  "${MAAS_GW}/${MODEL_NS}/bedrock-gpt-oss-20b/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${TARGET_MODEL}"'","messages":[{"role":"user","content":"hi"}]}'

# Rate limit headers (quota is visible to the consumer)
curl -sk -D - -o /dev/null \
  "${MAAS_GW}/${MODEL_NS}/bedrock-gpt-oss-20b/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"'"${TARGET_MODEL}"'","messages":[{"role":"user","content":"hi"}],"max_tokens":300}' \
  | grep -i ratelimit
```

**The talking points:**

| Check | What it proves |
|---|---|
| 403 on bogus key | Only org-issued credentials work |
| 401 with no auth | The endpoint is not open |
| `X-RateLimit-Remaining` header | Per-subscription quota is enforced and visible |
| Analysts hold a MaaS key, not an ABSK | Revoke one analyst without rotating the AWS credential |
| Authorino strips the inbound header | A compromised backend cannot capture user tokens |
| Token metrics in Prometheus | Per-department chargeback is real, not aspirational |

## 5.5 Credential isolation — the security proof

Show the security team this explicitly. The user's credential is validated by Authorino and **stripped before forwarding**; the Bedrock ABSK key is injected separately from the Secret. The user's token never reaches AWS, and the AWS key never reaches the user. This behaviour requires RHCL 1.3+ / Kuadrant 1.4.2+ (Authorino v0.23.1+) — which is why the version floor in §2.1 is not optional.

## 5.6 Observability

```bash
# Token metrics through the gateway
oc -n openshift-user-workload-monitoring exec -it prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]' | grep -i -E 'token|limitador|authorino' | head -30
```

In the RHOAI dashboard, the **Observability** tab shows per-team token consumption, request rates, latency, and error rates — provided `observabilityDashboard: true` and the Cluster Observability Operator are configured.

---

# PART 6 — Troubleshooting reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `MaaSModelRef` stuck not-Ready | Namespace missing the gateway-access label | `oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite` |
| `404` from the gateway | Using `bedrock-runtime` instead of `bedrock-mantle` | Fix `spec.endpoint` |
| `404`, endpoint correct | Model not available on Mantle in that region | Re-check `/v1/models` for the region |
| `401` from AWS (visible in IPP logs) | Secret missing `bbr-managed` label, or wrong data key | Label must be `inference.networking.k8s.io/bbr-managed=true`; key must be `api-key` |
| `invalid_api_key` / "Invalid bearer token" from AWS | **Truncated ABSK key (131 chars instead of 132)** — by far the most common cause | `oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' \| base64 -d \| wc -c` → must be 132. Re-create the Secret. |
| Copied a valid-looking key that AWS rejects | Wrong field taken from `create-service-specific-credential` | The key is whichever field starts with `ABSK` — not the alias, not the credential ID. See §3.5 |
| Key worked, then broke right after tightening IAM | Custom policy missing `bedrock-mantle:CallWithBearerToken` | Add it on `Resource: "*"`, or re-attach `AmazonBedrockMantleInferenceAccess` (§3.6) |
| `/v1/models` 403s but inference works | Policy missing `bedrock-mantle:Get*` / `List*` | Add both (§3.6) |
| `content: null`, `finish_reason: "length"` | Reasoning model exhausted `max_tokens` — **not** a failure | Raise `max_tokens` to 300+ |
| `403` from the gateway | No matching `MaaSAuthPolicy` for the caller's groups | Check `modelRefs` and `subjects.groups` |
| `429` unexpectedly | Subscription limit too low, or Limitador counters shared | Raise `tokenRateLimits.limit` or split subscriptions |
| Gateway never `Programmed` | Non-cloud platform without MetalLB; or cert secret name wrong | §2.6 |
| Gateway pod OOMKilled | Istio 1Gi default too small for Kuadrant Wasm | Apply the `maas-gateway-options` ConfigMap (§2.6) |
| `maas-api` CrashLoopBackOff | Postgres unreachable or secret missing | §2.7, §2.9 |
| Kuadrant `MissingDependency` | Istio race condition | Restart the kuadrant-operator pod (§2.2) |
| No MaaS CRDs | `modelsAsService` not Managed | §2.8 |
| `maas-api` healthy, models missing from `/v1/models` | `MaaSModelRef` not created, or in wrong namespace | Must be in the same namespace as the `ExternalModel` |
| ABSK key rejected everywhere | Key expired, or you detached the managed policy without adding the inline one | §3.6 |
| Cannot create IAM user | SCP blocking IAM user creation | Attach the service-specific credential to an existing IAM user |

### Useful log locations

```bash
oc logs -n redhat-ods-applications deployment/maas-api --tail=100
oc logs -n openshift-ingress -l app=payload-processing --tail=100
oc logs -n kuadrant-system deployment/authorino --tail=100
oc logs -n kuadrant-system deployment/limitador-limitador --tail=100
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --tail=100
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100
oc describe datasciencecluster default-dsc
```

---

# PART 7 — Cleanup

Remove just the Bedrock integration, leaving MaaS intact:

```bash
oc delete externalmodel bedrock-gpt-oss-20b -n ${MODEL_NS}   # OwnerRefs clean up Service/ServiceEntry/DR/HTTPRoute
oc delete maasmodelref  bedrock-gpt-oss-20b -n ${MODEL_NS}
oc delete maasauthpolicy  bedrock-access  -n models-as-a-service
oc delete maassubscription bedrock-free   -n models-as-a-service
oc delete secret bedrock-api-key -n ${MODEL_NS}
```

Revoke the AWS side:

```bash
aws iam list-service-specific-credentials --user-name rhoai-maas-bedrock
aws iam delete-service-specific-credential \
  --user-name rhoai-maas-bedrock \
  --service-specific-credential-id <ID-from-above>
```

> Do **not** delete `Tenant/default-tenant` in `models-as-a-service` unless you are intentionally tearing down MaaS. It is bootstrapped once and is not automatically recreated.

---

# Appendix A — Ordered checklist

```
[ ] OCP 4.19+, platform = AWS
[ ] Operators: rhods, rhcl (1.3+), cert-manager, leader-worker-set → all Succeeded
[ ] Kuadrant CR Ready; Authorino + Limitador running
[ ] Authorino TLS enabled (authorino-server-cert + listener patch + env vars)
[ ] User Workload Monitoring enabled
[ ] GatewayClass openshift-default Accepted
[ ] maas-gateway-options ConfigMap applied (2Gi)
[ ] Gateway maas-default-gateway Programmed, both annotations present
[ ] redhat-ods-applications labelled gateway-access=true
[ ] PostgreSQL reachable; maas-db-config secret in redhat-ods-applications
[ ] DSC: modelsAsService = Managed
[ ] 4 MaaS CRDs present
[ ] maas-api rollout complete; /maas-api/health returns healthy
[ ] Tenant default-tenant exists
[ ] IPP pod 1/1 Running in openshift-ingress
[ ] Dashboard flags set
--- AWS ---
[ ] Mantle region chosen; data residency signed off
[ ] Model access confirmed (Marketplace subscription if required)
[ ] IAM user created (deliberately named) or SCP workaround identified
[ ] ABSK long-term key generated with expiry
[ ] Key VALIDATED: len=132, prefix=ABSK, tail matches source (§3.5)
[ ] IAM tightened (SKIP for throwaway PoC) — AmazonBedrockMantleInferenceAccess,
    attach-before-detach, MUST include bedrock-mantle:CallWithBearerToken (§3.6)
[ ] Key tested directly against bedrock-mantle — /v1/models and /v1/chat/completions
--- Integration ---
[ ] external-models namespace created and labelled gateway-access=true
[ ] Key re-validated (len=132) immediately before creating the Secret
[ ] Secret bedrock-api-key: key=api-key, label bbr-managed=true
[ ] ExternalModel applied (provider bedrock-openai, mantle endpoint)
[ ] MaaSModelRef applied; PHASE = Ready
[ ] MaaSAuthPolicy + MaaSSubscription in models-as-a-service
--- Verification ---
[ ] Model listed in /maas-api/v1/models
[ ] API key minted against the subscription
[ ] Inference returns choices[]
[ ] Bogus key → 403; no auth → 401
[ ] Rate limit headers present
[ ] Token metrics visible in Prometheus
```

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