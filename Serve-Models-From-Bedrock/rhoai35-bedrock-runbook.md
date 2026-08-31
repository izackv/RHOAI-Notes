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

### Redaction policy for this document

**This runbook is published in a public repository.** Environment-specific values must never appear in it.

| Never write | Use instead |
|---|---|
| The real sandbox / cluster ID | `<sandbox-id>` — e.g. `apps.rhoai.<sandbox-id>.opentlc.com` |
| Resolved IP addresses | `<gateway-ip>` |
| AWS account IDs | `<account-id>` |
| IAM credential IDs (`ACCA…`), user IDs (`AIDA…`) | `<credential-id>`, `<user-id>` |
| ABSK keys, passwords, tokens | never, in any form |
| ELB hostnames, internal cluster IPs | `<lb-hostname>`, `<cluster-ip>` |

This applies to reference values, worked examples, and pasted command output alike — including the "Reference cluster" column of the Appendix F site record sheet. Site-specific values belong in *your* copy of Appendix F, which stays out of the repository.

### Working variables

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
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

## 2.5 Gateways — verify the platform one, create the MaaS one

**RHOAI 3.5 GA uses TWO gateways.** This is the single most important structural fact in Part 2, and it is not in any guide.

| Gateway | Owner | Purpose | You |
|---|---|---|---|
| `data-science-gateway` | `GatewayConfig` (platform) | Dashboard, model catalog, notebooks, OAuth callback | **Verify only. Never edit** — the operator reconciles changes away. |
| `maas-default-gateway` | **You** | All MaaS traffic: `maas-api`, model endpoints | **Create it.** MaaS will not, by design. |

MaaS refuses to provision until the second one exists. The `AITenant` controller says so explicitly:

```
gateway openshift-ingress/maas-default-gateway not found:
the Gateway must be created by a network or cluster administrator
before AITenant can be provisioned
```

The name comes from `AITenant.spec.gateway.name`, which defaults to `maas-default-gateway`. It is a writable field, so you *could* point MaaS at `data-science-gateway` instead — **do not.** That Gateway is `GatewayConfig`-owned with a name-based namespace allowlist the platform controls, so admitting your model namespaces means fighting two controllers, and MaaS would need to add a listener to a Gateway it does not own.

### (a) Verify the platform Gateway

```bash
oc get gatewayconfig default-gateway          # READY True
oc get gatewayclass                           # data-science-gateway-class, ACCEPTED True
oc get gateway -A
oc get route -n openshift-ingress
```

The GatewayClass is created by the DSCI — you do not create one. Its name is `data-science-gateway-class`, **not** the `openshift-default` that generic Gateway API guides use; you need it for the MaaS Gateway below.

`GatewayConfig.spec` governs identity and ingress plumbing, not routing:

| Field | Purpose | Customer-site relevance |
|---|---|---|
| `certificate.type` | `SelfSigned` \| `Provided` \| `OpenshiftDefaultIngress` | Use `Provided` + `secretName` for a corporate cert |
| `domain` / `subdomain` | Dashboard hostname | Set explicitly if the default clashes with site DNS |
| `ingressMode` | `OcpRoute` \| `LoadBalancer` | `OcpRoute` on sandbox. Note this applies **only** to this Gateway |
| `oidc` | `clientID`, `clientSecretRef`, `issuerURL` | **Where you wire the customer's IdP** |
| `enableK8sTokenValidation` | Accept OpenShift tokens | Keep `true` |

Patch `GatewayConfig`, never the Gateway:

```bash
oc patch gatewayconfig default-gateway --type=merge -p '{"spec":{"subdomain":"rh-ai"}}'
```

> `LoadBalancerReady: False` on `data-science-gateway` is **normal** with `ingressMode: OcpRoute` — the Service stays ClusterIP and a Route provides access. Do not chase it.

### (b) Find the ingress certificate

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME="${CERT_NAME:-router-certs-default}"
echo "domain=$CLUSTER_DOMAIN cert=$CERT_NAME"

oc get secret -n openshift-ingress | grep -iE 'cert|tls'
```

`spec.defaultCertificate` is **empty** when no custom certificate is configured — that is normal, and the operator-generated wildcard `router-certs-default` in `openshift-ingress` is what you use. Confirm it appears in the secret list before continuing. At a customer site this is where their real wildcard secret goes, and `-k` disappears from every curl in this runbook.

### (c) Memory override

Istio's 1Gi default is not enough once Kuadrant compiles its Wasm extensions, and the gateway pod gets OOMKilled under load — an intermittent failure that is miserable to diagnose mid-demo.

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

### (d) Create the MaaS Gateway

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

**Four things here are load-bearing:**

| Item | Why |
|---|---|
| `name: maas-default-gateway` | Must match `AITenant.spec.gateway.name`. MaaS looks for this exact name in `openshift-ingress`. |
| `gatewayClassName: data-science-gateway-class` | The RHOAI-created class. `openshift-default` does not exist here. |
| `opendatahub.io/managed: "false"` | Lets maas-controller own the AuthPolicies; without it the ODH Model Controller overwrites them |
| `allowedRoutes` **by label** | Deliberately different from `data-science-gateway`'s name-based allowlist. MaaS does **not** overwrite this, so `maas.opendatahub.io/gateway-access=true` is how model namespaces get admitted in §4.1. |

### (e) Verify

```bash
oc get gateway -A
oc get svc -n openshift-ingress | grep -i maas
```

Reference result — note this Gateway gets a **real LoadBalancer**, because `ingressMode: OcpRoute` applies only to the GatewayConfig-managed Gateway:

```
data-science-gateway   ...svc.cluster.local                      True   (ClusterIP + Route)
maas-default-gateway   <lb-hostname>.us-east-1.elb.amazonaws.com True   (LoadBalancer)
```

Set your base URL and test:

```bash
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"     # LoadBalancer path; on a Route see §2.5(f)
echo "$MAAS_GW"

dig +short maas.${CLUSTER_DOMAIN}
curl -sk -o /dev/null -w "%{http_code}\n" "${MAAS_GW}/maas-api/health"
```

**Before §2.8 this returns 404 or a connection error — that is expected**, since `maas-api` does not exist yet. After §2.8 it must return **200**.

> **`MAAS_GW` is `maas.<cluster-domain>`, not the dashboard host.** Do not reuse `gatewayconfig status.domain` (`rh-ai.<domain>`) — that is the *dashboard* gateway. Requests for `/maas-api/*` sent there hit the dashboard's catch-all `/` route and return the dashboard's HTML with status 200, which looks like success. Record `MAAS_GW` in Appendix F.
>
> If `dig` returns nothing, the cluster's wildcard DNS does not cover `maas.<domain>`. On the reference sandbox it resolved without extra work. Otherwise add a DNS record for the ELB hostname, or create a passthrough Route.

### (f) On-prem / non-cloud: ClusterIP + Route

**On a cloud cluster the Gateway provisions a LoadBalancer automatically.** On-prem there is no cloud LB controller, so a `LoadBalancer` Service sits `Pending` forever and nothing reaches the gateway. Use ClusterIP plus an OpenShift Route instead.

This is the **verified** procedure — tested on the reference cloud cluster by forcing it down the on-prem path.

```bash
# Snapshot for rollback
oc get configmap maas-gateway-options -n openshift-ingress -o yaml > /tmp/maas-gw-options-backup.yaml

# The infrastructure ConfigMap accepts a `service` key alongside `deployment`
oc patch configmap maas-gateway-options -n openshift-ingress --type=merge -p '{
  "data": {"service": "spec:\n  type: ClusterIP\n"}}'

oc rollout restart deployment -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
sleep 30
oc get svc -n openshift-ingress | grep maas       # TYPE must now read ClusterIP
```

Then expose it with a **passthrough** Route:

```bash
oc create route passthrough maas-gateway -n openshift-ingress \
  --service=maas-default-gateway-data-science-gateway-class \
  --port=443 --hostname="maas.${CLUSTER_DOMAIN}"

oc get route maas-gateway -n openshift-ingress
curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health"; echo
```

> **Passthrough, not reencrypt.** The gateway already terminates TLS with a certificate valid for `*.apps.<domain>`, so re-encrypting at the router adds a hop and a trust relationship to get wrong. Reencrypt was tested here and failed — the router could not validate the backend certificate. Passthrough lets SNI carry the hostname straight to Envoy.
>
> `data-science-gateway` uses reencrypt, but its backend presents a `service-ca`-signed certificate the router already trusts. Yours does not.

**If the health check is empty or fails, check DNS before anything else:**

```bash
curl -vk "https://maas.${CLUSTER_DOMAIN}/maas-api/health" 2>&1 | tail -20
dig +short maas.${CLUSTER_DOMAIN}
dig +short anything-random.${CLUSTER_DOMAIN}     # does the wildcard work at all?
```

`Could not resolve host` is a DNS problem, not a Route problem. Prove the topology independently by bypassing the resolver:

```bash
ROUTER_IP=$(dig +short console-openshift-console.${CLUSTER_DOMAIN} | head -1)
curl -sk --resolve "maas.${CLUSTER_DOMAIN}:443:${ROUTER_IP}" \
  "https://maas.${CLUSTER_DOMAIN}/maas-api/health"; echo
```

`{"status":"healthy"}` here means the gateway, Route, and MaaS are all correct and **only DNS is outstanding** — on-prem that is a DNS ticket, not a technical blocker. Either the customer's `*.apps` wildcard already covers it, or their DNS admin adds `maas.<domain>` → ingress VIP.

#### Gotcha: switching an existing cloud gateway from LoadBalancer to ClusterIP

Only affects clusters that ran with a LoadBalancer first — a fresh on-prem build never hits this.

When the ELB existed, external-dns published a record for `maas.<domain>`. Removing the ELB leaves the **name registered but empty**, and an explicit record always shadows the wildcard. The signature:

```
dig maas.<domain>
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: ...
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1
```

**`NOERROR` with `ANSWER: 0`** — the name exists, has no address. Distinguish it from a broken wildcard:

```bash
dig +short anything-random.${CLUSTER_DOMAIN}    # wildcard healthy → returns router IPs
dig +short maas.${CLUSTER_DOMAIN}               # shadowed → returns nothing
```

Cache flushing does not help; a public resolver returns the same. **Use a different hostname** the wildcard covers and external-dns never claimed:

```bash
export MAAS_HOSTNAME="maas-gw.${CLUSTER_DOMAIN}"
dig +short ${MAAS_HOSTNAME}        # must return the router IPs

oc patch gateway maas-default-gateway -n openshift-ingress --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"${MAAS_HOSTNAME}\"}]"

oc delete route maas-gateway -n openshift-ingress
oc create route passthrough maas-gateway -n openshift-ingress \
  --service=maas-default-gateway-data-science-gateway-class \
  --port=443 --hostname="${MAAS_HOSTNAME}"

export MAAS_GW="https://${MAAS_HOSTNAME}"
curl -sk "${MAAS_GW}/maas-api/health"; echo
```

> **The Gateway listener hostname and the Route hostname must match.** With passthrough, SNI carries the hostname to Envoy, which matches its listener on it. A mismatch produces an empty response with no error — indistinguishable from the DNS failure above.
>
> Changing the hostname breaks nothing else: `AITenant` references the Gateway by **name**, not hostname. Only `MAAS_GW` changes, and everything downstream reads that variable.

> ## ⚠ The listener hostname MUST be `maas.<cluster-domain>`
>
> The MaaS **UI** hardcodes `maas.<cluster-domain>` for its API calls — it does not read the listener hostname or `MaaSModelRef.status.endpoint`. Any other hostname gives you a fully working API via curl and a broken console: empty **AI hub → Models**, and **Gen AI studio → API keys** failing with `invalid character '<' looking for beginning of value` (the dashboard's HTML returned instead of JSON).
>
> So the hostname-change workaround below is a **last resort**. If `maas.<domain>` is unusable, fix DNS rather than renaming — and expect the console to stay broken until you do.
>
> ```bash
> oc logs -n redhat-ods-applications deployment/maas-ui --tail=20 | grep -i endpoint
> ```

#### Read MAAS_GW from the cluster, never construct it

Once you are on a Route, the hostname is whatever the Route says — not a formula:

```bash
export MAAS_GW="https://$(oc get route maas-gateway -n openshift-ingress -o jsonpath='{.spec.host}')"
echo "$MAAS_GW"
curl -sk "${MAAS_GW}/maas-api/health"; echo
```

Reference cluster after the on-prem switch: `https://maas-gw.apps.rhoai.<sandbox-id>.opentlc.com`. Record it in Appendix F — Parts 4, 5 and 6 all read it.

### ALWAYS restart the gateway after a listener or Service change

Observed twice: one of the two replicas keeps stale upstream config, producing ~50% `503 UC,DC` after 60s timeouts while the rest succeed in under a second.

```bash
oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
```

Then run the six-call stability loop from §4.7 before trusting the result.

**Rollback to LoadBalancer:**

```bash
oc patch configmap maas-gateway-options -n openshift-ingress --type=json \
  -p '[{"op":"remove","path":"/data/service"}]'
oc rollout restart deployment -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
oc delete route maas-gateway -n openshift-ingress
```

**Alternative — MetalLB.** Keeps the manifest identical to §2.5(d), but needs MetalLB installed, an IPAddressPool on a free IP in the node subnet (**not** a node's own IP), *and* a DNS record for `maas.<domain>` pointing at that VIP — the `*.apps` wildcard points at the ingress VIP, not your new one. Two extra dependencies and a DNS ticket versus zero. Prefer ClusterIP + Route unless the customer specifically wants MaaS off the ingress path.

### Label namespaces that attach routes

```bash
oc label namespace redhat-ods-applications maas.opendatahub.io/gateway-access=true --overwrite
```

`external-models` gets this label in §4.1 and the guardrails namespace in §5.2. **Without it the Gateway silently rejects the HTTPRoute** — no error, no event, the model just never becomes reachable.

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

**Console alternative to `oc apply -f dsc.yaml`:** this is the *OpenShift* console (not the RHOAI dashboard) — **Administration → CustomResourceDefinitions → DataScienceCluster → Instances → Create DataScienceCluster**, YAML view, paste the manifest above. The masthead **+** → **Import YAML** does the same thing in one step.


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

#### 3.5 GA dashboard navigation

The nav was renamed in 3.5 — **"Data Science Projects" is now just "Projects"**. Any guide referencing the old label is 2.x-era. The 3.5 GA left nav is:

```
Home
Projects                  ← workbenches live here
AI hub
Learning resources
Applications              → Enabled | Explore
Settings                  → Cluster settings
                            Environment setup
                            Model resources and operations
                            User management
```

#### Option A — console

1. Open the dashboard and log in
2. **Projects** in the left nav → **Create project** → name it `bedrock-demo`
3. Open the project → **Workbenches** tab → **Create workbench**
4. Work down the form's left-hand steps:

| Step | What to set |
|---|---|
| **Name and description** | `bedrock-demo-wb` |
| **Workbench image** | `Jupyter \| Data Science \| CPU \| Python 3.12`, **Version selection: 3.5** (Python v3.12). Images are versioned in 3.5 — take the newest. |
| **Deployment size** | **Hardware profile: `default-profile`** — 2 CPU / 4 GiB. **Take the default; do not customize.** Ample for a notebook that pip-installs `openai` and makes HTTPS calls. |
| **Environment variables** | Skip. §6.2 pastes the MaaS key into the notebook. *(For a polished demo you could inject it from a Secret here instead.)* |
| **Cluster storage** | 20 GiB on the default StorageClass — usually prefilled |
| **Connections** | Skip. This is for S3/model connections; there are none in this scenario. |

5. **Create**

> **"Container size: Small" no longer exists.** 3.5 replaced the T-shirt size dropdown with **Hardware profiles**. `default-profile` gives 2 CPU / 4 GiB, customizable to 4 CPU / 8 GiB. Any guide offering Small/Medium/Large is 2.x-era.

#### Choosing the workbench image

3.5 renamed the images to a `Product | Variant | Accelerator | Python` scheme. **"Standard Data Science" no longer exists** — any guide naming it is 2.x-era. List what your cluster actually offers:

```bash
oc get imagestream -n redhat-ods-applications \
  -o custom-columns='NAME:.metadata.name,DISPLAY:.metadata.annotations.opendatahub\.io/notebook-image-name' \
  | sort
```

| Use | Display name | Imagestream |
|---|---|---|
| **Default for this runbook** | `Jupyter \| Data Science \| CPU \| Python 3.12` | `s2i-generic-data-science-notebook` |
| Smaller/faster alternative | `Jupyter \| Minimal \| CPU \| Python 3.12` | `s2i-minimal-notebook` |
| Part 5 guardrails work | `Jupyter \| TrustyAI \| CPU \| Python 3.12` | `odh-trustyai-notebook` |
| VS Code instead of Jupyter | `Code Server \| Data Science \| CPU \| Python 3.12` | `code-server-notebook` |

**Requirements are modest:** Python 3.x with `pip`, CPU-only. §6.2 installs the `openai` package and makes HTTPS calls — that is the entire workload.

**Avoid anything containing CUDA, ROCm, or Gaudi.** There is nothing to schedule against on a GPU-less cluster, they pull many GB for no benefit, and accelerator variants can sit Pending waiting for resources that do not exist.

> The `runtime-*` imagestreams with no display name are **pipeline runtimes, not workbench images**. They will not appear in the workbench picker. Ignore them.

> There is also a **Start basic workbench** button at the top right of the Projects page, which spins one up without creating a project. Fine for a quick check, but create the project — §6.2 and the demo narrative both assume it.

#### Option B — CLI

An RHOAI project is an ordinary namespace carrying the dashboard label. Without that label it exists in OpenShift but **will not appear in the dashboard**:

```bash
oc new-project bedrock-demo 2>/dev/null || oc project bedrock-demo
oc label namespace bedrock-demo opendatahub.io/dashboard=true --overwrite

oc get namespace bedrock-demo --show-labels | grep opendatahub.io/dashboard
```

Reload the dashboard and it appears under **Projects**.

> **If a project you created is missing from the list**, check two things: the `opendatahub.io/dashboard=true` label, and the **A.I. projects** filter chip at the top of the Projects page — an active filter will hide unlabelled or non-matching namespaces. Click **Clear all filters** to rule it out.

Creating the workbench itself from the CLI means writing a `Notebook` CR, which is fiddly and version-sensitive. Create the project with the CLI if you prefer, then use the console for the workbench.

**Watch it start:**

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
| Project missing from the dashboard | Namespace lacks `opendatahub.io/dashboard=true`, or an active filter chip on the Projects page |
| Notebook starts, `requests` call hangs | Egress blocked. Resolve before §6.2 |


## 2.8 Enable MaaS

Everything MaaS needs now exists: Authorino, Limitador, **the `maas-default-gateway`**, PostgreSQL, and a healthy RHOAI.

### The field path (changed in 3.5 GA)

`kserve.modelsAsService` is **deprecated** — kept for compatibility through at least 3.6, and one-directional: CEL allows `Managed→Removed` but blocks `Removed→Managed`. You cannot fall back to it.

```
spec.components.aigateway.managementState: Managed
spec.components.aigateway.modelsAsAService.managementState: Managed
```

**Spelling: `modelsAsAService` — "AsA".** Intentional, matching the `ai-gateway-operator` CRD's own field. A misspelling is silently ignored, not rejected.

```bash
oc explain datasciencecluster.spec.components.aigateway.modelsAsAService

oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {"components": {"aigateway": {
    "managementState": "Managed",
    "modelsAsAService": {"managementState": "Managed"}
  }}}}'

oc get dsc -w      # back to READY True, then Ctrl-C

# Confirm BOTH fields landed — a merge patch can silently drop the nested one
oc get dsc default-dsc -o jsonpath='{.spec.components.aigateway}'; echo
```

### What gets created, and where

Namespaces are **not** what 3.4 guides describe. Nothing lands in `redhat-ods-applications` except controllers.

| Resource | Namespace | Note |
|---|---|---|
| `AIGateway/default-aigateway` | cluster-scoped | Parent component CR. `oc get modelsasservice` returns nothing — MaaS is a *sub-component*, not its own CR |
| `ai-gateway-operator`, `maas-controller` | `redhat-ods-applications` | Controllers |
| **`maas-api`** | **`redhat-ai-gateway-infra`** | The API itself. ClusterIP :8443 + HTTPRoute `maas-api-route`. **Not** in `redhat-ods-applications` |
| `AITenant/models-as-a-service` | `ai-tenants` | Holds `spec.gateway.name` |
| `MaasTenantConfig/default-tenant` | `models-as-a-service` | API-key expiry + telemetry settings |
| `Config/default` | cluster-scoped | `limitadorScrapeInterval`, `usageLogging` |

### Verify

```bash
oc get dsc default-dsc -o jsonpath='{.status.conditions}' | python3 -m json.tool \
  | grep -A3 -E 'AIGatewayReady|ModelsAsAServiceReady'

oc get aigateway -A                       # default-aigateway  READY True
oc get aitenant -A                        # READY True, GATEWAY maas-default-gateway
oc get maastenantconfig -A                # READY True, REASON Reconciled
oc get pods -n redhat-ai-gateway-infra    # maas-api 1/1 Running
oc get httproute -A | grep -i maas        # maas-api-route

curl -sk "${MAAS_GW}/maas-api/health"; echo
```

`ModelsAsAServiceReady` should read *"modelsAsAService is Managed and deployments are available"*, and the health check must return **200**.

### If the tenant stays Pending / Failed

```bash
oc get aitenant -A -o yaml | grep -A8 'conditions:'
oc logs -n redhat-ods-applications deployment/maas-controller --tail=40
```

| Condition / log | Cause | Fix |
|---|---|---|
| `GatewayCheckFailed` / `GatewayNotReady`, *"gateway openshift-ingress/maas-default-gateway not found"* | The MaaS Gateway does not exist | §2.5(d). This is by design — MaaS never creates it |
| Gateway exists but name differs | `AITenant.spec.gateway.name` mismatch | `oc get aitenant -A -o jsonpath='{.items[0].spec.gateway.name}'` and match it |
| `maas-api` CrashLoopBackOff | Database | `oc logs -n redhat-ai-gateway-infra deployment/maas-api --tail=100` — see §2.6 |
| Health returns dashboard HTML | Called the wrong gateway | `MAAS_GW` must be `maas.<domain>`, not `rh-ai.<domain>` |
| `oc get modelsasservice` empty | Not an error | MaaS is a sub-component of `AIGateway`. Use `oc get aigateway -A` |

> **`maas-api` logs every request with an `auth_headers` field** — `Authorization=absent X-Api-Key=absent Cookie=absent ...`. That is the header-stripping evidence used in §6.5, available with no extra setup.

### Record in Appendix F

`MAAS_GW`, the tenant CRD kinds (`AITenant` + `MaasTenantConfig`), the infra namespace (`redhat-ai-gateway-infra`), and confirmation that namespace admission is **label-based** on this Gateway.

## 2.9 Dashboard feature flags

3.5 stripped `OdhDashboardConfig.spec.dashboardConfig` down to almost nothing — on a fresh install it contains only `disableTracking`. The CRD describes the field as *"intended to just contain overrides"*, so anything unset takes a default, and the MaaS-related features default to **off**.

### Inspect first

```bash
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | python3 -m json.tool

# Every flag your version accepts — do not trust any doc's list, including this one
oc explain odhdashboardconfig.spec.dashboardConfig --recursive

# Deprecated flags, which CEL will reject on write
oc get crd odhdashboardconfigs.opendatahub.io -o yaml | grep -i -B2 -A6 'DEPRECATED'
```

3.5 offers roughly 60 flags. The ones relevant here:

| Flag | Enables | Needed for |
|---|---|---|
| `modelAsService` | Models-as-a-Service UI | Part 4 |
| **`externalModels`** | **External model management UI** | **Part 4 — easy to miss** |
| **`guardrails`** | **Guardrails UI** | **Part 5** |
| `observabilityDashboard` | Token metering / observability | §6.3 |
| `genAiStudio` | GenAI Studio playground | Only if `llamastackoperator: Managed` |
| `vLLMDeploymentOnMaaS` | Deploy vLLM models through MaaS | Not needed for Bedrock. Relevant if the customer wants on-prem and external models behind one gateway |

### Apply

```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{
        "modelAsService": true,
        "externalModels": true,
        "guardrails": true,
        "observabilityDashboard": true
      }}}'

oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | python3 -m json.tool
```

> **Do NOT include `maasAuthPolicies`.** It exists in the schema but is **deprecated in 3.5**, and a CEL rule rejects any attempt to set it:
>
> ```
> Invalid value: "object": no such key: maasAuthPolicies evaluating rule:
> DEPRECATED: spec.dashboardConfig.maasAuthPolicies must be removed or left unchanged.
> ```
>
> The patch is rejected **atomically** — one deprecated field means none of the others apply, and `oc get` still shows the old content. Same one-directional CEL pattern as `kserve.modelsAsService` (§2.8).

If a patch is rejected and you cannot tell which field caused it, bisect:

```bash
for f in modelAsService externalModels guardrails observabilityDashboard; do
  printf "%-24s " "$f"
  oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
    --type=merge -p "{\"spec\":{\"dashboardConfig\":{\"$f\":true}}}" >/dev/null 2>&1 \
    && echo OK || echo REJECTED
done
```

### Verify

**Hard-reload the dashboard** (Cmd/Ctrl-Shift-R) — the UI is built from micro-frontends (`agentOps`, `evalHub`, `genAi`, `maas`, `modelRegistry`) that cache aggressively, so a normal refresh may not pick up flag changes.

The nav grows as components and flags are enabled. Reference cluster, before and after:

```
Before §2.8/§2.9          After §2.9 + hard reload
─────────────────────     ────────────────────────────────
Home                      Home
Projects                  Projects
AI hub                    AI hub
                            └─ Models              ← externalModels
Learning resources        Gen AI studio
Applications                └─ API keys            ← modelAsService
Settings                  Learning resources
                          Applications
                          Settings
                            ├─ Cluster settings
                            ├─ Environment setup
                            ├─ Model resources and operations
                            ├─ User management
                            └─ MaaS governance     ← modelAsService
```

**MaaS is not one menu — it is three, split by function.** Expect this question from anyone using the UI:

| Task | Where |
|---|---|
| Register / view models, incl. external | **AI hub → Models** |
| Mint and revoke MaaS API keys | **Gen AI studio → API keys** |
| Auth policies, subscriptions, quotas | **Settings → MaaS governance** |

That gives Parts 4 and 6 a console path as well as the curl commands — **Gen AI studio → API keys** is the UI equivalent of the `POST /maas-api/v1/api-keys` call in §4.6, and is the better option when demoing to a non-technical audience.

**Console:** **Administration → CustomResourceDefinitions → OdhDashboardConfig → odh-dashboard-config → YAML** (the OpenShift console, not the RHOAI dashboard).

> The operator recreates this resource with factory defaults if deleted, but does not overwrite edits to existing fields.

## 2.10 Part 2 exit criteria

Do not start Part 4 until all of these pass:

```bash
oc get csv -n openshift-operators | grep rhcl              # v1.4.2+ Succeeded
oc get pods -n kuadrant-system                             # authorino + limitador Running
oc get pods -n openshift-user-workload-monitoring          # prometheus-user-workload-0 Running
oc get gatewayconfig default-gateway                       # READY True
oc get gateway -A                                          # BOTH gateways PROGRAMMED=True
oc get aitenant -A                                         # READY True
oc get maastenantconfig -A                                 # READY True, Reconciled
oc get pods -n redhat-ai-gateway-infra                     # maas-api 1/1, has ADDRESS
oc get secret maas-db-config -n redhat-ods-applications    # exists
oc get dsc default-dsc                                     # READY True
oc get crd | grep maas.opendatahub.io                      # MaaS CRDs present
oc get pods -n openshift-ingress -l app=payload-processing # 1/1 Running
curl -sk "${MAAS_GW}/maas-api/health"                      # 200 (MAAS_GW = maas.<domain>)
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

Part 2 built the gateway. Part 3 proved the AWS credential. Now you connect them.

Nothing here deploys a model. You register an external endpoint and declare who may call it and how much.

## 4.0 The 3.5 GA object model

**This changed completely from 3.4.** The flat `ExternalModel` with `provider`/`endpoint`/`targetModel`/`credentialRef` no longer exists. 3.5 splits connection from presentation:

```
ExternalProvider  (inference.opendatahub.io)   WHERE + HOW to connect
  endpoint: bedrock-mantle.us-east-1.api.aws        FQDN only, no scheme/path
  provider: aws-bedrock                             API type
  auth: {type: apikey, secretRef: {name: ...}}      credential
        │
        │ referenced by name, same namespace
        ▼
ExternalModel  (inference.opendatahub.io)      WHAT clients ask for
  modelName: bedrock-claude-sonnet                  name clients use
  externalProviderRefs:                             ARRAY — one model, many providers
    - ref: {name: bedrock-us-east-1}
      apiFormat: openai-chat                        translation
      path: /v1/chat/completions                    outgoing :path
      targetModel: anthropic.claude-sonnet-5        provider's own model id
      weight: 100                                   traffic split
        │
        ▼
MaaSModelRef  (maas.opendatahub.io)            EXPOSE through the MaaS gateway
  modelRef: {kind: ExternalModel, name: ...}
```

Then `MaaSAuthPolicy` (who) and `MaaSSubscription` (how much), both in `models-as-a-service`.

**Verify the schema on your cluster before applying anything:**

```bash
oc get crd | grep inference.opendatahub.io
# externalmodels.inference.opendatahub.io
# externalproviders.inference.opendatahub.io

oc explain externalprovider.spec --recursive
oc explain externalmodel.spec --recursive
oc explain maasmodelref.spec --recursive
```

> **Two `externalmodels` CRDs exist.** `externalmodels.inference.opendatahub.io` is the live one; `externalmodels.maas.opendatahub.io` is legacy — the same deprecated-but-present pattern as `tenants` vs `aitenants`. If a command is ambiguous, fully qualify it: `oc get externalmodels.inference.opendatahub.io`.

**Why the split matters for the customer story:** because `externalProviderRefs` is an array with `weight`, one client-facing model name can fan out across several providers — the same model in two regions, or a canary between vendors — with no client change. That is the "provider portability" claim made concrete.

### Field reference

**ExternalProvider**

| Field | Notes |
|---|---|
| `endpoint` (req) | **FQDN only — no scheme, no path.** e.g. `bedrock-mantle.us-east-1.api.aws` |
| `provider` (req) | API type: `openai`, `anthropic`, `azure`, `aws-bedrock`, `vertex` |
| `auth.type` (req) | `apikey` \| `simple` \| `sigv4` \| `oauth2` |
| `auth.secretRef.name` (req) | Secret in the **same namespace**, data key **`api-key`** |
| `config` | Provider-specific k/v, e.g. Vertex `{"project": "...", "location": "..."}` |

**ExternalModel**

| Field | Notes |
|---|---|
| `modelName` | Name clients use. Defaults to `metadata.name` |
| `externalProviderRefs[].ref.name` (req) | ExternalProvider, same namespace |
| `externalProviderRefs[].apiFormat` (req) | `openai-chat` (`/v1/chat/completions`) or `messages` (Anthropic `/v1/messages`) |
| `externalProviderRefs[].path` (req) | Outgoing `:path` pseudo-header. Supports `{key}` placeholders from the merged config |
| `externalProviderRefs[].targetModel` (req) | The provider's own model id |
| `externalProviderRefs[].weight` | Traffic split across refs |
| `externalProviderRefs[].config` | Overrides the provider's config for this binding |

> **`path` is per-binding and templated**, which is what makes odd providers work. The 3.4 translator hardcoded `/v1/chat/completions`, so Google Gemini (which needs `/v1beta/openai/chat/completions`) simply 404'd. In 3.5 you set `path` and it works.
>
> **`auth.type: sigv4`** suggests native AWS SigV4 signing is supported, which would remove the long-lived ABSK key entirely. Not validated here — this runbook uses `apikey`, which is proven. Worth investigating for a production customer build, since "no long-lived AWS credential in the cluster" is a materially better security posture.

## 4.1 Namespace

```bash
export MODEL_NS="external-models"
oc create namespace ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -

# REQUIRED — maas-default-gateway admits namespaces BY LABEL
oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite

oc get namespace ${MODEL_NS} --show-labels
```

> The label is genuinely load-bearing here. `maas-default-gateway` (§2.5d) uses label-based `allowedRoutes`, unlike `data-science-gateway`'s name-based allowlist. Without it the Gateway **silently** rejects the HTTPRoute — no error, no event, the model just never becomes reachable. Check this first whenever anything in Part 4 fails.

## 4.2 Credential Secret

Three requirements: same namespace as the `ExternalProvider`, data key exactly **`api-key`** (mandated by the CRD), and the bbr-managed label.

**Re-validate the key first.** A truncated key stored in a Secret surfaces later as an opaque 401 from AWS buried in payload-processor logs.

```bash
echo "len=${#BEDROCK_API_KEY} prefix=${BEDROCK_API_KEY:0:4}"
# len=132 prefix=ABSK  — anything else, go back to §3.5

oc create secret generic bedrock-api-key \
  --from-literal=api-key="${BEDROCK_API_KEY}" \
  -n ${MODEL_NS} --dry-run=client -o yaml | oc apply -f -

# CRITICAL: this label, not the one in the 3.4 docs. See the warning below.
oc label secret bedrock-api-key -n ${MODEL_NS} \
  inference.llm-d.ai/ipp-managed=true --overwrite

oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' | base64 -d | wc -c
# 132
```

> ## ⚠ The documented Secret label is WRONG in 3.5 GA
>
> | | |
> |---|---|
> | **Required** | `inference.llm-d.ai/ipp-managed=true` |
> | Documented (3.4-era, inert) | `inference.networking.k8s.io/bbr-managed=true` |
>
> The payload processor's `apikey-injection-secret-watcher` only caches Secrets carrying `inference.llm-d.ai/ipp-managed`. With the documented label the Secret is silently ignored and every inference call fails:
>
> ```
> HTTP 500  inference error: Internal - authType 'apikey' credentials not found
> ```
>
> No RBAC error, no warning — the credential store is simply empty. Nothing about the Secret's name, namespace, data key, or the `ExternalProvider` matters until this label is right. Verified by extracting strings from the IPP binary (`grep -a '/ipp-managed' /bbr`).
>
> **Confirm the watcher picked it up** — this line must appear within seconds of labelling:
>
> ```bash
> oc logs -n openshift-ingress -l app=payload-processing --since=1m | grep -i 'Secret added'
> # "Secret added/updated in store" ... "key":"external-models/bedrock-api-key"
> ```
>
> If that line is absent, nothing downstream will work. Ruled out during diagnosis and **not** the cause: RBAC, the `api-key`/`apiKey` data-key name, the Secret's namespace, and model-level `auth` overrides.

**Console:** **Workloads → Secrets → Create → Key/value secret** in `external-models`. Name `bedrock-api-key`, key `api-key`. Then **Actions → Edit labels** and add `inference.llm-d.ai/ipp-managed=true`.

> Avoid `oc create ... --dry-run | oc apply` for Secrets: it writes the full base64 value into the `kubectl.kubernetes.io/last-applied-configuration` annotation, exposing the key in plaintext to anyone with read on the namespace. Use plain `oc create secret`.

> Never commit this. For GitOps use External Secrets Operator or Sealed Secrets — the `ExternalProvider` CR itself is safe to commit, holding only a `secretRef`.

## 4.3 ExternalProvider

One provider serves every Bedrock model in the region.

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
oc describe externalprovider bedrock-${AWS_REGION} -n ${MODEL_NS}
```

**Use `bedrock-mantle.<region>.api.aws`, not `bedrock-runtime`.** Only Mantle serves `/v1/chat/completions`; `bedrock-runtime` uses an `/openai/v1/` prefix and returns 404 for the path set below.

## 4.4 ExternalModels

Two models — you need a second for the model-swap demo in §6.2.

```bash
cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: bedrock-claude-sonnet
  namespace: ${MODEL_NS}
spec:
  modelName: bedrock-claude-sonnet
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: anthropic.claude-sonnet-5
      weight: 100
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: bedrock-gpt-oss-20b
  namespace: ${MODEL_NS}
spec:
  modelName: bedrock-gpt-oss-20b
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: openai.gpt-oss-20b
      weight: 100
EOF

oc get externalmodels.inference.opendatahub.io -n ${MODEL_NS}
```

Confirm the target model ids are available in your region first:

```bash
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  | jq -r '.data[] | select(.status=="available") | .id' | sort
```

### Verify the models attached to the gateway

`Ready` on the CR only means the CR reconciled. These three checks prove the route actually bound to `maas-default-gateway` — the difference between "HTTPRoute exists" and "HTTPRoute is accepted".

```bash
oc get externalmodels.inference.opendatahub.io -n ${MODEL_NS}    # PHASE Ready
oc get httproute -n ${MODEL_NS}                                   # one per model

# 1. Which Gateway did it attach to?
oc get httproute bedrock-claude-sonnet -n ${MODEL_NS} \
  -o jsonpath='{.spec.parentRefs}{"\n"}'

# 2. Was it accepted, and did Kuadrant attach its policies?
oc get httproute bedrock-claude-sonnet -n ${MODEL_NS} \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'

# 3. What path does it serve? (defines your inference URL)
oc get httproute bedrock-claude-sonnet -n ${MODEL_NS} \
  -o jsonpath='{.spec.rules[*].matches[*].path}{"\n"}'
```

Reference output:

```
parentRef:  name: maas-default-gateway, namespace: openshift-ingress

Accepted=True
ResolvedRefs=True
kuadrant.io/AuthPolicyAffected=True
kuadrant.io/TokenRateLimitPolicyAffected=True

{"type":"PathPrefix","value":"/external-models/bedrock-claude-sonnet"}
```

| Condition | Meaning if False |
|---|---|
| `Accepted` | Route rejected by the listener. Usually the namespace is missing `maas.opendatahub.io/gateway-access=true` (§4.1) — check this first |
| `ResolvedRefs` | A backend reference is unresolvable; check the ExternalProvider and its Secret |
| `kuadrant.io/AuthPolicyAffected` | Authorino is **not** protecting this route — the endpoint may be open. Investigate before demoing |
| `kuadrant.io/TokenRateLimitPolicyAffected` | Limitador is not metering this route; quotas will not apply |

> **The two Kuadrant conditions appear before you create any `MaaSAuthPolicy` or `MaaSSubscription`.** MaaS attaches default gateway-level policies as soon as a model route exists. Your §4.6 objects refine who and how much; they are not what turns protection on.

The path prefix gives you the inference URL:

```
${MAAS_GW}/<model-namespace>/<model-name>/v1/chat/completions
```

On the reference cluster: `https://maas-gw.apps.<sandbox-id>.../external-models/bedrock-claude-sonnet/v1/chat/completions`

> **Model choice for the demo.** `gpt-oss-20b` is a reasoning model — reasoning tokens count against `max_tokens` and against your metering, so the analyst sees three words while chargeback shows hundreds of tokens. That muddies the metering story. Use `anthropic.claude-sonnet-5` or `anthropic.claude-haiku-4-5` for anything customer-facing; keep `gpt-oss-20b` for cheap plumbing tests.
>
> Both models here use `apiFormat: openai-chat` because Bedrock Mantle presents an OpenAI-compatible API even for Anthropic models. Use `messages` only against the Anthropic API directly.

## 4.5 MaaSModelRef

Exposes each model through the MaaS gateway.

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: bedrock-claude-sonnet
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: bedrock-claude-sonnet
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

oc get maasmodelref -n ${MODEL_NS}
```

`modelRef.kind` accepts `ExternalModel` or `LLMInferenceService` — the latter is how you would expose an on-prem vLLM model through the same gateway. Optional fields: `endpointOverride` and `tenantRef` (defaults to the single tenant).

### Expect `Pending` here — this is by design

Immediately after creating the MaaSModelRefs:

```
NAME                    PHASE     ENDPOINT   HTTPROUTE               GATEWAY
bedrock-claude-sonnet   Pending              bedrock-claude-sonnet   maas-default-gateway
```

**`Pending` with an empty ENDPOINT is correct at this point.** It does not clear on its own — waiting will not help. `oc describe` shows why:

```
GovernanceAttached  False  NoPairingFound   "No active subscription and auth policy pairing found"
RuntimeReady        True   RuntimeHealthy   "Backend is healthy"
Ready               False  BackendNotReady  "Awaiting governance pairing"
```

**MaaS refuses to expose a model until both a `MaaSAuthPolicy` and a `MaaSSubscription` reference it.** A model cannot be reachable without someone having declared who may call it and how much they may spend. Complete §4.6 and it flips to Ready within seconds.

| Condition | Reading |
|---|---|
| `RuntimeReady=True` | **The provider connection works.** Your ExternalProvider, Secret and Bedrock endpoint are all correct — a strong signal that Part 3 and §4.3 are sound |
| `GovernanceAttached=False` / `NoPairingFound` | Normal before §4.6. If it persists *after* §4.6, the `modelRefs[].name`/`namespace` in the policy or subscription do not match the MaaSModelRef |
| `RuntimeReady=False` | A real problem — provider, Secret, or endpoint. Do not proceed to §4.6 |

> **Worth saying out loud to the customer.** Ungoverned exposure is not possible by construction: no auth policy and no subscription means no endpoint. This is not a setting an administrator can forget to switch on.

After §4.6 completes:

```
NAME                    PHASE   ENDPOINT                                      HTTPROUTE               GATEWAY
bedrock-claude-sonnet   Ready   https://maas-gw.apps.<sandbox-id>...          bedrock-claude-sonnet   maas-default-gateway
```

The ENDPOINT is read live from the Gateway listener, so it reflects any hostname change made in §2.5(f).

### Verify (after §4.6 — see the note above)

```bash
oc get externalprovider,externalmodels.inference.opendatahub.io,maasmodelref -n ${MODEL_NS}
oc get httproute -n ${MODEL_NS}
oc get serviceentry,destinationrule -n ${MODEL_NS} 2>/dev/null
oc logs -n openshift-ingress -l app=payload-processing --tail=40
```

If a `MaaSModelRef` will not go Ready:

```bash
oc describe maasmodelref bedrock-claude-sonnet -n ${MODEL_NS}
oc describe externalmodels.inference.opendatahub.io bedrock-claude-sonnet -n ${MODEL_NS}
oc get namespace ${MODEL_NS} --show-labels | grep gateway-access   # the usual culprit
```

## 4.5b Fix the generated HTTPRoute — REQUIRED

**The route the controller generates cannot match any request.** Without this fix every inference call returns `404 route_not_found` from Envoy.

### The bug

The generated HTTPRoute carries four rules. The catch-all (`PathPrefix: /`) matches on header `X-Gateway-Model-Name` set to the **`targetModel`**:

```yaml
matches:
  - headers:
      - name: X-Gateway-Model-Name
        value: openai.gpt-oss-20b        # targetModel
    path: {type: PathPrefix, value: /}
```

But the pre-processing IPP sets that header from the request body's `model` field, which is the **`modelName`** clients use:

```
bodyfieldtoheader: "parsed field from body"  field=model  value="bedrock-gpt-oss-20b"
```

`bedrock-gpt-oss-20b` ≠ `openai.gpt-oss-20b`, so the rule never matches.

### The fix

```bash
for m in bedrock-gpt-oss-20b bedrock-claude-sonnet; do
  oc patch httproute $m -n ${MODEL_NS} --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/3/matches/0/headers/0/value\",\"value\":\"$m\"}]"
done

# Confirm and re-check after a minute — the controller may reconcile it away
oc get httproute bedrock-gpt-oss-20b -n ${MODEL_NS} \
  -o jsonpath='{.spec.rules[3].matches[0].headers[0].value}'; echo
sleep 60
oc get httproute bedrock-gpt-oss-20b -n ${MODEL_NS} \
  -o jsonpath='{.spec.rules[3].matches[0].headers[0].value}'; echo
```

On the reference cluster the patch **survived** reconciliation. Re-check it before any demo, and re-apply after any `ExternalModel` change — editing the model triggers a route rebuild.

Verify rule 3 is the right index first; the layout may differ:

```bash
oc get httproute bedrock-gpt-oss-20b -n ${MODEL_NS} -o jsonpath='{.spec.rules}' | python3 -m json.tool | grep -n 'X-Gateway-Model-Name' -A2
```

## 4.5c The client endpoint

**Clients call the gateway root with the model in the body — OpenAI style.** Not the namespaced path.

| | |
|---|---|
| ✅ **Correct** | `${MAAS_GW}/v1/chat/completions` with `{"model": "bedrock-gpt-oss-20b", ...}` |
| ❌ Wrong | `${MAAS_GW}/external-models/bedrock-gpt-oss-20b/v1/chat/completions` |

The namespaced path *does* route to AWS, but Bedrock receives the full prefix as its own path and returns **404 with an `x-amzn-requestid` header** — an AWS error, not a cluster one. That header is the giveaway: if a 404 carries `x-amzn-requestid`, the request reached AWS and the path is wrong; if Envoy logs `route_not_found`, it never left the cluster.

This matches the catalogue, where `/maas-api/v1/models` returns `url` as the bare gateway host with no path.

### apiFormat must match the model

| Model family on Bedrock Mantle | `apiFormat` | `path` |
|---|---|---|
| OpenAI (`openai.gpt-oss-*`) | `openai-chat` | `/v1/chat/completions` |
| Anthropic (`anthropic.claude-*`) | see note | see note |

If a model rejects the API you send, AWS says so precisely:

```json
{"error":{"code":"validation_error",
 "message":"The model 'anthropic.claude-sonnet-5' does not support the '/v1/chat/completions' API"}}
```

**Unresolved:** switching Claude to `apiFormat: messages` with `path: /v1/messages` produced a 404 from AWS. The correct Mantle path for Anthropic-native format was not determined. **Use an OpenAI-family model for the demo** — `openai.gpt-oss-20b` is verified working end to end.

## 4.5d Adding another Bedrock model

Repeatable procedure, verified. Bedrock Mantle exposes 50+ models through the one ABSK credential and the one `ExternalProvider` — adding a model is five resources, no new AWS anything.

### Step 1 — Assess candidates BEFORE registering

Test against Bedrock directly. This bypasses RHOAI entirely, so a failure here is AWS's and you have not touched the cluster.

```bash
# Everything available in your region
curl -s "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/models" \
  -H "Authorization: Bearer ${BEDROCK_API_KEY}" \
  | jq -r '.data[] | select(.status=="available") | .id' | sort
```

Then benchmark the shortlist — status, token cost, and whether `content` is actually populated:

```bash
for m in openai.gpt-oss-120b mistral.mistral-large-3-675b-instruct qwen.qwen3-32b \
         google.gemma-3-27b-it deepseek.v3.2 nvidia.nemotron-nano-9b-v2; do
  printf "%-42s " "$m"
  code=$(curl -s -o /tmp/r.json -w "%{http_code}" -m 60 \
    "https://bedrock-mantle.${AWS_REGION}.api.aws/v1/chat/completions" \
    -H "Authorization: Bearer ${BEDROCK_API_KEY}" -H "Content-Type: application/json" \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}")
  echo -n "$code  "
  jq -r 'if .choices then "\(.usage.total_tokens) tok | \(.choices[0].message.content // "NULL — reasoning only")" else .error.message end' /tmp/r.json
done
```

Reference results, same prompt:

| Model | Tokens | Verdict |
|---|---|---|
| `mistral.mistral-large-3-675b-instruct` | **15** | Best — direct answer, different vendor |
| `deepseek.v3.2` | 17 | Clean |
| `qwen.qwen3-32b` | 26 | Clean |
| `google.gemma-3-27b-it` | 32 | Clean, but emoji and an aside |
| `openai.gpt-oss-120b` | 170 | Reasoning tokens |
| `nvidia.nemotron-nano-9b-v2` | 319 | Reasoning tokens leaked into `content` — avoid |
| `anthropic.claude-*` | — | **400: does not support `/v1/chat/completions`** |

**What to look for:**

- **Token count for a trivial prompt.** Reasoning models spend hundreds before answering. `gpt-oss-20b` used 214 tokens on a three-word greeting; mistral used 15. Those tokens are billed and metered, so a reasoning model muddies any cost or quota story.
- **`content` is not null.** Reasoning models return `finish_reason: "length"` with `content: null` when `max_tokens` is too low — looks broken, isn't. Test at 300.
- **Reasoning leaking into `content`.** Nemotron returned its entire monologue as the answer. Fine for a chatbot, terrible in a demo.
- **Vendor diversity.** For the §6.2 model-swap moment, a different vendor makes the portability point far better than another model from the same family.
- **Anthropic models reject `openai-chat`** on Mantle and the Messages path is unresolved (Appendix G §4).

### Step 2 — Register it

```bash
export M2_NAME="mistral-large"                              # client-facing name
export M2_TARGET="mistral.mistral-large-3-675b-instruct"    # Bedrock model id

cat <<EOF | oc apply -f -
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${M2_NAME}
  namespace: ${MODEL_NS}
spec:
  modelName: ${M2_NAME}
  externalProviderRefs:
    - ref:
        name: bedrock-${AWS_REGION}      # the existing provider — no new credential
      apiFormat: openai-chat
      path: /v1/chat/completions
      targetModel: ${M2_TARGET}
      weight: 100
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${M2_NAME}
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${M2_NAME}
EOF
```

### Step 3 — Governance (or it stays Pending)

A model with no `MaaSAuthPolicy` **and** `MaaSSubscription` referencing it never becomes Ready (§4.5).

```bash
oc patch maasauthpolicy bedrock-access -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2_NAME}\",\"namespace\":\"${MODEL_NS}\"}}]"

oc patch maassubscription analysts-standard -n models-as-a-service --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/modelRefs/-\",\"value\":{\"name\":\"${M2_NAME}\",\"namespace\":\"${MODEL_NS}\",\"tokenRateLimits\":[{\"limit\":100000,\"window\":\"1h\"}]}}]"
```

### Step 4 — Patch the HTTPRoute (§4.5b bug)

Every new model needs this. Wait for the route to exist first.

```bash
sleep 20
oc patch httproute ${M2_NAME} -n ${MODEL_NS} --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/3/matches/0/headers/0/value\",\"value\":\"${M2_NAME}\"}]"
```

### Step 5 — Verify

```bash
oc get maasmodelref -n ${MODEL_NS}        # PHASE Ready, ENDPOINT populated

curl -sk -m 60 "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${M2_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in 3 words.\"}],\"max_tokens\":300}" \
  | jq '{content: .choices[0].message.content, tokens: .usage.total_tokens}'
```

Reference: `{"content": "\"Hey there, friend!\"", "tokens": 17}` — Ready in 49s from apply to working call.

### The customer point

Adding a model touched **no AWS resource, no new credential, no client change**. Same `ExternalProvider`, same ABSK key, same analyst API key. Two CRs and two patches, and every analyst on that subscription can use it immediately by changing one string.

Note the cost contrast for §6.3: the same prompt costs **214 tokens on `gpt-oss-20b` and 15 on `mistral-large`** — 14×. That is a live argument for per-model metering, and it lands better than a slide.

## 4.6 Access policy and quota

These live in **`models-as-a-service`**, not the model namespace. Two tiers, so §6.3 can exhaust one on camera.

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: bedrock-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: bedrock-claude-sonnet
      namespace: ${MODEL_NS}
    - name: bedrock-gpt-oss-20b
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
    - name: bedrock-claude-sonnet
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 100000
          window: "1h"
    - name: bedrock-gpt-oss-20b
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
  priority: 10
  modelRefs:
    - name: bedrock-gpt-oss-20b
      namespace: ${MODEL_NS}
      tokenRateLimits:
        - limit: 500
          window: "1h"
EOF

sleep 20
oc get maasauthpolicy,maassubscription -n models-as-a-service
# both PHASE Active

oc get maasmodelref -n ${MODEL_NS}
# PHASE now Ready, ENDPOINT populated — the governance pairing from §4.5 is satisfied
```

- **`MaaSAuthPolicy`** — *who may call*. Enforced by Authorino.
- **`MaaSSubscription`** — *how many tokens*. Enforced by Limitador.

**Three 3.5 fields that make the chargeback story concrete:**

| Field | Use |
|---|---|
| `tokenMetadata` / `meteringMetadata` — `costCenter`, `organizationId`, `labels` | Tags every metered call. This is what turns raw token counts into a finance-department report. |
| `modelRefs[].billingRate.perToken` | Attaches a price to tokens, so the dashboard shows cost, not just usage |
| `priority` | QoS ordering between subscriptions under contention |

For the real engagement, replace `system:authenticated` with actual OpenShift or OIDC groups and create one subscription per department with its own `costCenter`. That is the chargeback boundary and the thing the customer is actually buying.

**Console:** **Settings → MaaS governance** (enabled in §2.9) manages policies and subscriptions.

## 4.7 Smoke test — verified working

```bash
export MAAS_GW="https://$(oc get route maas-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || echo "maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')")"
curl -sk "${MAAS_GW}/maas-api/health"; echo    # {"status":"healthy"}
```

The MaaS admin API sits behind `kube-auth-proxy`, so you need an OpenShift **token** — certificate-based kubeconfig auth is not enough:

```bash
oc whoami -t || echo "no token — oc login -u <user> -p <password>, or console → Copy login command → Display Token"
```

> **Two different credentials.** The OpenShift token authenticates *you* to the MaaS admin API. The MaaS API key it returns is what an *analyst* uses to call models. You need the first to create the second.

```bash
# Catalogue
curl -sk "${MAAS_GW}/maas-api/v1/models" \
  -H "Authorization: Bearer $(oc whoami -t)" | jq -r '.data[] | "\(.id)  ready=\(.ready)"'

# Mint an analyst key
API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"demo-key","subscription":"analysts-standard","expiresIn":"24h"}' | jq -r '.key')
echo "${API_KEY:0:12}..."

# INFERENCE — root path, model in the body
curl -sk -m 120 "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"bedrock-gpt-oss-20b","messages":[{"role":"user","content":"Say hello in 3 words."}],"max_tokens":300}' | jq .
```

Verified response shape:

```json
{"choices":[{"finish_reason":"stop","message":{
   "content":"Hello, friend, world!",
   "reasoning":"The user asks...","role":"assistant"}}],
 "model":"openai.gpt-oss-20b",
 "usage":{"completion_tokens":214,"prompt_tokens":74,"total_tokens":288}}
```

Note `model` in the response is the **targetModel** — proof the gateway substituted it. And `usage.total_tokens` is what Limitador meters and what a chargeback report is built from.

**Console alternative:** **Gen AI studio → API keys** mints and revokes keys in the UI — better than curl for a non-technical audience.

### Prove stability before demoing

```bash
for i in $(seq 1 6); do
  curl -sk -o /dev/null -w "call $i: %{http_code} in %{time_total}s\n" -m 60 \
    "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"bedrock-gpt-oss-20b","messages":[{"role":"user","content":"hi"}],"max_tokens":300}'
done
```

Want six 200s around 1s each. Reference cluster: 0.92–1.60s.

> ## ⚠ Intermittent 503s = one bad gateway replica
>
> If roughly half your calls return **503 after ~60 seconds** while the rest succeed in under a second, the gateway has two replicas and one is serving stale upstream configuration. Envoy logs `UC,DC downstream_remote_disconnect` — and the *pod address* differs between failures and successes:
>
> ```
> 503 UC,DC  10.129.2.41  59382ms     ← stale replica
> 200        10.131.0.44    409ms     ← healthy replica
> ```
>
> ```bash
> oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
>   --tail=20 | grep 'chat/completions'
> ```
>
> Compare the second-to-last IP column across 200s and 503s. Fix:
>
> ```bash
> oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
> oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
> ```
>
> Most likely after changing the gateway Service type (§2.5f) or the listener hostname. **Always run the six-call loop before a demo** — a coin-flip failure rate on camera is worse than no demo.

### Interpreting failures

| Symptom | Where it failed | Fix |
|---|---|---|
| `500 inference error: ... credentials not found` | IPP credential store | Secret label — §4.2 |
| `404`, Envoy logs `route_not_found` | Envoy, never left the cluster | HTTPRoute header — §4.5b |
| `404` **with `x-amzn-requestid`** | AWS — wrong path | Use the root endpoint — §4.5c |
| `400 ... does not support the '/v1/...' API` | AWS — wrong apiFormat | §4.5c |
| `403 x-ext-auth-reason: model_not_in_subscription` | Authorino — working correctly | Use `modelName`, not `targetModel`, in the body |
| `503 UC,DC` ~50% of calls | One stale gateway replica | Restart the gateway (above) |

Save the key — Parts 5 and 6 use it. Record `MAAS_GW` in Appendix F.

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
export MAAS_HOST="maas.${CLUSTER_DOMAIN}"
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

# PART 6 — The demo

Written against the **verified working state**. Every command here was run successfully on the reference cluster. Where something is not yet working, it says so.

---

## 6.0 Pre-flight — 10 minutes before

Do not skip. Two of these have bitten during this build.

```bash
# 1. Environment
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
export MODEL_NS="external-models"
export MODEL="bedrock-gpt-oss-20b"
export MODEL2="mistral-large"        # cross-vendor swap for §6.2
echo "$MAAS_GW"

# 2. Health
curl -sk "${MAAS_GW}/maas-api/health"; echo     # {"status":"healthy"}

# 3. The HTTPRoute patch survived (§4.5b) — re-apply if not
for m in ${MODEL} ${MODEL2}; do
  printf "%-24s " "$m"
  oc get httproute $m -n ${MODEL_NS} \
    -o jsonpath='{.spec.rules[3].matches[0].headers[0].value}'; echo   # must equal $m
done

# 4. Credential is in the IPP store
oc get secret bedrock-api-key -n ${MODEL_NS} \
  -o jsonpath='{.metadata.labels}'; echo        # inference.llm-d.ai/ipp-managed: "true"

# 5. Fresh API key (they expire — mint a new one for the demo)
API_KEY=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"demo","subscription":"analysts-standard","expiresIn":"24h"}' | jq -r '.key')
echo "${API_KEY:0:12}..."

# 6. STABILITY — six clean calls or restart the gateway
for i in $(seq 1 6); do
  curl -sk -o /dev/null -w "call $i: %{http_code} in %{time_total}s\n" -m 60 \
    "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":300}"
done
```

Any 503 → restart the gateway and repeat step 6:

```bash
oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
```

Also open ahead of time: the RHOAI dashboard (logged in), the `bedrock-demo` workbench (started — first launch is slow), a terminal with the variables exported, and the AWS console on Bedrock → API keys if you plan to show the "before" state.

**Use `bedrock-gpt-oss-20b`.** `bedrock-claude-sonnet` reports `ready=true` but does not serve — Anthropic models on Bedrock Mantle reject `/v1/chat/completions` and the correct path is unresolved (Appendix G §4). Do not demo it.

---

## 6.1 The setup — 2 minutes, no terminal

Say this before touching anything.

> "Today your analysts hold a Bedrock URL and a long-lived AWS key on their desktops. That works — they're productive. But there's no way to revoke one analyst without rotating the key for everyone, no record of who spent what, no ceiling before the invoice arrives, and that AWS credential sits in a browser tab.
>
> What I'll show you is the same models, the same code, the same speed — with the credential moved inside your cluster and every call attributed and capped."

Then the architecture in one breath:

```
analyst → RHOAI gateway → AWS Bedrock
             │
             ├─ validates the analyst's key, strips it
             ├─ meters tokens against their quota
             └─ injects the AWS credential from a Secret
```

**The one-line version:** the analyst's key never reaches AWS, and the AWS key never reaches the analyst.

---

## 6.2 Demo 1 — The analyst experience (Workbench)

Open the workbench in `bedrock-demo`. New notebook.

```python
!pip install openai --quiet
```

```python
from openai import OpenAI

MAAS_GW = "https://maas.apps.<your-domain>"
API_KEY = "sk-oai-..."          # paste the key from pre-flight

client = OpenAI(base_url=f"{MAAS_GW}/v1", api_key=API_KEY)

resp = client.chat.completions.create(
    model="bedrock-gpt-oss-20b",
    messages=[{"role": "user",
               "content": "Summarise the risks of long-lived API keys in three bullets."}],
    max_tokens=300,
)
print(resp.choices[0].message.content)
print("\ntokens:", resp.usage.total_tokens)
```

**Say while it runs:**

> "This is the standard OpenAI SDK, unmodified. Two lines differ from what your analysts run today: the base URL and the key. No AWS SDK, no boto3, no region, no AWS credential anywhere in this notebook."

**Then point at the token count:**

> "That number is now a line in someone's chargeback report. Same call, same result — the difference is that the organisation can see it."

### The model swap

Change one string — `model="bedrock-gpt-oss-20b"` → `model="mistral-large"` — and re-run the same cell.

> "Different vendor's model. Same code, same key, same URL. No new contract, no new credential, no desktop rollout — adding that model was two Kubernetes resources."

**Then point at the token counts side by side:**

| Model | Tokens for the same prompt |
|---|---|
| `bedrock-gpt-oss-20b` | 214 |
| `mistral-large` | 15 |

> "Fourteen times the cost for the same question, because one of them reasons before answering. Neither is wrong — but until now nobody could see it. That's what per-model metering buys you."

Registering more models: §4.5d.

---

## 6.3 Demo 2 — Governed access (terminal)

Four commands. Run them, don't narrate the syntax.

```bash
# 1. The catalogue — what this analyst may use
curl -sk "${MAAS_GW}/maas-api/v1/models" -H "Authorization: Bearer $(oc whoami -t)" \
  | jq -r '.data[] | "\(.id)  ready=\(.ready)  subs=\([.subscriptions[].name]|join(","))"'
```

> "Two models, each bound to a subscription. Subscriptions are where quota and cost centre live."

```bash
# 2. A forged key
curl -sk -o /dev/null -w "forged key:  %{http_code}\n" \
  "${MAAS_GW}/v1/chat/completions" -H "Authorization: Bearer sk-oai-NOTREAL" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"
# 403

# 3. No credential at all
curl -sk -o /dev/null -w "no auth:     %{http_code}\n" \
  "${MAAS_GW}/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50}"
# 401
```

> "Only credentials this organisation issued will work. Nothing here is anonymous."

```bash
# 4. A model outside the subscription
curl -sk -D- -o /dev/null "${MAAS_GW}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"anthropic.claude-sonnet-5","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' \
  | grep -i 'x-ext-auth-reason'
# x-ext-auth-reason: model_not_in_subscription
```

> "This is the part people don't expect. A valid key isn't a licence to use any model — entitlement is per model, per subscription. Whoever owns that budget decides."

### Revocation — the strongest beat

**Console:** **Gen AI studio → API keys**. Show the list, revoke the demo key, then re-run the notebook cell. It fails.

> "That analyst is offboarded. No AWS credential rotated, nobody else disrupted, no ticket to a cloud team. Compare that with today, where revoking one analyst means rotating a key that everyone shares."

Mint a new one and carry on.

### Metering

**Console:** **Settings → MaaS governance** — show the subscriptions, their models, and the token limits.

> "Every call is attributed to a user, a group, and a cost centre. That's the input to chargeback — and to noticing a runaway process before the invoice does."

> **Note:** responses carry no `X-RateLimit-*` headers in 3.5 GA (Appendix G §5), so show the subscription definition rather than promising live quota headers. A live 429 was not verified — do not script it.

---

## 6.4 Demo 3 — Guardrails

**Not yet built.** Part 5 covers the design; it was not implemented on the reference cluster. Describe it, don't demo it:

> "Everything so far is access control — who may call, how much. The next layer is content control: PII stripped before anything leaves the cluster, prompt-injection blocked, responses moderated. That runs in front of this same gateway, with detectors on CPU — no GPU required. For a query going from here to a US-region endpoint, that's the difference between hoping and knowing."

If you have implemented Part 5, run §5.4 and §5.5's tests instead and finish with the bypass attempt returning 403.

---

## 6.5 Closing — the summary slide

| Today | With RHOAI |
|---|---|
| Long-lived AWS key on desktops | Credential lives in the cluster, never leaves |
| Revoke = rotate for everyone | Revoke one analyst in a click |
| No attribution | Per-user, per-group, per-cost-centre metering |
| No ceiling | Quota enforced before the invoice |
| Model change = desktop rollout | Model change = a Kubernetes resource |
| Contents unexamined | Guardrails layer available |
| Analyst effort to migrate | **Two lines: base URL and key** |

---

## 6.6 Be upfront about these

Say them before you're asked. It costs nothing and buys credibility.

| Point | How to put it |
|---|---|
| **External model routing is Tech Preview** | "The gateway underneath — auth, metering, quota — is GA. Routing to external providers is Tech Preview. I'd phase accordingly and I'd want that in writing." |
| **This build needed two undocumented fixes** | "3.5 shipped days ago. We hit two documentation defects and have them filed. Neither affects the architecture, both are one-line workarounds." |
| **Anthropic via Bedrock is unresolved** | "OpenAI-family models work end to end. Anthropic models on Bedrock's OpenAI-compatible endpoint need a different API path that we haven't pinned down." |
| **The gateway is now on the critical path** | "Plan HA for the gateway and the rate limiter. If it's down, analysts are down — that's a real change from today." |
| **The AWS key still needs rotating** | "It's long-lived with an expiry. Someone owns that. Two keys per IAM user makes zero-downtime rotation possible — write that runbook now." |

---

## 6.7 If something fails live

| Symptom | Say | Do |
|---|---|---|
| 503, ~60s hang | "One gateway replica is stale — that's the HA story arriving early." | Retry; it round-robins onto the good one |
| 500 credentials not found | "Credential store lost the Secret." | `oc label secret bedrock-api-key -n ${MODEL_NS} inference.llm-d.ai/ipp-managed=true --overwrite` |
| 404 | "Routing." | Check the §4.5b HTTPRoute patch |
| 401 on a real key | "Key expired." | Mint a new one |
| Slow first response | "Reasoning model — it's thinking before it answers." | Wait; ~1s typical, occasionally longer |

**If it fails hard:** switch to the architecture and the summary table. The story is governance, and the governance layer is provable without a completion — 403 on a forged key and `model_not_in_subscription` both work without touching AWS.

# PART 7 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| HTTPRoute exists but `Accepted=False` | Namespace missing `maas.opendatahub.io/gateway-access=true` | `oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite` |
| `kuadrant.io/AuthPolicyAffected` absent or False | Route not protected by Authorino — endpoint may be open | Check the Gateway's `opendatahub.io/managed: "false"` annotation (§2.5d) |
| `MaaSModelRef` Pending, `NoPairingFound` | No MaaSAuthPolicy + MaaSSubscription pair references it | Expected before §4.6. After §4.6, check `modelRefs[].name`/`namespace` match exactly |
| `MaaSModelRef` Pending, `RuntimeReady=False` | Provider/Secret/endpoint problem | Fix §4.2–4.3 before touching governance |
| `MaaSModelRef` not Ready | Namespace missing gateway-access label | `oc label namespace ${MODEL_NS} maas.opendatahub.io/gateway-access=true --overwrite` |
| `404` from the gateway | `bedrock-runtime` instead of `bedrock-mantle` | Fix `spec.endpoint` |
| `404`, endpoint correct | Model not on Mantle in that region | Re-check `/v1/models` |
| `500 authType 'apikey' credentials not found` | Secret missing `inference.llm-d.ai/ipp-managed=true` — the documented `bbr-managed` label is inert | §4.2 |
| `404` + Envoy `route_not_found` | HTTPRoute matches `targetModel`, pre-processing sends `modelName` | §4.5b |
| `404` with `x-amzn-requestid` | Reached AWS with a bad path — used the namespaced URL | §4.5c: root path + model in body |
| `503 UC,DC` on ~half of calls | One gateway replica serving stale config | Restart the gateway deployment (§4.7) |
| `400 does not support the '/v1/chat/completions' API` | Wrong `apiFormat` for that model family | §4.5c |
| `invalid_api_key` from AWS | **Truncated ABSK key (131 vs 132 chars)** | `oc get secret bedrock-api-key -n ${MODEL_NS} -o jsonpath='{.data.api-key}' \| base64 -d \| wc -c` → must be 132 |
| `401` from AWS in IPP logs | Secret missing `bbr-managed` label or wrong data key | Label `inference.networking.k8s.io/bbr-managed=true`; key must be `api-key` |
| `403` from the gateway | No matching `MaaSAuthPolicy` for caller's groups | Check `modelRefs` and `subjects` |
| `429` unexpectedly | Subscription limit too low | Raise `tokenRateLimits.limit` |
| `content: null`, `finish_reason: length` | Reasoning model exhausted `max_tokens` — not a failure | Raise to 300+ |
| AITenant `GatewayCheckFailed` | `maas-default-gateway` missing — MaaS never creates it | §2.5(d) |
| `maas-api` not found in `redhat-ods-applications` | Wrong namespace — it lives in `redhat-ai-gateway-infra` | `oc get pods -n redhat-ai-gateway-infra` |
| `/maas-api/health` returns dashboard HTML at 200 | Called `rh-ai.<domain>` instead of `maas.<domain>` | Dashboard's `/` catch-all swallows unknown paths (§2.5e) |
| `oc get modelsasservice` empty | Not an error — MaaS is a sub-component of AIGateway | `oc get aigateway -A` |
| Dashboard patch rejected: "DEPRECATED ... must be removed or left unchanged" | A deprecated flag (e.g. `maasAuthPolicies`) in the patch | Remove it. Rejection is atomic — no field applies (§2.9) |
| Flags set but nav unchanged | Micro-frontend cache | Hard-reload (Cmd/Ctrl-Shift-R) |
| Gateway edits keep reverting | Gateway is owned by `GatewayConfig` | Patch `gatewayconfig/default-gateway`, never the Gateway (§2.5) |
| `LoadBalancerReady: False` | Normal with `ingressMode: OcpRoute` | Ignore; verify the Route instead (§2.5) |
| Empty response from `$MAAS_GW`, no error | Gateway listener hostname != Route hostname (passthrough/SNI) | Make them match (§2.5f) |
| `dig` shows NOERROR with ANSWER: 0 | Stale explicit DNS record shadowing the wildcard | Use a different hostname (§2.5f) |
| 404 on `/maas-api/health` | Base URL constructed, not derived | `export MAAS_GW="https://maas.${CLUSTER_DOMAIN}"` |
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
[ ] §2.5(a) GatewayConfig READY; data-science-gateway Programmed (platform-owned — never edit)
[ ] §2.5(b) CERT_NAME resolved (router-certs-default when defaultCertificate is empty)
[ ] §2.5(c) maas-gateway-options ConfigMap (2Gi) applied
[ ] §2.5(d) maas-default-gateway CREATED — class data-science-gateway-class, label-based allowedRoutes
[ ] §2.5(e) MAAS_GW = https://maas.<cluster-domain>  (NOT rh-ai.<domain>)
[ ] §2.5(f) ON-PREM ONLY: ConfigMap service:ClusterIP + passthrough Route; DNS for maas.<domain>
[ ] §2.5 Listener hostname IS maas.<cluster-domain> (the UI hardcodes it — any other value breaks the console)
[ ] §2.5 Gateway restarted after any listener/Service change, six-call loop clean
[ ] §2.5 redhat-ods-applications labelled maas.opendatahub.io/gateway-access=true
[ ] §2.6 PostgreSQL running; maas-db-config in redhat-ods-applications
[ ] §2.7 DSC applied and Ready; dashboard reachable (both classic Route and $MAAS_GW)
[ ] §2.7 Workbench smoke test passed — notebook runs AND has egress (reused in §6.2)
[ ] §2.8 aigateway + modelsAsAService Managed  (spelling: AsA)
[ ] §2.8 Both fields confirmed present in spec.components.aigateway
[ ] §2.8 AIGateway/AITenant/MaasTenantConfig all READY True
[ ] §2.8 maas-api 1/1 in redhat-ai-gateway-infra; /maas-api/health returns 200
[ ] §2.9 Dashboard flags set: modelAsService, externalModels, guardrails, observabilityDashboard
[ ]      (NOT maasAuthPolicies — deprecated, CEL rejects the whole patch)
[ ] §2.9 Hard-reloaded; nav shows AI hub>Models, Gen AI studio>API keys, Settings>MaaS governance

--- Part 3: AWS ---
[x] ABSK key validated: len=132, prefix=ABSK
[x] /v1/models and /v1/chat/completions return successfully
[ ] IAM tightened (SKIP for throwaway PoC) — must include bedrock-mantle:CallWithBearerToken

--- Part 4: integration ---
[ ] external-models namespace labelled gateway-access=true
[ ] Secret bedrock-api-key: key=api-key, label bbr-managed=true, 132 bytes
[ ] ExternalProvider bedrock-<region> (inference.opendatahub.io) created
[ ] ExternalModel x2 (claude-sonnet, gpt-oss-20b) with apiFormat/path/targetModel
[ ] Second working model registered for the swap demo (mistral-large) — §4.5d
[ ] HTTPRoutes Accepted=True, ResolvedRefs=True, both kuadrant.io/*Affected=True
[ ] Inference path prefix recorded: /<model-ns>/<model-name>
[ ] MaaSModelRef x2 created — Pending until §4.6 is applied (expected, not a fault)
[ ] MaaSModelRef RuntimeReady=True (proves the provider connection works)
[ ] MaaSAuthPolicy + two MaaSSubscriptions (standard + trial) — all PHASE Active
[ ] MaaSModelRef now Ready with ENDPOINT populated
[ ] OpenShift TOKEN available (oc whoami -t non-empty) — needed for the admin API
[ ] Secret labelled inference.llm-d.ai/ipp-managed=true (NOT bbr-managed)
[ ] "Secret added/updated in store" confirmed in payload-processing logs
[ ] HTTPRoute rule 3 header patched to modelName (§4.5b), survives 60s
[ ] Inference via ${MAAS_GW}/v1/chat/completions with model in body → 200
[ ] Six-call stability loop: all 200, ~1s each (no stale gateway replica)

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

# Appendix B — Provider matrix (3.5 schema)

`ExternalProvider.spec.provider` names the API type; `ExternalModel.spec.externalProviderRefs[].apiFormat` and `path` control translation and routing.

| Target | `provider` | `endpoint` | `apiFormat` | `path` | `auth.type` |
|---|---|---|---|---|---|
| **AWS Bedrock (Mantle)** | `aws-bedrock` | `bedrock-mantle.<region>.api.aws` | `openai-chat` | `/v1/chat/completions` | `apikey` (or `sigv4`) |
| OpenAI | `openai` | `api.openai.com` | `openai-chat` | `/v1/chat/completions` | `apikey` |
| Anthropic direct | `anthropic` | `api.anthropic.com` | `messages` | `/v1/messages` | `apikey` |
| Azure OpenAI | `azure` | `<resource>.openai.azure.com` | `openai-chat` | `/openai/deployments/{deployment}/chat/completions` | `apikey` |
| Google Vertex | `vertex` | `<region>-aiplatform.googleapis.com` | `openai-chat` | per Vertex OpenAI path | `oauth2` |

Notes for a multi-provider design:

- **`path` is per-binding and supports `{key}` placeholders** resolved from the merged config map (model config overrides provider config). This is what fixes the 3.4 limitation where the translator hardcoded `/v1/chat/completions` — Google Gemini needs `/v1beta/openai/chat/completions` and simply 404'd. In 3.5 you set `path` and it works.
- **`config`** carries provider-specific k/v — e.g. Vertex `{"project": "...", "location": "..."}` — and can be overridden per model binding.
- **`weight`** across multiple `externalProviderRefs` gives one client-facing model name a traffic split: same model in two regions, or a canary between vendors, with no client change.
- **`auth.type: sigv4`** is in the enum, suggesting native AWS SigV4 signing without a long-lived ABSK key. Not validated in this runbook — worth investigating for production, since removing the long-lived credential is a materially better posture.
- **Anthropic via Bedrock beats Anthropic direct** for most customers: `openai-chat` format avoids the Messages-API parameter dropping, and it keeps the commercial relationship inside their existing AWS agreement.
- **Vertex OAuth2 tokens expire hourly**, so the Secret needs continuous refresh — not a fit for a static-credential gateway without automation.

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
| Egress to AWS | Direct | Proxy / firewall rules for `bedrock-mantle.<region>.api.aws` | Raise the firewall request early — it is usually a ticket with lead time |
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
| **MAAS_GW** | LB: `https://maas.<cluster-domain>` · Route: `oc get route maas-gateway -n openshift-ingress -o jsonpath='{.spec.host}'` | `https://maas-gw.apps.rhoai.<sandbox-id>.opentlc.com` (ClusterIP + passthrough Route) | |
| Dashboard URL (NOT MaaS) | `oc get gatewayconfig default-gateway -o jsonpath='{.status.domain}'` | `rh-ai.apps.rhoai.<sandbox-id>.opentlc.com` | |
| OCP version | `oc get clusterversion version -o jsonpath='{.status.desired.version}'` | 4.22.10 | |
| Platform | `oc get infrastructure cluster -o jsonpath='{.status.platform}'` | AWS | |
| RHOAI CSV | `oc get csv -n redhat-ods-operator` | `rhods-operator.3.5.0` (GA, `stable-3.5`) | |
| RHCL CSV | `oc get csv -n openshift-operators \| grep rhcl` | `rhcl-operator.v1.4.2` | |
| GatewayClass | `oc get gatewayclass` | `data-science-gateway-class` | |
| Gateway | `oc get gateway -A` | `data-science-gateway` / `openshift-ingress` | |
| Ingress mode | `oc get gatewayconfig default-gateway -o jsonpath='{.spec.ingressMode}'` | `OcpRoute` | |
| Ingress cert secret | `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}'` | (default) | |
| Default StorageClass | `oc get storageclass \| grep default` | `gp3-csi` | |
| MaaS Gateway exposure | `oc get svc -n openshift-ingress \| grep maas` | ClusterIP + passthrough Route (switched from ELB — §2.5f) | |
| MaaS listener hostname | `oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}'` | `maas-gw.apps.rhoai.<sandbox-id>.opentlc.com` | |
| MaaS infra namespace | `oc get pods -n redhat-ai-gateway-infra` | `redhat-ai-gateway-infra` (maas-api lives here) | |
| Tenant CRDs | `oc get aitenant,maastenantconfig -A` | `AITenant` (ai-tenants) + `MaasTenantConfig` (models-as-a-service) | |
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
| Dashboard flags set | `oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig}'` | modelAsService, externalModels, guardrails, observabilityDashboard | |

**Environment-specific decisions** (see Appendix E for the reasoning):

| Decision | Reference cluster | Your site |
|---|---|---|
| TLS certificate source | `OpenshiftDefaultIngress` (self-signed chain, `-k` required) | |
| Identity provider | `system:authenticated` + OpenShift tokens | |
| Database | in-cluster Postgres, emptyDir, no backup | |
| Kuadrant mTLS | off | |
| IAM policy | `AmazonBedrockLimitedAccess` (not tightened — throwaway account) | |
| Groups for auth policy / subscriptions | `system:authenticated` | |

---

# Appendix G — Undocumented 3.5 GA findings (bug report material)

Discovered by trial and binary inspection on `rhods-operator.3.5.0` GA, MaaS v0.2.0, ai-gateway-operator 1.26.2, RHCL 1.4.2. **None of these appear in the product documentation.** Raise them with the RHOAI team.

## 1. The Secret label is wrong in the docs

| | |
|---|---|
| **Required** | `inference.llm-d.ai/ipp-managed=true` |
| Documented (inert) | `inference.networking.k8s.io/bbr-managed=true` |

`apikey-injection-secret-watcher` only caches Secrets carrying the first. With the documented label, every inference call returns:

```
HTTP 500  inference error: Internal - authType 'apikey' credentials not found
```

Silent: no RBAC error, no warning, no status condition. The `ExternalProvider` still reports `Ready`.

**Evidence:** `grep -a '[a-zA-Z0-9.-]{0,20}/ipp-managed' /bbr` inside the payload-processing pod → `inference.llm-d.ai/ipp-managed`. Applying it produced `apikey-injection/reconciler.go:71 "Secret added/updated in store"` immediately, and the pipeline began completing with `apikey-injection/plugin.go:193 "auth headers injected"`.

**Ruled out during diagnosis:** RBAC (ClusterRole `payload-processing-reader` grants full access to `inference.opendatahub.io` and Secrets; verified with the SA token from inside the pod); the `api-key` vs `apiKey` data-key name; placing the Secret in `openshift-ingress` or `models-as-a-service`; model-level `auth` overrides; IPP restarts.

## 2. The generated HTTPRoute cannot match any request

The controller sets the catch-all rule's `X-Gateway-Model-Name` header match to **`targetModel`**:

```yaml
- name: X-Gateway-Model-Name
  value: openai.gpt-oss-20b          # targetModel
```

The pre-processing IPP sets that header from the request body's `model` field, which is **`modelName`**:

```
bodyfieldtoheader "parsed field from body" field=model value="bedrock-gpt-oss-20b"
```

They can never match → `404 route_not_found` at Envoy for every request. Manual patch (§4.5b) resolves it and survived reconciliation on the reference cluster.

Note this bug is **masked** by bug 1: while credential injection aborts, IPP never rewrites the path, so Envoy's original path match holds and requests reach AWS. Fixing the label exposes the routing bug — which is why the symptom changed from 500 to 404 mid-diagnosis.

## 3. `ExternalProvider` reports Ready without validating the credential

`phase: Ready`, `"All resources created successfully"` — while the referenced Secret is invisible to the component that needs it. A condition reflecting whether the credential was actually loaded would have saved hours.

## 4. Anthropic models on Bedrock Mantle: format unresolved

`anthropic.claude-sonnet-5` with `apiFormat: openai-chat` returns:

```json
{"error":{"code":"validation_error",
 "message":"The model 'anthropic.claude-sonnet-5' does not support the '/v1/chat/completions' API"}}
```

`apiFormat: messages` + `path: /v1/messages` returns 404 from AWS. Correct Mantle path for Anthropic-native format not determined. OpenAI-family models work.

## 5. No rate-limit headers on responses

HTTPRoute status shows `kuadrant.io/TokenRateLimitPolicyAffected: True` and `MaaSSubscription` is Active, but responses carry no `X-RateLimit-*` headers. Quota demos need the observability dashboard instead of response headers. Enforcement itself is untested at the limit.

## 6. Two gateway replicas, one can hold stale config

After changing the gateway Service type or listener hostname, one replica may serve stale upstream config: ~50% of calls return `503 UC,DC` after ~60s while the rest succeed in <1s. Distinguishable by pod IP in the Envoy access log. `oc rollout restart` fixes it. Worth an automatic reconcile.

## 7. The MaaS hostname is NOT configurable in practice

`AITenant.spec.gateway.name` lets you name the Gateway, and the Gateway listener hostname is yours to set — but **the MaaS UI hardcodes `maas.<cluster-domain>`**. It derives the API URL from the naming convention, not from the listener or from `MaaSModelRef.status.endpoint`.

Set any other hostname and the API works perfectly via curl while the console breaks:

```
Error loading API keys
unknown error when invoking maas-api (unmarshall): invalid character '<' looking for beginning of value
```

`maas-ui` logs show it plainly:

```
level=ERROR msg="unknown error when invoking maas-api (unmarshall)" statusCode=503
  endpoint=https://maas.apps.<domain>/maas-api/v1/subscriptions
```

The `<` is the RHOAI dashboard's own HTML — the request fell through to a catch-all instead of reaching maas-api.

**Consequence: the MaaS gateway listener hostname must be `maas.<cluster-domain>`.** Plan DNS around that at a customer site; it is not negotiable through configuration. Symptoms of getting it wrong are an entirely working API and a dead console — including empty **AI hub → Models** and a broken **Gen AI studio → API keys**.

```bash
oc logs -n redhat-ods-applications deployment/maas-ui --tail=30 | grep -i endpoint
```

## 8. Any gateway listener or Service change needs a manual restart

Observed twice. After changing `spec.listeners[0].hostname`, or the Service type via the infrastructure ConfigMap (§2.5f), **one of the two gateway replicas keeps stale upstream config**. Roughly half of calls then return `503 UC,DC downstream_remote_disconnect` after a full ~60s timeout while the rest succeed in under a second.

```bash
oc rollout restart deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress
oc rollout status deployment/maas-default-gateway-data-science-gateway-class -n openshift-ingress --timeout=300s
```

Make this a standing step after any gateway change, and always follow with the six-call loop. The gateway should reconcile this itself.

## Diagnostic techniques worth reusing

- **`grep -a` on the binary.** `strings` isn't in the image, but `grep -a` works and revealed the label. When docs and behaviour disagree, the binary is the source of truth.
- **`x-amzn-requestid` distinguishes AWS from Envoy.** A 404 carrying it reached AWS; without it, check the Envoy log for `route_not_found`.
- **Envoy access logs name the pod.** The second-to-last IP column identifies which gateway replica served a request — how the stale-replica issue was found.
- **The SA token from inside the pod tests real RBAC.** `curl` against `kubernetes.default.svc` with `/var/run/secrets/kubernetes.io/serviceaccount/token` proves what the component can actually see, beyond `oc auth can-i`.
- **Check the plugin chain in the IPP log.** `maas-headers-guard` → `model-provider-resolver` → `api-translation` → `apikey-injection` — whichever stage logs last is where it failed.

## Verified working configuration

```
Client → ${MAAS_GW}/v1/chat/completions  {"model": "bedrock-gpt-oss-20b", ...}
  ExternalProvider  provider=aws-bedrock  endpoint=bedrock-mantle.us-east-1.api.aws
                    auth.type=apikey  secretRef=bedrock-api-key
  Secret            data key "api-key"  label inference.llm-d.ai/ipp-managed=true
  ExternalModel     modelName=bedrock-gpt-oss-20b  targetModel=openai.gpt-oss-20b
                    apiFormat=openai-chat  path=/v1/chat/completions
  HTTPRoute         rule[3] X-Gateway-Model-Name PATCHED to modelName
  → HTTP 200, ~1s, usage.total_tokens reported
```