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
