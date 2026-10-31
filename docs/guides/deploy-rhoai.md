# Batch Gateway on Red Hat OpenShift AI (RHOAI)

This guide demonstrates how to deploy batch-gateway on OpenShift with RHOAI (Red Hat OpenShift AI), using Red Hat Connectivity Link (RHCL/Kuadrant) for authentication, authorization, and rate limiting.

> **Note**: The batch gateway does not depend on RHCL. This guide uses RHCL for gateway-level auth and rate limiting, but any policy engine that works with Gateway API can be used instead.

## 1. Architecture Overview

### 1.1 Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `openshift-ingress` | Gateway data plane (Istio/Envoy proxy), managed by Ingress Operator |
| `cert-manager-operator` | cert-manager operator subscription |
| `cert-manager` | cert-manager controller, webhook, cainjector |
| `openshift-lws-operator` | LeaderWorkerSet operator (required by LLMInferenceService) |
| `kuadrant-system` | Kuadrant operator, Authorino, Limitador |
| `redhat-ods-operator` | RHOAI operator |
| `redhat-ods-applications` | RHOAI controllers (KServe, model controller) |
| `batch-api` | batch-gateway (apiserver + processor), PostgreSQL, MinIO |
| `llm` | LLMInferenceService, model servers, InferencePool, EPP, InferenceObjective CRDs |

### 1.2 Data Flow

![RHOAI Deployment Architecture](diagrams/deploy-rhoai-arch.png)


**Batch inference flow**:
1. Client sends a batch request (e.g. `POST /v1/batches`) to the OpenShift Gateway (`openshift-ai-inference`) with a Kubernetes token
2. Gateway matches `/v1/batches`, `/v1/files` → **batch-route** (HTTPRoute)
    - **AuthPolicy** on the batch-route performs authentication only (kubernetesTokenReview, no authorization check) — unauthenticated requests are rejected with 401
    - **RateLimitPolicy** on the batch-route enforces per-user request rate limiting (e.g. 20 req/min), keyed by Kubernetes username (user or ServiceAccount) from TokenReview — excess requests are rejected with 429
    - Authenticated request is forwarded to **batch-gateway apiserver**, which stores the batch job
3. **Processor** dequeues the batch job and enqueues each inference request on the async dispatch queue (PostgreSQL); the **async-processor** sends them through a separate **Internal Gateway** (`batch-internal-gateway`) — a ClusterIP-only Gateway that is not externally accessible — with the user's original token
4. The Internal Gateway matches `/{ns}/{isvc}/v1/*` → **batch-llm-route** (HTTPRoute)
    - **AuthPolicy** on the batch-llm-route performs authentication and authorization (SubjectAccessReview — checks if the original user can `get llminferenceservices/<name>`) — if the user lacks permission, the request is rejected with 403
    - **No TokenRateLimitPolicy** — batch inference requests are exempt from per-user token rate limits
5. Request is routed to **InferencePool** → **EPP** (endpoint picker) → **vLLM** model server. EPP uses **flow control** to prioritize interactive requests over batch requests (see [1.6 Flow Control](#16-flow-control)). The response is returned to the Processor, which adds the response to the batch job's output file

### 1.3 Authentication

Both the LLM route and the batch route use **kubernetesTokenReview** for authentication. Clients provide a valid Kubernetes token via the `Authorization: Bearer <token>` header. The token must include the audience `https://kubernetes.default.svc`. Tokens are typically created from a ServiceAccount using `oc create token`.

- **LLM route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**
- **Batch route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**

### 1.4 Authorization Model

Model access is controlled through Kubernetes RBAC. Users need `get` permission on the specific `LLMInferenceService` resource to access a model. This is granted by creating a Role and RoleBinding in the model's namespace (see [Enabling authentication and authorization for LLM inference service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/enabling-authentication-and-authorization-for-llm-inference-service_distributed-inference) for details).

- **LLM route**: SubjectAccessReview checks if user can `get llminferenceservices/<name>` — unauthorized requests are rejected with **403**
- **Batch route**: No authorization check — authorization is enforced by the batch-llm-route on the Internal Gateway when the async-processor forwards inference requests with the user's original token

### 1.5 Security boundary: batch-route vs batch-llm-route

For security and operations readers: **admission on the batch API is not the same as authorization for inference.**

- **batch-route** proves the caller has a valid Kubernetes token and applies batch-side **RateLimitPolicy**. Invalid or missing credentials are rejected with **401**; excess batch API traffic is rejected with **429**. It does **not** evaluate whether the caller may use a specific `LLMInferenceService`.
- **batch-llm-route** (on the Internal Gateway) runs **authentication and authorization** (SubjectAccessReview on `llminferenceservices` as above) on each inference request the async-processor sends. The Internal Gateway is ClusterIP-only — it has no external Route or Ingress, ensuring batch inference traffic stays cluster-internal. **No TokenRateLimitPolicy** is applied, so batch requests are exempt from per-user token rate limits. A user can create a batch job and still see **per-request failures** (often surfaced as failed lines or job errors) when the batch-llm-route returns **403** — this is **by design**, not a bypass of model access control.

The `Authorization` header is included in `passThroughHeaders` by default. Without it, the Internal Gateway cannot attribute inference traffic to the original caller and model-level checks cannot run as intended.

### 1.6 Flow Control

Flow control ensures interactive inference requests are always served before batch requests. The EPP (Endpoint Picker Plugin) uses GIE's flow control feature to assign requests to priority bands based on the `x-llm-d-inference-objective` header (`x-gateway-inference-objective` is a deprecated alias):

| Priority Band | Priority | Workload | Behavior Under Saturation |
|---------------|----------|----------|---------------------------|
| Interactive | 100 | Interactive requests | Dispatched first |
| Default | 0 | Requests without an objective header | Dispatched before batch |
| Batch | -1 (sheddable) | Batch requests | Queued: shed on TTL expiry or band capacity (429, or 503 with no endpoints). In flight: revoked with 429 when higher-priority work is blocked (`enableEviction`, recommended on). Retries come from the processor (sync) or llm-d-async (async) |

When the backend is not saturated, both interactive and batch requests are dispatched freely. When saturation reaches 1.0, head-of-line blocking pauses dispatch; interactive requests resume first, and batch requests wait in the batch band until their TTL expires or the band's capacity is exhausted. With `enableEviction` enabled (the recommended setting), a batch request that is already in flight is also revoked so the engine stops working on it while interactive traffic is waiting.

This is configured through three components:

1. **EndpointPickerConfig** in the LLMInferenceService CR (`spec.router.scheduler.config.inline`) enables the `flowControl` feature gate and defines priority bands, fairness policies, and saturation detection thresholds.
2. **InferenceObjective CRDs** map objective names to priority levels. The batch processor sends the `x-llm-d-inference-objective: batch-sheddable` header, which EPP resolves to priority -1. Create them in the `llm-d.ai` group (see [3.7](#37-create-inferenceobjective-crds)).
3. **Batch processor `inferenceObjective` config** sets which `InferenceObjective` name is sent in the header on each inference request.

For full details on flow control configuration, see the [Flow Control Setup Guide](flow-control-setup.md).

## 2. Prerequisites
- OpenShift cluster 4.20 or later (required for Distributed Inference with llm-d).
- OpenShift Service Mesh v2 is not installed in the cluster.
- CLI tools: `oc`, `helm`, `curl`, `jq`.
- An `aigateway` operator bundle whose BatchGateway CRD includes the PostgreSQL async transport — i.e. one pinned to an operator commit at or after [llm-d-batch-gateway-operator#124](https://github.com/opendatahub-io/llm-d-batch-gateway-operator/pull/124). [3.10](#310-install-batch-gateway) verifies this on the cluster; a bundle without it needs the Redis/Valkey transport instead.


## 3. Installation Steps


### 3.1 Install cert-manager

Install the OpenShift cert-manager operator (required by LeaderWorkerSet and batch-gateway TLS). See the [cert-manager Operator for Red Hat OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift).

<details>
<summary>Install cert-manager operator</summary>

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for cert-manager webhook to be ready (this implies the operator CSV succeeded)
until oc get deployment cert-manager-webhook -n cert-manager &>/dev/null; do sleep 10; done
oc rollout status deployment/cert-manager-webhook -n cert-manager --timeout=300s
```

</details>

<details>
<summary>Create a self-signed ClusterIssuer</summary>

```bash
# Wait for the cert-manager webhook TLS to be fully bootstrapped (~15s after rollout)
sleep 15

# Create a self-signed ClusterIssuer (used later by batch-gateway for TLS)
oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

</details>

### 3.2 Install LeaderWorkerSet operator

LLMInferenceService requires the LeaderWorkerSet (LWS) CRD. Install the LWS operator. See the [Leader Worker Set Operator documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/ai_workloads/leader-worker-set-operator).

<details>
<summary>Install LWS operator</summary>

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-lws-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: leader-worker-set
  namespace: openshift-lws-operator
spec:
  targetNamespaces:
  - openshift-lws-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: leader-worker-set
  namespace: openshift-lws-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: leader-worker-set
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator deployment to be ready
until oc get deployment openshift-lws-operator -n openshift-lws-operator &>/dev/null; do sleep 10; done
oc rollout status deployment/openshift-lws-operator -n openshift-lws-operator --timeout=300s

# Create the LeaderWorkerSetOperator CR
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
  namespace: openshift-lws-operator
spec:
  managementState: Managed
EOF

# Wait for the LWS CRD to be available (may take ~30s for the controller to deploy)
until oc get crd leaderworkersets.leaderworkerset.x-k8s.io &>/dev/null; do sleep 5; done
oc wait crd/leaderworkersets.leaderworkerset.x-k8s.io --for=condition=Established --timeout=120s
```

</details>

### 3.3 Create OpenShift GatewayClass and Gateway

Create a GatewayClass and a Gateway named `openshift-ai-inference` in the `openshift-ingress` namespace as described in [Gateway API with OpenShift Container Platform Networking](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/ingress_and_load_balancing/configuring-ingress-cluster-traffic#ingress-gateway-api).

<details>
<summary>Create GatewayClass</summary>

Create the GatewayClass — this triggers the Ingress Operator to install a lightweight Service Mesh (Istio) automatically.
```bash
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

# Wait for the Istiod deployment to appear and become ready (~20s)
until oc get deployment istiod-openshift-gateway -n openshift-ingress &>/dev/null; do sleep 5; done
oc rollout status deployment/istiod-openshift-gateway -n openshift-ingress --timeout=120s
```
</details>


<details>
<summary>Create the Gateway with a hostname matching your cluster domain</summary>

```bash
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
HOSTNAME="llm-inference.${DOMAIN}"

oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-default
  listeners:
  - name: http
    hostname: "${HOSTNAME}"
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            llm-d.ai/gateway-route: "true"
  - name: https
    hostname: "${HOSTNAME}"
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: router-certs-default
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            llm-d.ai/gateway-route: "true"
EOF

# Wait for the Envoy proxy deployment to become ready
until oc get deployment openshift-ai-inference-openshift-default -n openshift-ingress &>/dev/null; do sleep 5; done
oc rollout status deployment/openshift-ai-inference-openshift-default -n openshift-ingress --timeout=120s
```

> **Note**: The Gateway uses the OpenShift default router certificate (`router-certs-default`). The hostname must match the cluster's wildcard DNS for external access.

> **Security**: The Gateway uses `allowedRoutes.namespaces.from: Selector` to restrict HTTPRoute attachment. Only namespaces labeled with `llm-d.ai/gateway-route: "true"` can attach HTTPRoutes. This must be applied to the batch and LLM namespaces before creating their HTTPRoutes.

</details>

### 3.4 Install RHCL

Follow [Red Hat Connectivity Link docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link) to install RHCL

Set the variable used throughout this section:
```bash
KUADRANT_NS=kuadrant-system
```

<details>
<summary>Install RHCL operator</summary>

```bash
oc create namespace "${KUADRANT_NS}" 2>/dev/null || true

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: ${KUADRANT_NS}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec:
  upgradeStrategy: Default
EOF
```

</details>

<details>
<summary>Create Kuadrant CR</summary>

Wait for the operator to be ready, then create the Kuadrant CR:

```bash
# Wait for RHCL operator to be ready
until oc get csv -n "${KUADRANT_NS}" 2>/dev/null | grep rhcl-operator | grep -q Succeeded; do sleep 10; done

oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOF

# Wait for Kuadrant instance to be ready
oc wait kuadrant/kuadrant --for="condition=Ready=true" \
    -n "${KUADRANT_NS}" --timeout=300s
```

</details>

<details>
<summary>Configure Authorino TLS</summary>

Configure Authorino with OpenShift serving certificates for TLS:

```bash
oc annotate svc/authorino-authorino-authorization \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
    -n "${KUADRANT_NS}" --overwrite

oc apply -f - <<EOF
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: ${KUADRANT_NS}
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

oc wait --for=condition=ready pod -l authorino-resource=authorino \
    -n "${KUADRANT_NS}" --timeout=150s
```

</details>

### 3.5 Install RHOAI

Follow [RHOAI Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/latest/html/installing_and_uninstalling_openshift_ai_self-managed/index) to install RHOAI

<details>
<summary>Install RHOAI operator</summary>

```bash
oc create namespace redhat-ods-operator 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

</details>

<details>
<summary>Create DataScienceCluster instance</summary>

Wait for the RHOAI operator CSV to succeed, then create DataScienceCluster:

```bash
# Wait for the RHOAI operator CSV and DataScienceCluster CRD to be ready
until oc get csv -n redhat-ods-operator 2>/dev/null | grep -q Succeeded; do sleep 10; done
until oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; do sleep 5; done

# Wait for the RHOAI operator webhook to be ready
until oc get deployment rhods-operator -n redhat-ods-operator &>/dev/null; do sleep 10; done
oc rollout status deployment/rhods-operator -n redhat-ods-operator --timeout=120s
```

```bash
oc apply -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headed
      modelsAsService:
        managementState: Removed
    aigateway:
      managementState: Managed
      batchGateway:
        managementState: Managed
    dashboard:
      managementState: Removed
EOF
```
</details>

<details>
<summary>Wait for the DataScienceCluster to be ready</summary>

```bash
oc get datasciencecluster default-dsc

oc wait datasciencecluster/default-dsc --for=jsonpath='{.status.phase}'=Ready --timeout=600s
```

> **Note**: If Connectivity Link was installed after RHOAI, restart the RHOAI controllers to pick up Authorino:
> ```bash
> oc delete pod -n redhat-ods-applications -l app=odh-model-controller
> oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager
> ```

</details>

### 3.6 Deploy model with llm-d

Follow [deploy model doc](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/index) to deploy model with LLM-D

For more examples: [kserve samples repo](https://github.com/red-hat-data-services/kserve/tree/rhoai-3.5/docs/samples/llmisvc) (switch to the `rhoai-<version>` branch matching your RHOAI version for version-specific samples)

The following example deploys a simulated model with `LLMInferenceService`.

<details>
<summary>Deploy a simulated model with LLMInferenceService</summary>

```bash
LLM_NS=llm
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

oc create namespace "${LLM_NS}" 2>/dev/null || true
# Label namespace for gateway access (required by Gateway namespace selector)
oc label namespace "${LLM_NS}" llm-d.ai/gateway-route=true --overwrite

oc apply -f - <<EOF
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: ${ISVC_NAME}
  namespace: ${LLM_NS}
  annotations:
    # Enables Gateway-level AuthPolicy (SubjectAccessReview on LLMInferenceService)
    security.opendatahub.io/enable-auth: "true"
spec:
  model:
    uri: hf://sshleifer/tiny-gpt2
    name: ${MODEL_NAME}
  replicas: 2
  router:
    route: {}
    scheduler:
      config:
        inline:
          apiVersion: llm-d.ai/v1alpha1
          kind: EndpointPickerConfig
          featureGates:
            - "flowControl"
          plugins:
            - type: round-robin-fairness-policy
            - type: global-strict-fairness-policy
            - type: slo-deadline-ordering-policy
            - type: utilization-detector
              parameters:
                queueDepthThreshold: 5
                kvCacheUtilThreshold: 0.8
          schedulingProfiles: []
          flowControl:
            maxBytes: 4294967296
            defaultRequestTTL: 30s
            enableEviction: true
            saturationDetector:
              pluginRef: utilization-detector
            priorityBands:
              - priority: 100
                maxBytes: 1073741824
                fairnessPolicyRef: round-robin-fairness-policy
                orderingPolicyRef: fcfs-ordering-policy
              - priority: -1
                maxBytes: 3221225472
                defaultRequestTTL: 120s
                fairnessPolicyRef: global-strict-fairness-policy
                orderingPolicyRef: slo-deadline-ordering-policy
            defaultPriorityBand:
              maxBytes: 536870912
              fairnessPolicyRef: global-strict-fairness-policy
              orderingPolicyRef: fcfs-ordering-policy
  template:
    containers:
      - name: main
        image: ghcr.io/llm-d/llm-d-inference-sim:v0.7.1
        imagePullPolicy: Always
        command: ["/app/llm-d-inference-sim"]
        args:
        - --port
        - "8000"
        - --model
        - ${MODEL_NAME}
        - --mode
        - random
        - --ssl-certfile
        - /var/run/kserve/tls/tls.crt
        - --ssl-keyfile
        - /var/run/kserve/tls/tls.key
        ports:
          - name: https
            containerPort: 8000
            protocol: TCP
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
```

</details>

<details>
<summary>Wait for the LLMInferenceService to be ready</summary>

Wait for the LLMInferenceService to be ready:
```bash
oc wait llminferenceservice/${ISVC_NAME} -n ${LLM_NS} \
    --for=condition=Ready --timeout=600s
```
> **Key annotation**: `security.opendatahub.io/enable-auth: "true"` enables the Gateway-level AuthPolicy that uses SubjectAccessReview to check if the user has RBAC permission to `get` the specific `LLMInferenceService` resource.

> **Flow control config**: The `scheduler.config.inline` EndpointPickerConfig enables the `flowControl` feature gate with two priority bands: interactive (priority 100, round-robin fairness, FCFS ordering) and batch (priority -1, sheddable, SLO-deadline ordering, longer queue TTL). `enableEviction: true` lets the EPP revoke in-flight batch requests when interactive traffic is blocked, and the `saturationDetector` (nested under `flowControl` since llm-d-router v0.11.0) monitors backend queue depth and KV-cache utilization to trigger head-of-line blocking when the system is saturated. An inline config replaces the platform's default EPPConfig preset rather than merging with it, so it must list every plugin it references. See [1.6 Flow Control](#16-flow-control) and the [Flow Control Setup Guide](flow-control-setup.md) for details.
</details>

<details>
<summary>Check LLM-D deployment</summary>

> **Note**: This `LLMInferenceService` CRD automatically creates the model server Deployment, InferencePool, EPP, and HTTPRoute.

```
oc get all -n llm
NAME                                                             READY   STATUS    RESTARTS   AGE
pod/facebook-opt-125m-kserve-85958d5dc-gp6kt                     1/1     Running   0          11m
pod/facebook-opt-125m-kserve-85958d5dc-q529j                     1/1     Running   0          11m
pod/facebook-opt-125m-kserve-router-scheduler-5d76d9f8b4-mvqs4   1/1     Running   0          11m

NAME                                                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                               AGE
service/facebook-opt-125m-epp-service                  ClusterIP   172.30.85.208   <none>        9002/TCP,9003/TCP,9090/TCP,5557/TCP   11m
service/facebook-opt-125m-inference-pool-ip-cf7269e1   ClusterIP   None            <none>        54321/TCP                             11m
service/facebook-opt-125m-kserve-workload-svc          ClusterIP   172.30.3.51     <none>        8000/TCP                              11m

NAME                                                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/facebook-opt-125m-kserve                    2/2     2            2           11m
deployment.apps/facebook-opt-125m-kserve-router-scheduler   1/1     1            1           11m

NAME                                                                   DESIRED   CURRENT   READY   AGE
replicaset.apps/facebook-opt-125m-kserve-85958d5dc                     2         2         2       11m
replicaset.apps/facebook-opt-125m-kserve-router-scheduler-5d76d9f8b4   1         1         1       11m

oc get httproute -n llm
NAME                             HOSTNAMES   AGE
facebook-opt-125m-kserve-route               13m
```
</details>

### 3.7 Create InferenceObjective CRDs

Create `InferenceObjective` resources that map the `x-llm-d-inference-objective` header value to a priority band in EPP's flow control. The batch processor sends the `batch-sheddable` objective on each inference request.

<details>
<summary>Create InferenceObjective CRDs</summary>

```bash
# Discover the InferencePool created by the LLMInferenceService
POOL_NAME=$(oc get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)

oc apply -f - <<EOF
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata:
  name: interactive-default
  namespace: ${LLM_NS}
spec:
  priority: 100
  poolRef:
    group: inference.networking.k8s.io
    name: ${POOL_NAME}
---
apiVersion: llm-d.ai/v1alpha2
kind: InferenceObjective
metadata:
  name: batch-sheddable
  namespace: ${LLM_NS}
spec:
  priority: -1
  poolRef:
    group: inference.networking.k8s.io
    name: ${POOL_NAME}
EOF
```

> **Use the `llm-d.ai` group.** RHOAI installs both the `llm-d.ai` and the legacy `inference.networking.x-k8s.io` InferenceObjective CRDs. When both are present the EPP prefers `llm-d.ai` and **ignores** resources in the legacy group (it logs a warning), so objectives created as `inference.networking.x-k8s.io/v1alpha2` are silently unused. The EPP ServiceAccount already has `get`/`list`/`watch` on `inferenceobjectives` in both groups.

> **`interactive-default` (priority 100)**: Interactive clients can optionally send `x-llm-d-inference-objective: interactive-default` to get the highest priority. Without this header, requests default to priority 0, which still outranks batch.

> **`batch-sheddable` (priority -1)**: Negative priority means sheddable, so batch yields to interactive traffic. With the `flowControl` feature gate enabled, these requests buffer in the batch band and are shed with HTTP 429 when the queue TTL expires or the band's capacity fills; in-flight requests can also be revoked when `enableEviction` is set. llm-d-async retries 429s with backoff in async dispatch mode. See [Flow Control Setup](flow-control-setup.md) for the timeout constraints that govern whether TTL shedding is observable.

</details>

### 3.8 Configure TokenRateLimitPolicy for LLMInferenceService

Configure per-user token rate limiting for inference requests. See [Red Hat Connectivity Link docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link) for details. The following is an example configuration.

> **Note**: The TokenRateLimitPolicy targets the Gateway (not HTTPRoute) because LLMInferenceService dynamically generates the inference HTTPRoute name.

<details>
<summary>Apply per-user token rate limiting on inference requests</summary>

```bash
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: inference-token-limit
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: openshift-ai-inference
  limits:
    per-user:
      rates:
      - limit: 500
        window: 1m
      when:
      - predicate: request.path.endsWith("/v1/chat/completions")
      counters:
      - expression: auth.identity.user.username
EOF

# wait for policy to be enforced
oc wait tokenratelimitpolicy/inference-token-limit \
    --for="condition=Enforced=true" \
    -n openshift-ingress --timeout=180s
```
</details>

### 3.9 Batch Gateway Dependencies

The async-processor routes inference requests through a separate, ClusterIP-only Internal Gateway to bypass the TokenRateLimitPolicy on the external Gateway while still enforcing model-level authorization (AuthPolicy).

Set the variables used throughout this section (re-set them if starting a new shell):
```bash
LLM_NS=llm
BATCH_NS=batch-api
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
```

<details>
<summary>Create Internal Gateway (ClusterIP)</summary>

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: batch-internal-gateway
  namespace: openshift-ingress
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: openshift-default
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            llm-d.ai/gateway-route: "true"
EOF

# Wait for the Internal Gateway deployment to be ready
until oc get deployment batch-internal-gateway-openshift-default -n openshift-ingress &>/dev/null; do sleep 5; done
oc rollout status deployment/batch-internal-gateway-openshift-default -n openshift-ingress --timeout=300s

# Wait for Gateway to be programmed
oc wait --for=condition=Programmed --timeout=300s -n openshift-ingress gateway/batch-internal-gateway
```

> **Key annotation**: `networking.istio.io/service-type: ClusterIP` forces the Gateway's Service to be ClusterIP instead of LoadBalancer, ensuring it is not externally accessible.

> **HTTP only**: The Internal Gateway uses HTTP (port 80) with no TLS listener. Since traffic is cluster-internal (processor → Internal Gateway → InferencePool), TLS termination is not needed.

> **Security**: The Internal Gateway uses the same `allowedRoutes` namespace selector (`llm-d.ai/gateway-route: "true"`) as the external Gateway.

</details>

<details>
<summary>Create batch-llm-route (HTTPRoute on Internal Gateway)</summary>

```bash
# Discover the InferencePool owned by the LLMInferenceService
POOL_NAME=$(oc get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)

oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-llm-route
  namespace: ${LLM_NS}
spec:
  parentRefs:
  - name: batch-internal-gateway
    namespace: openshift-ingress
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NS}/${ISVC_NAME}/v1/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NS}/${ISVC_NAME}/v1/chat/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/chat/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
EOF
```

> **Same path pattern**: The batch-llm-route uses the same `/{namespace}/{isvc-name}/v1/*` path pattern as the auto-generated LLM route on the external Gateway. This allows the async-processor to use the same URL format.

> **URL rewrite**: Each rule strips the `/{namespace}/{isvc-name}` prefix before forwarding to the InferencePool, matching the rewrite behavior of the auto-generated LLM route.

> **InferencePool API group**: `InferencePool` was promoted to the `inference.networking.k8s.io` group (v1) by the Gateway API Inference Extension. Routes referencing the pre-promotion `inference.networking.x-k8s.io` group are accepted by the Gateway but never resolve — the route reports `ResolvedRefs=False` ("referencing unsupported backendRef") and inference requests fail — on current Gateway implementations. Use `inference.networking.k8s.io` unless your cluster predates the promotion.

</details>

<details>
<summary>Apply AuthPolicy for batch-llm-route</summary>

```bash
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: batch-llm-route-auth
  namespace: ${LLM_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-llm-route
  rules:
    authentication:
      kubernetes-user:
        kubernetesTokenReview:
          audiences:
          - https://kubernetes.default.svc
    authorization:
      model-access:
        kubernetesSubjectAccessReview:
          user:
            expression: auth.identity.user.username
          authorizationGroups:
            expression: auth.identity.user.groups
          resourceAttributes:
            group:
              value: serving.kserve.io
            resource:
              value: llminferenceservices
            namespace:
              expression: request.path.split("/")[1]
            name:
              expression: request.path.split("/")[2]
            verb:
              value: get
EOF
```

> **Same authorization as external LLM route**: The AuthPolicy checks `get llminferenceservices/<name>` via SubjectAccessReview, identical to the auto-generated AuthPolicy on the external Gateway's LLM route.

> **No TokenRateLimitPolicy**: Unlike the external Gateway, no TokenRateLimitPolicy is applied to the Internal Gateway or its routes. Batch inference requests are exempt from per-user token rate limits.

</details>

Deploy batch-gateway dependencies (PostgreSQL, MinIO) and create the application secret:

<details>
<summary>Create namespace and install dependencies</summary>

```bash
oc create namespace "${BATCH_NS}" 2>/dev/null || true
oc label namespace "${BATCH_NS}" llm-d.ai/gateway-route=true --overwrite

# Install PostgreSQL (batch job state and the async SQL dispatch queues)
PG_PASSWORD="<your-password>"   # set once, referenced below
helm upgrade --install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
    --namespace ${BATCH_NS} --create-namespace \
    --set "auth.postgresPassword=${PG_PASSWORD}" \
    --set auth.database=batch
oc rollout status statefulset/postgresql -n ${BATCH_NS} --timeout=120s

# Install MinIO (S3-compatible object storage for batch files)
MINIO_USER=<your-minio-user>
MINIO_PASSWORD=<your-minio-password>
MINIO_BUCKET=batch-gateway

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${BATCH_NS}
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: "${MINIO_USER}"
        - name: MINIO_ROOT_PASSWORD
          value: "${MINIO_PASSWORD}"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${BATCH_NS}
  labels:
    app: minio
spec:
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
  type: ClusterIP
EOF

until oc get deployment minio -n ${BATCH_NS} &>/dev/null; do sleep 5; done
oc rollout status deployment/minio -n ${BATCH_NS} --timeout=180s

# Create application secret
oc create secret generic batch-gateway-secrets \
    --namespace ${BATCH_NS} \
    --from-literal=postgresql-url="postgresql://postgres:${PG_PASSWORD}@postgresql.${BATCH_NS}.svc.cluster.local:5432/batch?sslmode=disable" \
    --from-literal=s3-secret-access-key="${MINIO_PASSWORD}" \
    --dry-run=client -o yaml | oc apply -f -
```

> **Note**: `redis-url` is only required by the `redis-sortedset` async transport (see [3.10](#310-install-batch-gateway)); the SQL transport used there reuses `postgresql-url`, so this guide needs no Redis instance.

</details>

### 3.10 Install Batch Gateway

The batch-gateway is deployed via the `LLMBatchGateway` CR, which is managed by the batch-gateway-operator (deployed automatically when `aigateway.batchGateway.managementState: Managed` is set in the DataScienceCluster).

batch-gateway dispatches every batch inference request asynchronously: the processor writes each request to an async dispatch queue, and the async-processor sends it to the model server through the Internal Gateway. The CR below omits `dispatchMode` on purpose — releases that still accept the field default it to `async`, and releases after [llm-d-batch-gateway-operator#125](https://github.com/opendatahub-io/llm-d-batch-gateway-operator/pull/125) deprecate it and always dispatch asynchronously, with `spec.processor.asyncConfig` required. This guide uses the PostgreSQL (`sql`) queue transport, which reuses the Secret's `postgresql-url` — PostgreSQL is the only stateful dependency.

> **Check the installed CRD first**: the SQL transport needs an operator build whose CRD includes it. Verify before you deploy, and on the RHOAI path confirm the promoted `aigateway` bundle carries it:
>
> ```bash
> $ kubectl explain llmbatchgateway.spec.processor.asyncConfig.sql
> GROUP:      batch.llm-d.ai
> KIND:       LLMBatchGateway
> VERSION:    v1alpha1
>
> FIELD: sql <Object>
> ```
>
> `Error from server (NotFound)` means the installed operator predates SQL support: upgrade the operator, or follow the Redis/Valkey transport alternative at the end of this section — it works on every release.

Dispatching is driven by [llm-d-async](https://github.com/llm-d/llm-d-async): the async-processor uses a dispatch gate to control when requests are sent to the model server. This example uses the `prometheus-budget` gate, which requires Prometheus scraping EPP and vLLM metrics (deployed below). See [llm-d-async dispatch gates](https://github.com/llm-d/llm-d-async#per-queue-dispatch-gates) for other gate types.

> - **`modelGateways.<model>.inferencePoolName`**: The InferencePool whose queue feeds this model. The processor requires one consumer per pool, so each model gateway entry needs its own pool.
> - **`modelGateways.<model>.inferenceObjective`**: The `InferenceObjective` CRD name sent as the `x-llm-d-inference-objective` header (deprecated alias: `x-gateway-inference-objective`). EPP uses this to assign the request to the batch priority band (priority -1, sheddable). It must reference an `InferenceObjective` in the `llm-d.ai` group; see [3.7](#37-create-inferenceobjective-crds).
> - **`asyncConfig`**: Required for async dispatch (CRD-required after operator #125). The operator always deploys an async-processor component and configures the queues, worker pools, Prometheus URL, and dispatch gates from this block. `asyncConfig.sql` selects the PostgreSQL transport; `asyncConfig.redis` (Redis/Valkey sorted sets) is the alternative.
> - **`igwBaseURL`**: The async-processor sends inference requests through the Internal Gateway. Pass-through headers (including Authorization) are forwarded, so AuthPolicy works.
> - **`gate_type: prometheus-budget`**: Computes a dispatch budget from EPP flow control metrics (primary) with vLLM metrics fallback. Requires `prometheusURL` and `gate_params.pool`.
> - **`tls.certManager`**: Enables TLS for the batch API server using cert-manager. In this demo the DestinationRule (see [3.11](#311-configure-httproute-and-policies-for-batch-gateway)) uses `insecureSkipVerify: true` because we use a self-signed certificate; in production, configure a trusted CA.
> - **Images**: The operator pins component images (apiserver, processor, async-processor, gc) from its deployment configuration. You do not set image references in the CR.
> - **File storage**: This example uses S3-compatible storage (MinIO). To use a PVC instead, replace `fileStorage.s3` with:
>   ```yaml
>   fileStorage:
>     fs:
>       basePath: /tmp/batch-gateway
>       claimName: <your-pvc-name>
>   ```
>   The PVC must have `ReadWriteMany` access mode (requires NFS, CephFS, or similar).

<details>
<summary>Deploy Prometheus (required for prometheus-budget gate)</summary>

Deploy a minimal Prometheus instance scraping EPP and vLLM metrics. On RHOAI, the EPP endpoint requires SA token auth and serves metrics over HTTPS using the KServe serving certificate, and vLLM pods also serve metrics over HTTPS.

```bash
oc apply -n "${LLM_NS}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
    scrape_configs:
    - job_name: 'epp'
      scheme: https
      tls_config:
        insecure_skip_verify: true
      metrics_path: /metrics
      authorization:
        credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      static_configs:
      - targets: ['${ISVC_NAME}-epp-service.${LLM_NS}.svc.cluster.local:9090']
        labels:
          namespace: ${LLM_NS}
    - job_name: 'vllm'
      scheme: https
      tls_config:
        insecure_skip_verify: true
      metrics_path: /metrics
      kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ['${LLM_NS}']
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]
        action: keep
        regex: 'llminferenceservice-workload'
      - source_labels: [__meta_kubernetes_pod_ip]
        target_label: __address__
        replacement: '\${1}:8000'
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        regex: '(.+)'
        target_label: inference_pool
        replacement: '\${1}-inference-pool'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
      - name: prometheus
        image: prom/prometheus:v3.5.0
        args:
        - --config.file=/etc/prometheus/prometheus.yml
        - --storage.tsdb.retention.time=1h
        - --storage.tsdb.path=/tmp/prometheus
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get, list, watch]
- nonResourceURLs: [/metrics]
  verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: ${LLM_NS}
roleRef:
  kind: ClusterRole
  name: prometheus
  apiGroup: rbac.authorization.k8s.io
EOF

oc rollout status deployment/prometheus -n ${LLM_NS} --timeout=120s
```

> **RHOAI-specific scrape config**: EPP requires SA token auth (`authorization.credentials_file`). vLLM pods serve metrics over HTTPS with self-signed certs (`insecure_skip_verify: true`). The `inference_pool` label is derived per pod from the `app.kubernetes.io/name` label (`<name>-inference-pool`, the standard pool naming) — vLLM does not emit the label natively, and deriving it per pod keeps it correct when multiple models are deployed in the namespace; a static replacement only works for a single-model deployment. Both jobs also attach the `namespace` label: the `prometheus-budget` gate builds its metric queries from `gate_params.namespace` and filters every source on it, and neither static targets nor pod-discovered targets carry the label automatically — without it, all gate metric sources fail to match and the gate silently dispatches on its fallback value.

</details>

<details>
<summary>Create LLMBatchGateway CR</summary>

```bash
INTERNAL_GW_SVC=$(oc get svc -n openshift-ingress \
    -l "gateway.networking.k8s.io/gateway-name=batch-internal-gateway" \
    -o jsonpath='{.items[0].metadata.name}')
MODEL_URL="http://${INTERNAL_GW_SVC}.openshift-ingress.svc.cluster.local/${LLM_NS}/${ISVC_NAME}"

# Discover the InferencePool name
POOL_NAME=$(oc get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)

oc apply -f - <<EOF
apiVersion: batch.llm-d.ai/v1alpha1
kind: LLMBatchGateway
metadata:
  name: batch-gateway
  namespace: ${BATCH_NS}
spec:
  secretRef:
    name: batch-gateway-secrets
  dbBackend: postgresql
  fileStorage:
    s3:
      bucket: ${MINIO_BUCKET}
      region: us-east-1
      endpoint: http://minio.${BATCH_NS}.svc.cluster.local:9000
      accessKeyId: ${MINIO_USER}
      usePathStyle: true
      autoCreateBucket: true
  apiServer:
    replicas: 1
  processor:
    replicas: 1
    modelGateways:
      ${MODEL_NAME}:
        inferencePoolName: ${POOL_NAME}
        inferenceObjective: batch-sheddable
    asyncConfig:
      replicas: 1
      concurrency: 1
      drainTimeout: 2m
      resultPollTimeout: 30s
      prometheusURL: http://prometheus.${LLM_NS}.svc.cluster.local:9090
      prometheusCacheTTL: "0s"
      sql:
        maxConnections: 8
        pollIntervalMs: 500
        batchSize: 10
        queuesConfig:
        - name: "llm-d-async:requests:${POOL_NAME}"
          requestPathURL: /v1/chat/completions
          igwBaseURL: ${MODEL_URL}
          gateType: prometheus-budget
          gateParams:
            pool: "${POOL_NAME}"
            namespace: "${LLM_NS}"
            max_concurrency: "100"
            baseline: "0.05"
            fallback: "1.0"
          workerPoolID: default-workers
      workerPools:
      - name: default-workers
        workers: 4
        gateType: local-max-concurrency
        gateParams:
          limit: "2"
  gc:
    interval: 30m
  tls:
    enabled: true
    certManager:
      issuerName: selfsigned-issuer
      issuerKind: ClusterIssuer
      dnsNames:
      - batch-gateway-apiserver
      - batch-gateway-apiserver.${BATCH_NS}.svc.cluster.local
      - localhost
EOF

oc wait llmbatchgateway/batch-gateway -n ${BATCH_NS} \
    --for=condition=Ready --timeout=300s
```

> - The `asyncConfig` block is operator-managed: the operator deploys an `async-processor` Deployment automatically based on this configuration. You do not deploy the async-processor separately (unlike the Helm-based K8s path).
> - **`modelGateways` keys**: A key must exactly match the `model` field in batch request bodies — the processor rejects requests for unregistered models at ingestion. It must also be a name the model server accepts: the simulated model used above takes any name, but a real vLLM deployment requires the served model ID (for example `meta-llama/Llama-3.1-8B-Instruct`), which can differ from the `LLMInferenceService` name used in gateway URL paths. Requests naming anything else pass routing but fail with a 404 from the model server.
> - **`workerPools`**: Each worker pool has its own gate. The `local-max-concurrency` gate on `default-workers` limits concurrent in-flight requests per worker, while the `prometheus-budget` gate on the queue controls overall dispatch rate based on cluster capacity.
> - **`asyncConfig.sql`**: The PostgreSQL dispatch transport. The processor and the async-processor both use the Secret's `postgresql-url`. `maxConnections` caps the processor's SQL pool per replica (default 8) — budget `processor replicas × maxConnections` plus the async-processor's own pool against PostgreSQL `max_connections`. With SQL, each model gateway entry must resolve to its own result queue (default `llm-d-async:results:<inferencePoolName>`) and use a distinct `inferencePoolName`, because results are read destructively per model. To keep the queues in Redis/Valkey instead of PostgreSQL, see the alternative at the end of this section.

</details>

<details>
<summary>Alternative: Redis/Valkey queue transport</summary>

Instead of PostgreSQL, the queues can live in Redis — selected with `asyncConfig.redis` (`redis-sortedset` transport). Everything above still applies: the same queues, worker pools, gates and Internal Gateway URL, and PostgreSQL is still required for batch job state. The differences are one extra workload and a `redis-url` key in the Secret.

```bash
# Install Redis (or Valkey — wire-protocol compatible)
helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/redis \
    --namespace ${BATCH_NS} --create-namespace \
    --set architecture=standalone \
    --set auth.enabled=false
oc rollout status statefulset/redis-master -n ${BATCH_NS} --timeout=120s

# Alternative: Valkey
# helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/valkey \
#     --namespace ${BATCH_NS} --create-namespace \
#     --set architecture=standalone \
#     --set auth.enabled=false
# oc rollout status statefulset/redis-valkey-primary -n ${BATCH_NS} --timeout=120s
# Note: when using Valkey, use redis://redis-valkey-primary.${BATCH_NS}.svc.cluster.local:6379/0 below

# Add the queue URL to the existing application secret
REDIS_URL="redis://redis-master.${BATCH_NS}.svc.cluster.local:6379/0"
oc patch secret batch-gateway-secrets -n ${BATCH_NS} --type merge \
    -p "{\"data\":{\"redis-url\":\"$(printf %s "${REDIS_URL}" | base64 -w0)\"}}"
```

> **Note**: Redis auth is disabled for demo purposes. For production, enable authentication and use a `rediss://` URL.

Then replace the `sql:` block of the CR with the Redis one (`maxConnections` does not apply):

```yaml
      redis:
        pollIntervalMs: 500
        batchSize: 10
        queuesConfig:
        - name: "llm-d-async:requests:${POOL_NAME}"
          requestPathURL: /v1/chat/completions
          igwBaseURL: ${MODEL_URL}
          gateType: prometheus-budget
          gateParams:
            pool: "${POOL_NAME}"
            namespace: "${LLM_NS}"
            max_concurrency: "100"
            baseline: "0.05"
            fallback: "1.0"
          workerPoolID: default-workers
```

and re-apply the CR with `asyncConfig.redis` in place of `asyncConfig.sql`, keeping the same `modelGateways`, `workerPools`, `tls` and `gc` sections:

```bash
oc apply -f llmbatchgateway.yaml
oc wait llmbatchgateway/batch-gateway -n ${BATCH_NS} \
    --for=condition=Ready --timeout=300s
```

> - **Gates**: most gates are transport-independent, but `redis`, `redis-leased-rate` and `redis-quota` require this transport — on SQL, use `sql-quota` in place of `redis-quota`.
> - **Result queues**: each model still needs its own `inferencePoolName`; the processor appends its replica identity to `llm-d-async:results:<inferencePoolName>`.
> - **Switching transports on an existing deployment**: drain or cancel in-flight batches first — queued requests are not migrated between the two backends.

</details>

### 3.11 Configure HTTPRoute and Policies for Batch Gateway

Set the variable used throughout this section (re-set if starting a new shell):
```bash
BATCH_NS=batch-api
```

Create the batch route, authentication policy, and rate limit:

<details>
<summary>Create HTTPRoute for Batch API Server</summary>

```bash
# Batch HTTPRoute
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-route
  namespace: ${BATCH_NS}
spec:
  parentRefs:
  - name: openshift-ai-inference
    namespace: openshift-ingress
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/batches
    - path:
        type: PathPrefix
        value: /v1/files
    backendRefs:
    - name: batch-gateway-apiserver
      port: 8000
EOF

# DestinationRule for TLS re-encrypt between Gateway and batch apiserver
oc apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: batch-gateway-backend-tls
  namespace: openshift-ingress
spec:
  host: batch-gateway-apiserver.${BATCH_NS}.svc.cluster.local
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 8000
      tls:
        mode: SIMPLE
        insecureSkipVerify: true
EOF
```

</details>


<details>
<summary>Create AuthPolicy for Batch API Server</summary>

```bash
# Batch AuthPolicy (authentication only — model-level authorization
# is enforced by the Internal Gateway's batch-llm-route AuthPolicy)
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: batch-route-auth
  namespace: ${BATCH_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-route
  rules:
    authentication:
      kubernetes-user:
        kubernetesTokenReview:
          audiences:
          - https://kubernetes.default.svc
EOF

```

</details>

<details>
<summary>Create RateLimitPolicy for Batch API Server</summary>

```bash
# Batch RateLimitPolicy (20 requests/min per user)
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: batch-ratelimit
  namespace: ${BATCH_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-route
  limits:
    per-user:
      rates:
      - limit: 20
        window: 1m
      counters:
      - expression: auth.identity.user.username
EOF
```

</details>

## 4. Test

Set the variables used throughout this section (these were defined during installation — re-set them if starting a new shell):
```bash
LLM_NS=llm
BATCH_NS=batch-api
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
```

### 4.1 Setup Test Accounts
```bash
# Get Gateway hostname (OpenShift router uses SNI-based routing, so the
# spec hostname is required — the raw LB address won't work)
GW_HOSTNAME=$(oc get gateway openshift-ai-inference -n openshift-ingress \
    -o jsonpath='{.spec.listeners[0].hostname}')
GW_URL="https://${GW_HOSTNAME}"

# Create authorized SA with RBAC to access the LLMInferenceService
oc create serviceaccount test-authorized-sa -n ${LLM_NS} 2>/dev/null || true
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-authorized-sa-llm-reader
  namespace: ${LLM_NS}
rules:
- apiGroups: ["serving.kserve.io"]
  resources: ["llminferenceservices"]
  resourceNames: ["${ISVC_NAME}"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: test-authorized-sa-llm-reader
  namespace: ${LLM_NS}
subjects:
- kind: ServiceAccount
  name: test-authorized-sa
  namespace: ${LLM_NS}
roleRef:
  kind: Role
  name: test-authorized-sa-llm-reader
  apiGroup: rbac.authorization.k8s.io
EOF

AUTH_TOKEN=$(oc create token test-authorized-sa -n ${LLM_NS} \
    --audience=https://kubernetes.default.svc --duration=10m)

# Create unauthorized SA (no RBAC)
oc create serviceaccount test-unauthorized-sa -n ${LLM_NS} 2>/dev/null || true
UNAUTH_TOKEN=$(oc create token test-unauthorized-sa -n ${LLM_NS} \
    --audience=https://kubernetes.default.svc --duration=10m)
```

### 4.2 LLM Authentication

```bash
# Unauthenticated -> 401
curl -sk -o /dev/null -w "%{http_code}\n" \
    ${GW_URL}/${LLM_NS}/${ISVC_NAME}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"'${MODEL_NAME}'","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'

# Authenticated -> 200
curl -sk -o /dev/null -w "%{http_code}\n" \
    ${GW_URL}/${LLM_NS}/${ISVC_NAME}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -d '{"model":"'${MODEL_NAME}'","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
```

### 4.3 LLM Authorization

```bash
# Unauthorized SA -> 403
curl -sk -o /dev/null -w "%{http_code}\n" \
    ${GW_URL}/${LLM_NS}/${ISVC_NAME}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${UNAUTH_TOKEN}" \
    -d '{"model":"'${MODEL_NAME}'","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'

# Authorized SA -> 200
curl -sk -o /dev/null -w "%{http_code}\n" \
    ${GW_URL}/${LLM_NS}/${ISVC_NAME}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -d '{"model":"'${MODEL_NAME}'","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}'
```

### 4.4 LLM Token Rate Limit

```bash
# Send requests until 429 (token rate limit)
for i in $(seq 1 100); do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        ${GW_URL}/${LLM_NS}/${ISVC_NAME}/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -d '{"model":"'${MODEL_NAME}'","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}')
    if [ "$http_code" = "429" ]; then
        echo "Request $i: 429 Token Rate Limited"
        break
    fi
done
# Wait 60s for rate limit counters to reset
sleep 60
```

> **Note**: This test only produces a 429 when the TokenRateLimitPolicy from [3.8 Configure TokenRateLimitPolicy for LLMInferenceService](#38-configure-tokenratelimitpolicy-for-llminferenceservice) has been applied. On clusters with the Models as a Service (MaaS) component enabled, the pre-existing MaaS TokenRateLimitPolicies only apply to subscription-key traffic — plain Kubernetes SA-token users are not rate limited through the `openshift-ai-inference` Gateway, so without the section 3.8 policy this test completes without ever hitting 429.

### 4.5 Batch Authentication

```bash
# Unauthenticated -> 401
curl -sk -o /dev/null -w "%{http_code}\n" ${GW_URL}/v1/batches

# Authenticated -> 200
curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" ${GW_URL}/v1/batches
```

### 4.6 Batch Authorization (batch-llm-route enforcement)

```bash
# Unauthorized user creates a batch — batch is accepted (batch route has no authz),
# but the async-processor forwards requests to the batch-llm-route (Internal Gateway)
# with the unauthorized token, and its AuthPolicy rejects with 403.

# Create input file
cat > /tmp/batch-input.jsonl <<EOF
{"custom_id":"req-1","method":"POST","url":"/v1/chat/completions","body":{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}}
EOF

FILE_ID=$(curl -sk ${GW_URL}/v1/files \
    -H "Authorization: Bearer ${UNAUTH_TOKEN}" \
    -F purpose=batch \
    -F "file=@/tmp/batch-input.jsonl" \
    | jq -r '.id')

BATCH_ID=$(curl -sk ${GW_URL}/v1/batches \
    -H "Authorization: Bearer ${UNAUTH_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"input_file_id":"'${FILE_ID}'","endpoint":"/v1/chat/completions","completion_window":"24h"}' \
    | jq -r '.id')

# Wait for processing, then check status — expect failed requests with 403
# If still "in_progress", wait longer and re-run the curl command below
sleep 30
curl -sk ${GW_URL}/v1/batches/${BATCH_ID} \
    -H "Authorization: Bearer ${UNAUTH_TOKEN}" | jq '{status, request_counts}'
```

### 4.7 Batch Lifecycle

```bash
# Create input file
cat > /tmp/batch-input.jsonl <<EOF
{"custom_id":"req-1","method":"POST","url":"/v1/chat/completions","body":{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}}
EOF

# Upload input file
FILE_ID=$(curl -sk ${GW_URL}/v1/files \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -F purpose=batch \
    -F "file=@/tmp/batch-input.jsonl" \
    | jq -r '.id')

# Create batch
BATCH_ID=$(curl -sk ${GW_URL}/v1/batches \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"input_file_id":"'${FILE_ID}'","endpoint":"/v1/chat/completions","completion_window":"24h"}' \
    | jq -r '.id')

# Wait for processing, then check status
# If still "in_progress", wait longer and re-run the curl command below
sleep 30
curl -sk ${GW_URL}/v1/batches/${BATCH_ID} \
    -H "Authorization: Bearer ${AUTH_TOKEN}" | jq '.status'

# Download results (after status is "completed")
OUTPUT_FILE_ID=$(curl -sk ${GW_URL}/v1/batches/${BATCH_ID} \
    -H "Authorization: Bearer ${AUTH_TOKEN}" | jq -r '.output_file_id')

curl -sk ${GW_URL}/v1/files/${OUTPUT_FILE_ID}/content \
    -H "Authorization: Bearer ${AUTH_TOKEN}"
```

### 4.8 Batch Request Rate Limit

```bash
# Send 25 rapid requests — expect 429 after 20 (rate limit: 20 req/min)
for i in $(seq 1 25); do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${AUTH_TOKEN}" ${GW_URL}/v1/batches)
    echo "Request $i: $http_code"
done
```
