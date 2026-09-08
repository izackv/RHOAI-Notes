# Connecting AWS Bedrock to OpenShift AI Models-as-a-Service

**Installation Guide — RHOAI 3.5, AWS region `eu-west-1`, model `openai.gpt-oss-20b`**

This guide takes a cluster with Red Hat OpenShift AI (RHOAI) 3.5 already installed and connects it to AWS Bedrock through the Models-as-a-Service (MaaS) gateway. At the end, users call one authenticated HTTPS endpoint on the cluster; the gateway validates their key, enforces token quotas, and forwards the request to Bedrock using an AWS credential that users never see.

---

## What you are building

```
user  →  MaaS gateway  →  AWS Bedrock (eu-west-1)
           |
           ├─ Authorino   validates the user's MaaS key, strips it from the request
           ├─ Limitador   enforces the token quota
           └─ IPP         injects the AWS credential from a Kubernetes Secret
```

**The user's key never reaches AWS. The AWS key never reaches the user.** That credential swap is the core of the design:

- Users authenticate with a MaaS API key they mint themselves (self-service, expiring, revocable).
- The single AWS Bedrock key lives in one Kubernetes Secret, injected server-side.
- Every request is metered by token count, per subscription, so usage can be attributed and limited per team.

### The resources you will create

| Resource | Purpose |
|---|---|
| `ExternalProvider` | **Where** to connect — the Bedrock endpoint and its credential |
| `ExternalModel` | **What** clients ask for — maps a model name to a provider model ID |
| `MaaSModelRef` | **Exposes** the model through the MaaS gateway |
| `MaaSAuthPolicy` + `MaaSSubscription` | **Who** may call it, and **how much** |

One `ExternalProvider` serves every Bedrock model in the region. Adding a model later requires no new AWS credential.

---

## Prerequisites

Confirm all of these before starting:

| Requirement | How to check |
|---|---|
| OpenShift 4.19 or later | `oc version` |
| RHOAI 3.5 operator installed, `DataScienceCluster` Ready | `oc get dsc` → `READY: True` |
| cert-manager Operator installed | `oc get csv -A \| grep cert-manager` |
| A default StorageClass | `oc get storageclass` |
| `cluster-admin` access | `oc auth can-i '*' '*'` |
| Workstation tools | `oc`, `curl`, `jq`, `aws` CLI (optional) |
| **An AWS Bedrock API key** | A long-term Bedrock API key (starts with `ABSK`) with permission to invoke Bedrock models in `eu-west-1` — validated in Part 2 |

> **Note on the AWS key.** The key must belong to an IAM identity whose policy includes `bedrock-mantle:CallWithBearerToken` (included in `AmazonBedrockLimitedAccess` and `AmazonBedrockMantleInferenceAccess`). Without that action, every call fails with a generic permission error.

### Working variables

Set these in every terminal session used for this guide:

```bash
export AWS_REGION="eu-west-1"
export MODEL_NS="external-models"                # namespace for external model resources
export MODEL_NAME="openai.gpt-oss-20b"          # ONE name everywhere: resource names, client-facing name, Bedrock model ID
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
echo "Gateway will be: ${MAAS_GW}"
```

> **Why one name is used everywhere.** Two independent string comparisons in RHOAI 3.5 are satisfied only when the names align:
>
> 1. **Routing:** the generated gateway route matches requests against the *provider's* model ID (`targetModel`), while the request pre-processor populates that match from the *client-facing* name (`modelName`). If they differ, every request returns `404 route_not_found`, and the manual route edit that fixes it is reverted by the operator on reconciliation.
> 2. **Authorization:** the subscription check compares the requested model name against the *model resource name* (`metadata.name`). If they differ, every request is refused with `subscription ... does not include model ...` — even though the subscription references the resource correctly.
>
> Setting **`metadata.name` = `modelName` = `targetModel` = `openai.gpt-oss-20b`** satisfies both as shipped, with no manual patching and nothing to revert. Dots are valid in Kubernetes resource names. This guide follows that convention for every model — both failure modes above are verified, not theoretical.

---

# Part 1 — Enable the MaaS platform

This part assembles the gateway that will front every model call. Nothing here touches AWS yet.

On a cluster where MaaS is already set up, **do not walk the sections — run the four checks in §1.0.** If they pass, Part 1 is complete. Sections §1.1–§1.7 are the drill-down: use them only to fix whatever a check flags (each opens with its own narrower check, so within a section you also only run what is actually missing).

## 1.0 Verify the platform — four checks

The verification is top-down: check 1 is an end-to-end probe that transitively proves most of the platform in one call, and checks 2–4 cover only what it cannot see.

```bash
# 1. End-to-end health — proves DNS, the MaaS gateway, its TLS listener,
#    route admission, the maas-api pod, and its database connection, in one call
curl -sk "${MAAS_GW}/maas-api/health"; echo
# {"status":"healthy"}

# 2. Authenticated admin API — proves the auth plane accepts your OpenShift token
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" | jq .
# valid JSON — {"data":[]} is correct on a cluster with no models yet

# 3. The enforcement/injection components Part 3 depends on (idle until a model exists,
#    so not exercised by checks 1–2)
oc get pods -n kuadrant-system
oc get pods -n openshift-ingress -l app=payload-processing
# authorino, limitador, payload-processing — all Running

# 4. Authorino TLS — the one configuration that can be broken while 1–3 all pass,
#    because its failure only surfaces later as certificate errors
oc logs -n kuadrant-system deployment/authorino | grep -m2 'auth service'   # both lines "tls":true
oc -n kuadrant-system exec deployment/authorino -- head -1 /etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt   # BEGIN CERTIFICATE
oc -n kuadrant-system set env deployment/authorino --list | grep -cE 'SSL_CERT|REQUESTS_CA'   # 2
```

**All four pass → Part 1 is done. Continue with Part 2.**

If a check fails, drill into the matching section:

| Check | Symptom | Drill into |
|---|---|---|
| 1 | Connection error / cannot resolve host | §1.4 — gateway or DNS |
| 1 | HTML instead of JSON | Wrong hostname — `MAAS_GW` must be `maas.<cluster-domain>`, not the dashboard host |
| 1 | `404` | §1.6 — MaaS not enabled |
| 1 | `503` or not healthy | §1.5 database, then `oc logs -n redhat-ai-gateway-infra deployment/maas-api --tail=100` |
| 2 | `401`/`403` | Get a fresh token (`oc login`); if it persists, §1.6 |
| 3 | Pods missing | §1.1–§1.2 for kuadrant-system; §1.6 for the payload processor |
| 4 | `"tls":false`, or no match | §1.2 — the three-part TLS configuration |

When fixing missing pieces, the build order matters: the gateway (§1.4) and the database (§1.5) must exist *before* MaaS is enabled (§1.6), or `maas-api` crash-loops on startup.

Two items are deliberately **not** in the fast path because nothing in Parts 2–4 functionally depends on them — verify them once, at your convenience:

```bash
oc get pods -n openshift-user-workload-monitoring   # §1.3 — needed for token-metering dashboards
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}'             # §1.7 — needed only for the console UI pages
```

## 1.1 Install Red Hat Connectivity Link

**Check first:**

```bash
oc get csv -n openshift-operators | grep -iE 'rhcl|authorino|limitador'
```

If this shows `rhcl-operator` v1.4.2 or later at `Succeeded`, the operator is already installed — skip to §1.2.

Red Hat Connectivity Link (RHCL) provides Authorino (authentication/authorization) and Limitador (rate limiting) — the enforcement components of the gateway.

**Console:** Operators → OperatorHub → search *Connectivity Link* → **Red Hat Connectivity Link** (source *Red Hat*, not Community) → Install → namespace `openshift-operators`, channel `stable`.

**CLI:**

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

Verify:

```bash
oc get csv -n openshift-operators | grep -iE 'rhcl|authorino|limitador'
```

Expect `rhcl-operator` v1.4.2 or later at `Succeeded`, with authorino and limitador CSVs alongside it.

> - CSVs take 30–60 seconds to appear after the Subscription; "no matching resources found" from `oc wait` means "too early", not "broken".
> - Installing the operator does **not** yet deploy Authorino and Limitador — `kuadrant-system` stays empty until the next step. That is expected.
> - **Minimum version: RHCL 1.3 / Authorino 0.23.1.** That release added the Authorization-header stripping that keeps user tokens from reaching AWS.

## 1.2 Kuadrant CR and Authorino TLS

**Check first:**

```bash
oc get kuadrant kuadrant -n kuadrant-system 2>/dev/null
oc get pods -n kuadrant-system
```

If the `Kuadrant` CR exists and the authorino and limitador pods are Running, the components are already deployed — **skip the deployment below, but do not skip the "Authorino TLS" subsection**: run its checks regardless of how the cluster was set up, because a missing TLS piece produces no visible error here.

Creating the `Kuadrant` custom resource is what actually deploys Authorino and Limitador.

```bash
oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -
```

**Pre-create the Authorino Service with a serving-cert annotation** so OpenShift's service-ca mints the TLS certificate before the operator creates the deployment:

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

> If the Kuadrant CR reports `MissingDependency`, it is a startup race with the service mesh. Delete the kuadrant-operator pod in `openshift-operators` and wait again.

### Authorino TLS — three parts, all required

**If §1.0 check 4 passed (all three probes), this subsection is already satisfied — skip it.**

This is the most error-prone step in Part 1. All three pieces must be present — the server certificate, the CA bundle mount, and the environment variables. A partial configuration fails silently and only surfaces later as unrelated-looking TLS errors.

**Check whether TLS is already configured — all three at once:**

```bash
# (a) TLS listeners up
oc logs -n kuadrant-system deployment/authorino | head -5 | grep 'auth service'
# want: "starting http auth service","port":5001,"tls":true
#       "starting grpc auth service","port":50051,"tls":true

# (b) CA bundle mounted, with the right file name
oc -n kuadrant-system exec deployment/authorino -- head -1 /etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
# want: -----BEGIN CERTIFICATE-----

# (c) Environment variables set
oc -n kuadrant-system set env deployment/authorino --list | grep -E 'SSL_CERT|REQUESTS_CA'
# want both SSL_CERT_FILE and REQUESTS_CA_BUNDLE pointing at that file
```

**If all three pass, TLS is already configured — skip to §1.3.** If any fails, apply the corresponding part below; all of the commands are safe to re-run on a partly configured cluster.

**(a) Enable the TLS listener.** This needs the server certificate secret. If the cluster was set up with the pre-annotated Service from earlier in this section, the secret already exists; if not, add the annotation now and the service-ca operator mints it within seconds:

```bash
oc get secret authorino-server-cert -n kuadrant-system 2>/dev/null || \
oc annotate service authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
```

Then enable the listener:

```bash
oc get secret authorino-server-cert -n kuadrant-system     # must exist before patching

oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {"listener": {"tls": {
    "enabled": true,
    "certSecretRef": {"name": "authorino-server-cert"}
  }}}}'
```

**(b) Mount the cluster service CA bundle.** OpenShift's service-ca operator populates any ConfigMap carrying the inject annotation. The mount must go through the Authorino CR (not the Deployment — the operator would reconcile a Deployment edit away), and the key→path mapping is required because the environment variables in (c) expect a file named `service-ca-bundle.crt`:

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

oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {"volumes": {"items": [{
    "name": "service-ca",
    "configMaps": ["openshift-service-ca"],
    "mountPath": "/etc/ssl/certs/openshift-service-ca",
    "items": [{"key": "service-ca.crt", "path": "service-ca-bundle.crt"}]
  }]}}}'
```

**(c) Environment variables** — the Authorino CR has no env field, so set these on the Deployment, on one line:

```bash
oc -n kuadrant-system set env deployment/authorino SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

oc rollout status deployment/authorino -n kuadrant-system --timeout=300s
```

> Because this is a Deployment-level setting and the operator regenerates the Deployment from the CR, **re-check it after any Authorino CR change or operator upgrade.**

**After applying, re-run the three checks from the top of this subsection.** `"tls":true` on both listeners is the confirmation. Finally:

```bash
oc get pods -n kuadrant-system      # authorino, limitador, kuadrant operator all Running
```

## 1.3 Enable User Workload Monitoring

**Check first:**

```bash
oc get pods -n openshift-user-workload-monitoring
```

If `prometheus-user-workload-0` is Running, user workload monitoring is already enabled — skip to §1.4.

Token metering and usage dashboards scrape from user workload monitoring. Enable it before traffic flows so you have a baseline.

```bash
# If cluster-monitoring-config already exists, EDIT it to add the key — this apply replaces it wholesale
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

## 1.4 Create the MaaS gateway

**Check first:**

```bash
oc get gateway maas-default-gateway -n openshift-ingress
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}'; echo
```

If the gateway exists, is `PROGRAMMED=True`, and its listener hostname is exactly `maas.<cluster-domain>`, it is already in place — skip the creation steps (a)–(d) and go straight to the verification in (e). If the hostname differs, treat that as a problem to fix before continuing: the RHOAI console expects `maas.<cluster-domain>` (see the note in (d)).

RHOAI 3.5 uses **two** gateways, and the distinction matters:

| Gateway | Owner | Purpose | Your action |
|---|---|---|---|
| `data-science-gateway` | Platform (`GatewayConfig`) | Dashboard, notebooks, OAuth | **Verify only — never edit.** The operator reconciles changes away. |
| `maas-default-gateway` | You | All MaaS traffic | **Create it.** MaaS will not create it, by design — it requires a cluster administrator to do so. |

**(a) Verify the platform gateway exists** (created by the RHOAI install):

```bash
oc get gatewayconfig default-gateway     # READY True
oc get gatewayclass                      # data-science-gateway-class, ACCEPTED True
```

The `data-science-gateway-class` GatewayClass is what your new gateway references below.

**(b) Identify the TLS certificate** for the gateway listener:

```bash
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME="${CERT_NAME:-router-certs-default}"
echo "cert=$CERT_NAME"
oc get secret ${CERT_NAME} -n openshift-ingress      # must exist
```

If no custom certificate is configured, the operator-generated wildcard `router-certs-default` is used. If your organization has a corporate wildcard certificate for `*.apps.<domain>`, reference that Secret instead — then the `-k` flag can be dropped from every `curl` in this guide.

**(c) Memory override.** The default 1 Gi Istio proxy limit is not enough once the policy extensions are compiled, and the gateway pod can be OOM-killed under load:

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

**(d) Create the gateway:**

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

oc wait --for=condition=Programmed gateway/maas-default-gateway -n openshift-ingress --timeout=180s
```

Four items here are load-bearing:

| Item | Why |
|---|---|
| `name: maas-default-gateway` | MaaS looks for this exact name in `openshift-ingress` |
| `gatewayClassName: data-science-gateway-class` | The RHOAI-provided class; generic classes like `openshift-default` do not exist here |
| `opendatahub.io/managed: "false"` | Lets the MaaS controller own the auth policies on this gateway |
| `hostname: maas.<cluster-domain>` | The RHOAI console UI expects exactly this hostname; a different one leaves the API working but the console model pages broken |

**(e) Verify and set the base URL:**

```bash
oc get gateway -A
oc get svc -n openshift-ingress | grep -i maas

echo "$MAAS_GW"
dig +short maas.${CLUSTER_DOMAIN}
curl -sk -o /dev/null -w "%{http_code}\n" "${MAAS_GW}/maas-api/health"
```

On a cloud cluster the gateway provisions a LoadBalancer automatically, and the cluster's wildcard DNS usually covers `maas.<domain>`. **At this stage the health check returning 404 or a connection error is expected** — `maas-api` does not exist until §1.6. What matters now is that DNS resolves and the gateway is `Programmed`.

**(f) On-premises clusters (no cloud load balancer).** Without a cloud LB controller, a `LoadBalancer` Service stays `Pending` forever. Switch the gateway Service to ClusterIP and expose it with a passthrough Route:

```bash
oc patch configmap maas-gateway-options -n openshift-ingress --type=merge -p '{
  "data": {"service": "spec:\n  type: ClusterIP\n"}}'

oc rollout restart deployment -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
sleep 30
oc get svc -n openshift-ingress | grep maas       # TYPE must now read ClusterIP

oc create route passthrough maas-gateway -n openshift-ingress \
  --service=maas-default-gateway-data-science-gateway-class \
  --port=443 --hostname="maas.${CLUSTER_DOMAIN}"
```

> **Passthrough, not reencrypt** — the gateway already terminates TLS with a certificate valid for the domain; SNI carries the hostname straight to the gateway. If `maas.<domain>` does not resolve, the fix is a DNS record for it pointing at the ingress VIP (or confirmation that the `*.apps` wildcard covers it) — that is a DNS change, not a gateway problem.

**(g) After any gateway listener or Service change, restart the gateway.** A replica can keep stale routing configuration, causing intermittent 503s:

```bash
oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
```

## 1.5 PostgreSQL for the MaaS API

**Check first:**

```bash
oc get secret maas-db-config -n redhat-ai-gateway-infra
```

If the secret exists — and, on a cluster where MaaS is already enabled, `maas-api` is Running (§1.0) — the database is already in place; skip to §1.6. If the secret exists but `maas-api` crash-loops, the connection URL or password inside it is the first suspect: `oc logs -n redhat-ai-gateway-infra deployment/maas-api --tail=100`.

`maas-api` stores hashed API keys, subscription bindings, and revocation state in PostgreSQL. **This must exist before MaaS is enabled** or `maas-api` crash-loops.

For production, use an external PostgreSQL instance (or at minimum a PVC-backed one): the quick in-cluster instance below uses ephemeral storage, so a database pod restart invalidates every issued MaaS API key.

```bash
oc new-project maas-db 2>/dev/null || oc project maas-db

read -rs PGPASS && export PGPASS   # type a password, Enter; nothing echoes
```

> Choose a password without `$ @ / : #` — those characters break the connection URL below.

```bash
oc new-app --name=maas-postgres \
  --image=registry.redhat.io/rhel9/postgresql-16:latest \
  -e POSTGRESQL_USER=maas \
  -e POSTGRESQL_PASSWORD="$PGPASS" \
  -e POSTGRESQL_DATABASE=maas

oc rollout status deployment/maas-postgres -n maas-db --timeout=300s
```

Create the connection secret in the MaaS infrastructure namespace, `redhat-ai-gateway-infra`. That namespace is created when MaaS is enabled, so create it up front — pre-existing secrets are picked up automatically:

```bash
oc create namespace redhat-ai-gateway-infra --dry-run=client -o yaml | oc apply -f -

oc create secret generic maas-db-config \
  -n redhat-ai-gateway-infra \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:${PGPASS}@maas-postgres.maas-db.svc.cluster.local:5432/maas?sslmode=disable"
```

For an external database: `postgresql://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require`

**Verify before continuing** — ten seconds here prevents a confusing crash-loop later:

```bash
oc get deployment,pods,svc -n maas-db

oc exec -n maas-db deployment/maas-postgres -- \
  psql "postgresql://maas:${PGPASS}@localhost:5432/maas" -c '\conninfo'
# You are connected to database "maas" as user "maas" ...
```

## 1.6 Enable MaaS

**Check first:**

```bash
oc get dsc default-dsc -o jsonpath='{.spec.components.aigateway}'; echo
curl -sk "${MAAS_GW}/maas-api/health"; echo
```

If the `aigateway` component shows both `managementState: Managed` and `modelsAsAService.managementState: Managed`, and the health check returns `{"status":"healthy"}`, MaaS is already enabled — skip to §1.7.

Everything MaaS needs now exists: Authorino, Limitador, the gateway, and the database.

The field path in 3.5 is `spec.components.aigateway` — note the spelling **`modelsAsAService`** ("AsA"); a misspelling is silently ignored, not rejected. (The older `kserve.modelsAsService` field is deprecated — do not use it.)

```bash
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {"components": {"aigateway": {
    "managementState": "Managed",
    "modelsAsAService": {"managementState": "Managed"}
  }}}}'
```

> If your DataScienceCluster has a different name, substitute it: `oc get dsc`.

Confirm **both** fields landed — a merge patch can silently drop the nested one:

```bash
oc get dsc default-dsc -o jsonpath='{.spec.components.aigateway}'; echo
```

Verify everything came up (allow a few minutes):

```bash
oc get dsc default-dsc                    # READY True
oc get aigateway -A                       # default-aigateway  READY True
oc get aitenant -A                        # READY True, GATEWAY maas-default-gateway
oc get maastenantconfig -A                # READY True, Reconciled
oc get pods -n redhat-ai-gateway-infra    # maas-api 1/1 Running

curl -sk "${MAAS_GW}/maas-api/health"; echo     # {"status":"healthy"}
```

If something stays Pending:

| Symptom | Cause | Fix |
|---|---|---|
| AITenant: "gateway openshift-ingress/maas-default-gateway not found" | Gateway missing | §1.4(d) |
| `maas-api` CrashLoopBackOff | Database unreachable or wrong password | `oc logs -n redhat-ai-gateway-infra deployment/maas-api --tail=100`; re-check §1.5 |
| Health check returns HTML | Wrong hostname — you reached the dashboard gateway | `MAAS_GW` must be `maas.<domain>` |

## 1.7 Console feature flags

**Check first:**

```bash
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | python3 -m json.tool
```

If `modelAsService`, `externalModels`, and `observabilityDashboard` are all `true`, skip to §1.8.

The MaaS-related console pages default to off. Enable them:

```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{
        "modelAsService": true,
        "externalModels": true,
        "observabilityDashboard": true
      }}}'
```

Then **hard-reload** the RHOAI console (Cmd/Ctrl-Shift-R — the UI caches aggressively). The relevant pages, split by function:

| Task | Console location |
|---|---|
| View registered models, including external | **AI hub → Models** |
| Mint and revoke MaaS API keys | **Gen AI studio → API keys** |
| Auth policies, subscriptions, quotas | **Settings → MaaS governance** |

## 1.8 Part 1 checkpoint

Re-run the four checks in §1.0 — all green means Part 1 is complete; continue with Part 2. If you created or changed the gateway along the way, restart it first (§1.4(g)) so no replica holds stale configuration.

---

# Part 2 — Validate the AWS Bedrock key

You already have a Bedrock API key. Validate it **from your workstation, before touching the cluster** — if this part fails, nothing downstream can work, and you would otherwise debug the wrong layer.

## 2.1 Confirm the endpoint

RHOAI talks to Bedrock's **OpenAI-compatible** endpoint, `bedrock-mantle.<region>.api.aws` — not the classic `bedrock-runtime` endpoint. It is available in `eu-west-1` (Ireland):

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models"
# 401 or 403 = endpoint exists (you simply haven't authenticated)
# 000 or 404 = wrong region or a network/proxy issue — resolve before continuing
```

## 2.2 Capture and check the key

```bash
read -rs BEDROCK_API_KEY && export BEDROCK_API_KEY     # paste the key, Enter; nothing echoes
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"
```

| Check | Expected | If wrong |
|---|---|---|
| `prefix` | `ABSK` | Wrong value copied — a Bedrock API key always starts with `ABSK` |
| `len` | **132** | **131 or fewer means a truncated copy** — re-copy the key |

> **A truncated key looks completely legitimate** — right prefix, plausible length — and AWS rejects it with a permission error that sends you off investigating IAM policies. Check the length first, always.

## 2.3 Test the key against Bedrock

List the models available in the region:

```bash
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  | jq -r '.data[] | select(.status=="available") | .id' | sort
```

`openai.gpt-oss-20b` must appear in the list. Then run one inference:

```bash
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

A successful response has a `choices` array with non-null `message.content`.

> **Always use `max_tokens` of 300 or more when testing this model.** `openai.gpt-oss-20b` is a reasoning model: it spends tokens on internal reasoning before producing the answer. With a small budget you get `finish_reason: "length"` and `content: null` — which looks broken but is only a truncated response.

If the call fails:

| Failure | Meaning |
|---|---|
| `invalid_api_key` | Check the key length first (§2.2); then confirm the IAM policy includes `bedrock-mantle:CallWithBearerToken` |
| `403` | IAM policy too narrow, or an organization SCP blocking Bedrock |
| `404` | Wrong endpoint or region |

Do not continue to Part 3 until this test passes.

---

# Part 3 — Connect Bedrock to MaaS

## 3.1 Namespace

```bash
oc create namespace ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -
oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite
oc get namespace ${MODEL_NS} --show-labels
```

**The label matters.** The MaaS gateway admits namespaces by this label (configured in §1.4(d)); without it the gateway silently rejects the model's route — no error, no event, the model simply never becomes reachable.

## 3.2 The credential Secret

Three requirements, all mandatory:

1. Same namespace as the `ExternalProvider` (next step)
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

> **The label must be exactly `inference.llm-d.ai/ipp-managed=true`.** Some older community guides show `inference.networking.k8s.io/bbr-managed` — that label is ignored by the credential watcher in this release, and every inference call then fails with `HTTP 500 ... authType 'apikey' credentials not found`, with no warning anywhere and the provider still reporting Ready.
>
> Use plain `oc create secret` as above, not `--dry-run | oc apply` — the apply path writes the key into a `last-applied-configuration` annotation, exposing it in plaintext to anyone with read access to the namespace.

**Confirm the credential watcher picked it up** — the watcher logs the event once, within seconds of the label landing:

```bash
oc logs -n openshift-ingress -l app=payload-processing --tail=300 | grep -i secret
```

The **most recent** event for `external-models/bedrock-api-key` must be `Secret added/updated in store` (a `Secret removed from store` entry is fine as history — e.g. from an earlier key deletion — as long as an add/update follows it).

If no such line exists at all: verify the label with `oc get secret bedrock-api-key -n ${MODEL_NS} --show-labels`, then restart the watcher so it re-lists labeled secrets (`oc rollout restart deployment -n openshift-ingress -l app=payload-processing`) and check the log again. Do not continue until the add/update line is there — nothing downstream will work. Also verify the stored key length:

```bash
oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' | base64 -d | wc -c   # 132
```

## 3.3 ExternalProvider

One provider serves every Bedrock model in the region — it defines where to connect and which credential to use.

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

Expect `PHASE: Ready`. Note that `spec.endpoint` is the **hostname only** — no scheme, no path.

> **`Ready` means the provider's resources were created, not that AWS accepted the credential.** The credential is proven end to end in Part 4.

## 3.4 ExternalModel

This maps the client-facing model name to the provider's model ID. Per the naming convention explained at the top of this guide, **the resource name, `modelName`, and `targetModel` are all `openai.gpt-oss-20b`**:

```bash
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
      targetModel: ${MODEL_NAME}
      weight: 100
EOF

oc get externalmodels.inference.opendatahub.io -n ${MODEL_NS}
```

| Field | Meaning |
|---|---|
| `metadata.name` | Resource name — the authorization layer matches the requested model against it, so it must equal `modelName` |
| `modelName` | The name clients put in the request body |
| `targetModel` | Bedrock's model ID — the generated route matches against it, so it must also equal `modelName` |
| `apiFormat` / `path` | `openai-chat` on `/v1/chat/completions` — the OpenAI-compatible API |

> Two CRD groups share the short name `externalmodels`; always use the fully-qualified `externalmodels.inference.opendatahub.io` in commands.

**Verify the generated route attached and matches correctly:**

```bash
oc get httproute ${MODEL_NAME} -n ${MODEL_NS} \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
```

Expected:

```
Accepted=True
ResolvedRefs=True
kuadrant.io/AuthPolicyAffected=True
kuadrant.io/TokenRateLimitPolicyAffected=True
```

`Accepted=False` almost always means the namespace label from §3.1 is missing. The two `kuadrant.io` conditions confirm that authentication and rate limiting are attached to the route.

Now confirm the route's model-name match — this is where the naming convention pays off:

```bash
oc get httproute ${MODEL_NAME} -n ${MODEL_NS} -o jsonpath='{.spec.rules}' \
  | python3 -m json.tool | grep -A2 'X-Gateway-Model-Name'
```

The `value` shown must be `openai.gpt-oss-20b` — which it is, automatically, because the controller fills it from `targetModel` and we made `targetModel` equal to the name clients send. No manual route editing is needed, now or after any operator reconciliation.

## 3.5 Expose the model through MaaS

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

**Expect `PHASE: Pending` with an empty ENDPOINT — that is correct at this point.** Look at why:

```bash
oc describe maasmodelref ${MODEL_NAME} -n ${MODEL_NS} | grep -A4 Conditions
```

```
GovernanceAttached  False  NoPairingFound   "No active subscription and auth policy pairing found"
RuntimeReady        True   RuntimeHealthy   "Backend is healthy"
Ready               False  BackendNotReady  "Awaiting governance pairing"
```

MaaS refuses to expose a model until both an access policy and a subscription reference it — ungoverned model exposure is impossible by construction. `RuntimeReady: True` is the important signal here: it confirms the provider, Secret, and endpoint from §3.2–3.4 are all correct. If it reads `False`, fix those sections before continuing.

## 3.6 Access policy and quota

**Check first:**

```bash
oc get maasauthpolicy,maassubscription -n models-as-a-service
```

If an Active auth policy and subscription already exist on this cluster, **reuse them instead of creating the pair below** — add this model to both with the two `oc patch` commands shown under "Adding more models later", and note the existing subscription's name: it is what goes in the `subscription` field when minting API keys in §4.2.

These two resources live in the **`models-as-a-service`** namespace:

- **`MaaSAuthPolicy`** — *who may call the model* (enforced by Authorino)
- **`MaaSSubscription`** — *how many tokens they may use* (enforced by Limitador)

The values below grant access to all authenticated cluster users with a quota of 100,000 tokens per hour. **Adjust the groups, quota, and metadata to your organization's policy** — for production, replace `system:authenticated` with real user groups and create one subscription per team, each with its own `costCenter`; that is the usage-attribution boundary.

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
    costCenter: "platform"
    organizationId: "default"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: users-standard
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: "system:authenticated"
  priority: 100
  tokenMetadata:
    costCenter: "platform"
    organizationId: "default"
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100000
          window: "1h"
EOF

sleep 20
oc get maasauthpolicy,maassubscription -n models-as-a-service   # PHASE Active
oc get maasmodelref -n ${MODEL_NS}                              # now Ready, ENDPOINT populated
```

---

# Part 4 — End-to-end verification

## 4.1 Get an OpenShift token

The MaaS admin API sits behind an auth proxy, so you need an OpenShift **token** (certificate-based kubeconfig auth is not enough):

```bash
oc whoami -t || echo "no token — log in with a user/password, or use the console's 'Copy login command'"
```

> **Two different credentials are in play.** Your OpenShift token authenticates *you* to the MaaS admin API. The MaaS API key it issues is what a *model consumer* uses for inference.

## 4.2 List the catalogue and mint an API key

List the catalogue — this also shows which subscription each model is paired with, and that is the name to use when minting the key:

```bash
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" \
  | jq -r '.data[] | "\(.id)  ready=\(.ready)  subs=\([.subscriptions[].name] | join(","))"'
```

Mint the key, using the subscription name shown above (`users-standard` if you created it in §3.6, or the cluster's pre-existing one):

```bash
export SUBSCRIPTION="users-standard"      # replace with the name from the listing above

API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d "{\"name\":\"install-verify\",\"subscription\":\"${SUBSCRIPTION}\",\"expiresIn\":\"24h\"}" | jq -r '.key')
echo "${API_KEY:0:12}..."
```

> If `echo` prints `null`, the POST was rejected — re-run it without the `| jq -r '.key'` to see the error. `invalid_subscription` means the `subscription` value does not match any Active `MaaSSubscription` that covers you and the model — check with `oc get maassubscription -n models-as-a-service` and the catalogue listing above.

(End users can do the same from the console: **Gen AI studio → API keys**.)

## 4.3 Inference through the gateway

Call the **gateway root** with the model in the request body — standard OpenAI style:

```bash
curl -sk -m 120 "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" | jq .
```

Expected shape:

```json
{"choices":[{"finish_reason":"stop","message":{"content":"Hello there, friend!","role":"assistant"}}],
 "model":"openai.gpt-oss-20b",
 "usage":{"prompt_tokens":68,"completion_tokens":45,"total_tokens":113}}
```

`usage.total_tokens` is what gets metered against the subscription quota.

> Do **not** call a namespaced path such as `${MAAS_GW}/external-models/...` — the gateway forwards the extra path prefix to AWS, which returns a 404 (recognizable by an `x-amzn-requestid` response header).

## 4.4 Stability check

```bash
for i in $(seq 1 6); do
  curl -sk -o /dev/null -w "call $i: %{http_code} in %{time_total}s\n" -m 60 \
    "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}"
done
```

Expect six 200s, each in roughly one second.

> **Intermittent 503s indicate a gateway replica with stale routing state** — a known behavior after Service changes, operator installs, or long uptime. The fix is a gateway restart, then re-run this loop:
>
> ```bash
> oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
> oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
> ```

## 4.5 Prove the governance works

Three negative tests — these failing *correctly* is as important as inference succeeding:

```bash
# Forged key → 403
curl -sk -o /dev/null -w "forged key:    %{http_code}\n" "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-NOTREAL" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"

# No credential → 401
curl -sk -o /dev/null -w "no auth:       %{http_code}\n" "${MAAS_GW}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"

# An unregistered model name → the request cannot be routed
curl -sk -o /dev/null -w "unknown model: %{http_code}\n" "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"some.other-model","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'
# expect 404 — or code 000 (empty reply) on some gateway versions; either way, refused
```

There is a fourth, more meaningful refusal — `403` with the header `x-ext-auth-reason: model_not_in_subscription` — returned when the requested model **is registered on the gateway but not covered by the caller's subscription**. Note what does *not* trigger it: the gateway has no knowledge of which models exist on Bedrock, so a real-but-unregistered Bedrock model ID behaves exactly like a fake name (the unroutable case above). The refusal requires the name to resolve to a registered model.

To demonstrate it, register a second real model — `openai.gpt-oss-120b` works well — and pair it with a **separate** subscription: follow "Adding more models later" with `M2_ID="openai.gpt-oss-120b"`, but in step 3 add the model to the auth policy and to a *new* subscription (e.g. `premium`, same shape as §3.6's) instead of the standard one. Then the same model gives opposite results for two valid keys:

```bash
# A standard-subscription key → refused, with a machine-readable reason
curl -sk -D- -o /dev/null "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"openai.gpt-oss-120b","messages":[{"role":"user","content":"hi"}],"max_tokens":300}' \
  | grep -iE '^HTTP|x-ext-auth-reason'
# HTTP/... 403
# x-ext-auth-reason: model_not_in_subscription

# A premium-subscription key → answered
curl -sk -m 120 "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${PREMIUM_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"openai.gpt-oss-120b","messages":[{"role":"user","content":"hi"}],"max_tokens":300}' \
  | jq -r '.choices[0].message.content'
```

That contrast is worth showing: a valid key is not a licence to use any model — access is scoped per subscription, and the refusal names the reason.

## 4.6 Demonstrate the token quota (optional)

This shows the metering enforcement in action: two subscriptions on the same model, one with a token budget so small that a single response exhausts it. A key from the standard subscription keeps answering; a key from the limited one answers **once**, then is refused until its window resets.

Create the limited subscription — 100 tokens per hour, far less than one `openai.gpt-oss-20b` response consumes:

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: demo-limited
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: "system:authenticated"
  priority: 50
  tokenMetadata:
    costCenter: "demo-limited"
    organizationId: "default"
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100
          window: "1h"
EOF

sleep 20
oc get maassubscription -n models-as-a-service     # both Active
```

Mint one key per subscription. In the request body, `name` is only a display label for the key itself — `subscription` is the field that decides which quota the key draws from (`SUBSCRIPTION` is the standard subscription's name from §4.2, e.g. `users-standard`):

```bash
KEY_STD=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d "{\"name\":\"quota-demo-key-1\",\"subscription\":\"${SUBSCRIPTION}\",\"expiresIn\":\"24h\"}" | jq -r '.key')

KEY_LIM=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"quota-demo-key-2","subscription":"demo-limited","expiresIn":"24h"}' | jq -r '.key')

echo "std=${KEY_STD:0:12}... lim=${KEY_LIM:0:12}..."
```

Both echoes must show a `sk-`-prefixed value — `null` means that mint failed (usually a `subscription` value that does not match an Active `MaaSSubscription`; see the note in §4.2).

Run the comparison — three calls on each key:

```bash
# first pass = KEY_STD (standard subscription), second pass = KEY_LIM (limited)
for KEY in "$KEY_STD" "$KEY_LIM"; do
  echo "--- key ${KEY:0:12}... ---"
  for i in 1 2 3; do
    curl -sk -o /dev/null -w "call $i: %{http_code}\n" -m 60 \
      "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}"
    sleep 2
  done
done
```

Expected result:

```
--- key sk-... (standard) ---
call 1: 200
call 2: 200
call 3: 200
--- key sk-... (limited) ---
call 1: 200
call 2: 429
call 3: 429
```

What happened: the first call on the limited key was admitted with the full 100-token budget available, but its response consumed roughly 200–300 tokens (this model spends tokens on reasoning). The budget is now overdrawn, so every further call returns `429 Too Many Requests` until the one-hour window resets. The standard key, drawing on a separate 100,000-token budget, is unaffected — same model, same gateway, different subscription.

> - Token accounting is applied when the *response* arrives, so admission of the very next request can lag by a second or two — hence the `sleep 2`. If call 2 still returns 200, call 3 will not.
> - For a repeatable demonstration, use a short window such as `"5m"` so the limited key recovers between runs.
> - Quotas are per subscription, not per key: two keys minted from `demo-limited` share the same 100-token budget.

Clean up afterwards if the limited subscription is not wanted:

```bash
oc delete maassubscription demo-limited -n models-as-a-service
```

**Installation complete.** Users can now mint their own API keys from **Gen AI studio → API keys** and call `${MAAS_GW}/v1/chat/completions` with `"model": "openai.gpt-oss-20b"` using any OpenAI-compatible client or SDK.

---

# Adding more models later

No new AWS credential and no new provider — the existing `ExternalProvider` is reused. **Keep the naming convention: one string for the resource names, the client-facing `modelName`, and the Bedrock model ID (`targetModel`).**

```bash
export M2_ID="mistral.mistral-large-3-675b-instruct"    # one name: resources, client-facing, Bedrock ID

# 1. Test the model against Bedrock directly FIRST
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${M2_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}" \
  | jq '{content: .choices[0].message.content, tokens: .usage.total_tokens}'

# 2. Register it
cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${M2_ID}
  namespace: ${MODEL_NS}
spec:
  modelName: ${M2_ID}
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: ${M2_ID}
      weight: 100
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${M2_ID}
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${M2_ID}
EOF

# 3. Attach governance — without this the model stays Pending
oc patch maasauthpolicy bedrock-access -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2_ID}\",\"namespace\":\"${MODEL_NS}\"}}]"

oc patch maassubscription users-standard -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2_ID}\",\"namespace\":\"${MODEL_NS}\",\"tokenRateLimits\":[{\"limit\":100000,\"window\":\"1h\"}]}}]"

# 4. Verify
sleep 20
oc get maasmodelref -n ${MODEL_NS}
curl -sk -m 60 "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${M2_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}" \
  | jq -r '.choices[0].message.content'
```

> Use OpenAI-compatible model families (`apiFormat: openai-chat`). Anthropic models on Bedrock use a different API format that this integration path does not currently support; token-quota enforcement also only applies to the `openai-chat` format.

---

# Troubleshooting

Work through the request path in order. First identify **where** the failure happened, then apply the matching fix:

| Symptom | Where it failed | Fix |
|---|---|---|
| `500 authType 'apikey' credentials not found` | Credential store | Secret label must be exactly `inference.llm-d.ai/ipp-managed=true` (§3.2) |
| `404`, gateway logs show `route_not_found` | The cluster — the request never left | The route's model-name match differs from the name clients send; confirm `modelName` = `targetModel` (§3.4) |
| `404` **with an `x-amzn-requestid` header** | AWS — wrong path | Call the gateway root, not a namespaced path (§4.3) |
| `400 ... does not support the '/v1/chat/completions' API` | AWS — wrong API format | Use an OpenAI-format model |
| `403` with `x-ext-auth-reason: model_not_in_subscription` | Authorization, working correctly | The requested model is not in the caller's subscription |
| `subscription ... does not include model ...` for a model the subscription **does** reference | Authorization — name mismatch | The model resources are named differently from the client-facing name; `metadata.name` must equal `modelName` (§3.4), and the subscription's `modelRefs` must use that name |
| `401` on a previously working key | The MaaS API key expired | Mint a new one (§4.2) |
| `503` on a fraction of calls | Stale gateway replica | Restart the gateway (§4.4) |
| `MaaSModelRef` Pending, `NoPairingFound` | Governance missing | §3.6 |
| `MaaSModelRef` Pending, `RuntimeReady=False` | Provider, Secret, or endpoint | Re-check §3.2–3.3 |
| `invalid_api_key` from AWS | Truncated key | The key must be exactly 132 characters (§2.2) |
| `content: null` with `finish_reason: "length"` | Token budget too small | Use `max_tokens: 300+` — this is a reasoning model (§2.3) |

Logs, in the order a request travels:

```bash
oc logs -n kuadrant-system deployment/authorino --tail=50           # auth decision
oc logs -n openshift-ingress -l app=payload-processing --tail=50    # model resolution, credential injection
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --tail=20
```

The payload-processing log names each stage: `maas-headers-guard` → `model-provider-resolver` → `api-translation` → `apikey-injection`. Whichever stage logs last is where the request failed.

---

# Operational notes

- **The AWS Bedrock key expires** per its configured lifetime (typically 90 days). An IAM user can hold two keys at once: create the new key, update the `bedrock-api-key` Secret, confirm the payload-processing log shows `Secret added/updated`, then delete the old key — zero-downtime rotation.
- **MaaS API keys expire** per their `expiresIn` at creation. An expired key returns `401`, which looks like an auth fault rather than an expiry — check key age first.
- **After any gateway, Service, or operator change**, restart the MaaS gateway deployment and re-run the six-call stability loop (§4.4).
- **When adding models**, always use one string for the resource names, `modelName`, and the Bedrock model ID — the naming convention this installation relies on (see the note in the Prerequisites section).
- **Database durability:** if the quick in-cluster PostgreSQL from §1.5 is still in use, plan the move to a managed/PVC-backed instance — a database restart invalidates every issued MaaS API key.
- **IAM scope:** review the policy attached to the Bedrock key's IAM user. `AmazonBedrockLimitedAccess` grants more than a gateway needs (model customization, guardrail deletion, marketplace subscription); `AmazonBedrockMantleInferenceAccess` is the narrower alternative. Whichever is used must include `bedrock-mantle:CallWithBearerToken`.
