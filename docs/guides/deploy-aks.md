# Batch Gateway on AKS with RHAIIS (Operator-based)

This guide demonstrates how to deploy batch-gateway on AKS using the **batch-gateway operator** on top of [RHAIIS](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md), using [Kuadrant](https://kuadrant.io/) for authentication, authorization, and rate limiting.

> **Note**: The batch gateway does not depend on Kuadrant. This guide uses Kuadrant for gateway-level auth and rate limiting, but any policy engine that works with Gateway API can be used instead.

> **Note**: This guide is for AKS clusters **without** OpenShift. If you have OpenShift, see [deploy-rhoai.md](deploy-rhoai.md).

## 1. Architecture Overview

### 1.1 Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `istio-system` | Istio control plane (istiod) — installed by RHAIIS |
| `redhat-ods-applications` | KServe, inference-gateway, RHAIIS controllers, batch-gateway-operator — installed by RHAIIS + kustomize |
| `llm` (example; any user-defined namespace) | LLMInferenceService, model servers, InferencePool, EPP, InferenceObjective CRDs |
| `redhat-ods-operator` | RHAI operator — installed by RHAIIS |
| `cert-manager` | cert-manager — installed by RHAIIS |
| `kuadrant-system` | Kuadrant operator, Authorino, Limitador |
| `batch-api` | batch-gateway (apiserver + processor + gc), Redis, PostgreSQL |

### 1.2 Data Flow

**Batch inference flow**:
1. Client sends a batch request (e.g. `POST /v1/batches`) to the inference Gateway (`inference-gateway`) with a Kubernetes token
2. Gateway matches `/v1/batches`, `/v1/files` → **batch-route** (HTTPRoute)
    - **AuthPolicy** on the batch-route performs authentication only (kubernetesTokenReview, no authorization check) — unauthenticated requests are rejected with 401
    - **RateLimitPolicy** on the batch-route enforces per-user request rate limiting (e.g. 20 req/min), keyed by Kubernetes username (user or ServiceAccount) from TokenReview — excess requests are rejected with 429
    - Authenticated request is forwarded to **batch-gateway apiserver**, which stores the batch job
3. **Processor** dequeues the batch job and sends inference requests through a separate **Internal Gateway** (`batch-internal-gateway`) — a ClusterIP-only Gateway that is not externally accessible — with the user's original token
4. The Internal Gateway matches `/{ns}/{isvc-name}/v1/*` → **batch-llm-route** (HTTPRoute)
    - **AuthPolicy** on the batch-llm-route performs authentication and authorization (SubjectAccessReview — checks if the original user can `get llminferenceservices/<name>`) — if the user lacks permission, the request is rejected with 403
    - **No TokenRateLimitPolicy** — batch inference requests are exempt from per-user token rate limits
5. Request is routed directly to the **vLLM model server** (workload Service, port 8000 with TLS). The Internal Gateway does not use InferencePool/EPP routing because it lacks the ext_proc extension — only the inference-gateway (provisioned by RHAIIS) has InferencePool support. The response is returned to the Processor, which adds the response to the batch job's output file

### 1.3 Authentication

Both the LLM route and the batch route use **kubernetesTokenReview** for authentication. Clients provide a valid Kubernetes token via the `Authorization: Bearer <token>` header. The token must include the audience `https://kubernetes.default.svc`. Tokens are typically created from a ServiceAccount using `kubectl create token`.

- **LLM route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**
- **Batch route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**

### 1.4 Authorization Model

Model access is controlled through Kubernetes RBAC. Users need `get` permission on the specific `LLMInferenceService` resource to access a model. This is granted by creating a Role and RoleBinding in the model's namespace.

- **LLM route**: SubjectAccessReview checks if user can `get llminferenceservices/<name>` — unauthorized requests are rejected with **403**
- **Batch route**: No authorization check — authorization is enforced by the batch-llm-route on the Internal Gateway when the processor forwards inference requests with the user's original token

### 1.5 Security boundary: batch-route vs batch-llm-route

For security and operations readers: **admission on the batch API is not the same as authorization for inference.**

- **batch-route** proves the caller has a valid Kubernetes token and applies batch-side **RateLimitPolicy**. Invalid or missing credentials are rejected with **401**; excess batch API traffic is rejected with **429**. It does **not** evaluate whether the caller may use a specific `LLMInferenceService`.
- **batch-llm-route** (on the Internal Gateway) runs **authentication and authorization** (SubjectAccessReview on `llminferenceservices` as above) on each inference request the processor sends. The Internal Gateway is ClusterIP-only — it has no external Route or Ingress, ensuring batch inference traffic stays cluster-internal. **No TokenRateLimitPolicy** is applied, so batch requests are exempt from per-user token rate limits. A user can create a batch job and still see **per-request failures** (often surfaced as failed lines or job errors) when the batch-llm-route returns **403** — this is **by design**, not a bypass of model access control.

The `Authorization` header is included in `passThroughHeaders` by default. Without it, the Internal Gateway cannot attribute inference traffic to the original caller and model-level checks cannot run as intended.

### 1.6 Flow Control

Flow control ensures interactive inference requests are always served before batch requests. The EPP (Endpoint Picker Plugin) uses GIE's flow control feature to assign requests to priority bands based on the `x-gateway-inference-objective` header:

| Priority Band | Priority | Workload | Behavior Under Saturation |
|---------------|----------|----------|---------------------------|
| Interactive | 100 | Interactive requests | Dispatched first |
| Default | 0 | Requests without an objective header | Dispatched before batch |
| Batch | -1 (sheddable) | Batch requests | Shed immediately; processor retries with backoff |

When the backend is not saturated, both interactive and batch requests are dispatched freely. When saturation reaches 1.0, batch requests (priority -1) are shed at admission while interactive requests continue to be served.

This is configured through three components:

1. **EndpointPickerConfig** in the LLMInferenceService CR (`spec.router.scheduler.config.inline`) enables the `flowControl` feature gate and defines priority bands, fairness policies, and saturation detection thresholds.
2. **InferenceObjective CRDs** map objective names to priority levels. The batch processor sends the `x-gateway-inference-objective: batch-sheddable` header, which EPP resolves to priority -1.
3. **Batch processor `inferenceObjective` config** sets which `InferenceObjective` name is sent in the header on each inference request.

For full details on flow control configuration, see the [Flow Control Setup Guide](flow-control-setup.md).

> **AKS limitation**: On RHAIIS/AKS, the batch-internal-gateway routes directly to the workload service (bypassing InferencePool/EPP) because only the `inference-gateway` has the ext_proc extension needed for InferencePool support. This means EPP flow control prioritization does not apply to batch requests. Batch and interactive requests are served equally by the model server. If flow control is critical, consider routing batch traffic through the `inference-gateway` instead (with appropriate policy exemptions).

## 2. Prerequisites

- AKS cluster (Kubernetes 1.28+) with GPU nodes
- **RHAIIS installed** (latest version) — follow the [rhai-on-xks-chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md) to install RHAIIS on AKS
- CLI tools: `kubectl`, `helm`, `curl`, `jq`, `skopeo`
- Pull secret at `~/pull-secret.txt` (for quay.io/rhoai and registry images)

### Verify RHAIIS Installation

Before proceeding, confirm RHAIIS is healthy:

```bash
# Inference gateway should show an external IP and Programmed=True
kubectl get gateway -A
# Expected:
# NAMESPACE                  NAME                CLASS   ADDRESS        PROGRAMMED
# redhat-ods-applications    inference-gateway   istio   <external-ip>  True

# KServe controller should be running
kubectl get pods -n redhat-ods-applications -l control-plane=llmisvc-controller-manager

# Operator should be running
kubectl get pods -n redhat-ods-operator
```

## 3. Installation Steps

### 3.0 Prepare Infrastructure


<details>
<summary>Patch inference-gateway to allow routes from labeled namespaces</summary>

By default, the RHAIIS inference-gateway only allows HTTPRoutes from `redhat-ods-applications` (`allowedRoutes.namespaces.from: Same`). Batch-gateway needs to attach routes from the `batch-api` namespace, and model workloads live in the `llm` namespace. Use a label selector to restrict attachment to explicitly labeled namespaces only:

```bash
# Build a patch for all listeners on the gateway
LISTENER_COUNT=$(kubectl get gateway inference-gateway -n redhat-ods-applications \
    -o jsonpath='{.spec.listeners}' | jq length)
PATCH="["
for i in $(seq 0 $((LISTENER_COUNT - 1))); do
    [ "$i" -gt 0 ] && PATCH="${PATCH},"
    PATCH="${PATCH}{\"op\":\"replace\",\"path\":\"/spec/listeners/$i/allowedRoutes/namespaces/from\",\"value\":\"Selector\"}"
    PATCH="${PATCH},{\"op\":\"add\",\"path\":\"/spec/listeners/$i/allowedRoutes/namespaces/selector\",\"value\":{\"matchLabels\":{\"llm-d.ai/gateway-route\":\"true\"}}}"
done
PATCH="${PATCH}]"

kubectl patch gateway inference-gateway -n redhat-ods-applications --type='json' -p="${PATCH}"

# Label namespaces that need to attach routes to the inference-gateway
kubectl label namespace redhat-ods-applications llm-d.ai/gateway-route=true --overwrite
```

> The `llm` namespace is labeled in step 3.2 when the model is deployed. The `batch-api` namespace is labeled later in step 3.5 when it is created.


> **Security**: Only namespaces with the `llm-d.ai/gateway-route: "true"` label can attach HTTPRoutes to the inference-gateway. This is the same pattern used by the batch-gateway Helm deployment (`deploy-k8s.md`). On RHOAI (OpenShift), this patch is not needed because all batch-gateway HTTPRoutes are deployed in the same namespace as the gateway.

> **Note**: If the RHAIIS cloud-manager reconciles the gateway back to `Same`, you may need to disable gateway management or use a separate gateway for batch traffic.

</details>

### 3.1 Install Kuadrant

Kuadrant provides AuthPolicy (authentication + authorization) and RateLimitPolicy for gateway traffic. See [Kuadrant documentation](https://docs.kuadrant.io/) for details.

<details>
<summary>Install Kuadrant operator via Helm</summary>

```bash
KUADRANT_NS=kuadrant-system
KUADRANT_VERSION=1.5.0   # check https://kuadrant.io/helm-charts/ for latest

helm repo add kuadrant https://kuadrant.io/helm-charts/ --force-update
helm upgrade --install kuadrant-operator kuadrant/kuadrant-operator \
    --version "${KUADRANT_VERSION}" \
    --create-namespace \
    --namespace "${KUADRANT_NS}"

kubectl rollout status deploy/authorino-operator -n ${KUADRANT_NS} --timeout=120s
kubectl rollout status deploy/kuadrant-operator-controller-manager -n ${KUADRANT_NS} --timeout=120s
kubectl rollout status deploy/limitador-operator-controller-manager -n ${KUADRANT_NS} --timeout=120s
```

</details>

<details>
<summary>Create Kuadrant CR</summary>

```bash
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOF

kubectl wait kuadrant/kuadrant --for="condition=Ready=true" \
    -n "${KUADRANT_NS}" --timeout=300s
```

</details>

### 3.2 Deploy model with LLMInferenceService

Follow the [RHAIIS on xKS deployment guide](https://github.com/opendatahub-io/rhaii-on-xks/blob/main/docs/deploying-rhaii-helmcharts-on-xks-ea2.md) to deploy a model, or use the simulated model below for testing.

The following example deploys a simulated model with `LLMInferenceService`.

<details>
<summary>Deploy a simulated model with LLMInferenceService</summary>

```bash
LLM_NS=llm   # any user-defined namespace; label it llm-d.ai/gateway-route=true below
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

kubectl create namespace "${LLM_NS}" 2>/dev/null || true
kubectl label namespace "${LLM_NS}" llm-d.ai/gateway-route=true --overwrite

kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: ${ISVC_NAME}
  namespace: ${LLM_NS}
  annotations:
    security.opendatahub.io/enable-auth: "true"
spec:
  model:
    uri: hf://sshleifer/tiny-gpt2
    name: ${MODEL_NAME}
  replicas: 2
  router:
    route: {}
    scheduler:
      template:
        imagePullSecrets:
          - name: rhai-pull-secret
        containers:
          - name: main
          - name: tokenizer
      config:
        inline:
          apiVersion: inference.networking.x-k8s.io/v1alpha1
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
          saturationDetector:
            pluginRef: utilization-detector
          flowControl:
            maxBytes: 4294967296
            defaultRequestTTL: 30s
            priorityBands:
              - priority: 100
                maxBytes: 1073741824
                fairnessPolicyRef: round-robin-fairness-policy
                orderingPolicyRef: fcfs-ordering-policy
              - priority: -1
                maxBytes: 3221225472
                fairnessPolicyRef: global-strict-fairness-policy
                orderingPolicyRef: slo-deadline-ordering-policy
            defaultPriorityBand:
              maxBytes: 536870912
              fairnessPolicyRef: global-strict-fairness-policy
              orderingPolicyRef: fcfs-ordering-policy
  template:
    imagePullSecrets:
      - name: rhai-pull-secret
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

```bash
kubectl wait llminferenceservice/${ISVC_NAME} -n ${LLM_NS} \
    --for=condition=Ready --timeout=600s
```

> **Key annotation**: `security.opendatahub.io/enable-auth: "true"` enables the Gateway-level AuthPolicy that uses SubjectAccessReview to check if the user has RBAC permission to `get` the specific `LLMInferenceService` resource.

> **Flow control config**: The `scheduler.config.inline` EndpointPickerConfig enables the `flowControl` feature gate with two priority bands: interactive (priority 100, round-robin fairness, FCFS ordering) and batch (priority -1, sheddable, SLO-deadline ordering). The `saturationDetector` monitors backend queue depth and KV-cache utilization to trigger head-of-line blocking when the system is saturated. See [1.6 Flow Control](#16-flow-control) for details.

</details>

<details>
<summary>Check LLMInferenceService deployment</summary>

> **Note**: The `LLMInferenceService` CRD automatically creates the model server Deployment, InferencePool, EPP, and HTTPRoute.

```bash
kubectl get all -n ${LLM_NS}
kubectl get httproute -n ${LLM_NS}
```

</details>

### 3.3 Create InferenceObjective CRDs

Create `InferenceObjective` resources that map the `x-gateway-inference-objective` header value to a priority band in EPP's flow control. The batch processor sends the `batch-sheddable` objective on each inference request.

<details>
<summary>Create InferenceObjective CRDs</summary>

```bash
# Discover the InferencePool created by the LLMInferenceService
POOL_NAME=$(kubectl get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)

kubectl apply -f - <<EOF
apiVersion: inference.networking.x-k8s.io/v1alpha2
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
apiVersion: inference.networking.x-k8s.io/v1alpha2
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

> **`interactive-default` (priority 100)**: Interactive clients can optionally send `x-gateway-inference-objective: interactive-default` to get the highest priority. Without this header, requests default to priority 0, which still outranks batch.

> **`batch-sheddable` (priority -1)**: Negative priority means sheddable — when the backend is saturated, these requests are rejected immediately instead of queued. The batch processor handles retries with exponential backoff.

</details>

### 3.4 Configure AuthPolicy and TokenRateLimitPolicy for inference-gateway

Apply authentication, authorization, and token rate limiting for direct inference requests via the inference-gateway.

<details>
<summary>Apply AuthPolicy on inference-gateway</summary>

> **Note**: The AuthPolicy targets the inference Gateway (not HTTPRoute) because LLMInferenceService dynamically generates the HTTPRoute name.

```bash
RHAIIS_NS=redhat-ods-applications

kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: inference-gateway-auth
  namespace: ${RHAIIS_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
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
            namespace:
              expression: request.path.split("/")[1]
            group:
              value: serving.kserve.io
            resource:
              value: llminferenceservices
            name:
              expression: request.path.split("/")[2]
            verb:
              value: get
EOF

kubectl wait authpolicy/inference-gateway-auth \
    --for="condition=Enforced=true" \
    -n ${RHAIIS_NS} --timeout=180s
```

</details>

<details>
<summary>Apply TokenRateLimitPolicy on inference-gateway</summary>

> **Note**: The TokenRateLimitPolicy targets the Gateway (not HTTPRoute) because LLMInferenceService dynamically generates the inference HTTPRoute name.

```bash
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: inference-token-limit
  namespace: ${RHAIIS_NS}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
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

# Wait for policy to be enforced
kubectl wait tokenratelimitpolicy/inference-token-limit \
    --for="condition=Enforced=true" \
    -n ${RHAIIS_NS} --timeout=180s
```

</details>

### 3.5 Install Batch Gateway

The batch processor routes inference requests through a separate, ClusterIP-only Internal Gateway to bypass the TokenRateLimitPolicy on the external Gateway while still enforcing model-level authorization (AuthPolicy).

Set the variables used throughout this section (re-set them if starting a new shell):
```bash
LLM_NS=llm   # any user-defined namespace
BATCH_NS=batch-api
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
RHAIIS_NS=redhat-ods-applications
```

<details>
<summary>Patch RHAIIS llmisvc-controller-manager (if needed)</summary>

The RHAIIS `llmisvc-controller-manager` may lack `imagePullSecrets` for midstream images. Patch it if the pod is in `ImagePullBackOff`:

```bash
RHAIIS_NS=redhat-ods-applications
if kubectl get deploy llmisvc-controller-manager -n "${RHAIIS_NS}" &>/dev/null; then
    kubectl patch deploy llmisvc-controller-manager -n "${RHAIIS_NS}" --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/imagePullSecrets", "value": [{"name": "rhai-pull-secret"}]}]'
    kubectl rollout status deploy/llmisvc-controller-manager -n "${RHAIIS_NS}" --timeout=120s
fi
```

</details>

<details>
<summary>Install batch-gateway operator (via kustomize)</summary>

Install the batch-gateway-operator directly from `opendatahub-io/llm-d-batch-gateway-operator`. The `rhoai` overlay deploys into `redhat-ods-applications` with midstream `odh-stable` images. On RHOAI (OpenShift), downstream v3.5-EA2 images are injected via the `RELATED_IMAGE_*` mechanism; without that, midstream images are used.

```bash
kubectl apply -k "https://github.com/opendatahub-io/llm-d-batch-gateway-operator/config/overlays/rhoai?ref=main"

kubectl rollout status deploy/llm-d-batch-gateway-operator -n redhat-ods-applications --timeout=120s
```

Verify:

```bash
kubectl get pods -n redhat-ods-applications -l app.kubernetes.io/name=llm-d-batch-gateway-operator
kubectl get crd | grep llmbatchgateway               # LLMBatchGateway CRD registered
```

</details>

<details>
<summary>Create Internal Gateway (ClusterIP)</summary>

```bash
# Create a parametersRef ConfigMap to mount the RHAIIS CA bundle on the gateway's Envoy.
# This is needed because the workload service uses TLS and the DestinationRule references
# /var/run/secrets/rhai/ca.crt for certificate validation.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: batch-internal-gateway-config
  namespace: ${RHAIIS_NS}
data:
  deployment: |
    spec:
      template:
        spec:
          volumes:
          - name: rhai-ca-bundle
            configMap:
              name: rhai-ca-bundle
          containers:
          - name: istio-proxy
            volumeMounts:
            - name: rhai-ca-bundle
              mountPath: /var/run/secrets/rhai
              readOnly: true
EOF

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: batch-internal-gateway
  namespace: ${RHAIIS_NS}
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: batch-internal-gateway-config
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

# Wait for Gateway to be programmed
kubectl wait --for=condition=Programmed --timeout=300s \
    -n ${RHAIIS_NS} gateway/batch-internal-gateway
```

> **Key annotation**: `networking.istio.io/service-type: ClusterIP` forces the Gateway's Service to be ClusterIP instead of LoadBalancer, ensuring it is not externally accessible.

> **parametersRef**: The ConfigMap mounts the RHAIIS CA bundle (`rhai-ca-bundle`) into the gateway's Envoy proxy at `/var/run/secrets/rhai/ca.crt`. This is required because model workload services use TLS and the existing DestinationRule references this CA path for certificate validation.

> **HTTP only**: The Internal Gateway uses HTTP (port 80) with no TLS listener. Since traffic is cluster-internal (processor → Internal Gateway → workload service), TLS is handled by the Istio DestinationRule (originating TLS to the backend).

</details>

<details>
<summary>Create batch-llm-route (HTTPRoute on Internal Gateway)</summary>

```bash
# Discover the workload service owned by the LLMInferenceService
WORKLOAD_SVC=$(kubectl get svc -n ${LLM_NS} \
    -l "app.kubernetes.io/name=${ISVC_NAME},app.kubernetes.io/component=llminferenceservice-workload" \
    -o jsonpath='{.items[0].metadata.name}')

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-llm-route
  namespace: ${LLM_NS}
spec:
  parentRefs:
  - name: batch-internal-gateway
    namespace: ${RHAIIS_NS}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NS}/${ISVC_NAME}
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: ${WORKLOAD_SVC}
      port: 8000
EOF
```

> **Direct-to-workload routing**: The batch-llm-route targets the model server's workload Service directly (port 8000, TLS) rather than an InferencePool. This is because the batch-internal-gateway does not have the ext_proc extension configured for InferencePool support — only the `inference-gateway` (provisioned by RHAIIS) has this. The Istio DestinationRule created by the LLMInferenceService controller handles TLS origination to the workload using the RHAIIS CA bundle.

> **URL rewrite**: The single rule matches the `/{namespace}/{isvc-name}` prefix and replaces it with `/`, preserving the API path suffix (e.g. `/v1/chat/completions`, `/v1/completions`).

</details>

<details>
<summary>Apply AuthPolicy for batch-llm-route</summary>

```bash
kubectl apply -f - <<EOF
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

<details>
<summary>Create namespace and install dependencies</summary>

```bash
kubectl create namespace "${BATCH_NS}" 2>/dev/null || true
kubectl label namespace "${BATCH_NS}" llm-d.ai/gateway-route=true --overwrite

# Install Redis (or Valkey — see alternative below)
helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/redis \
    --namespace ${BATCH_NS} --create-namespace \
    --set architecture=standalone \
    --set auth.enabled=false
kubectl rollout status statefulset/redis-master -n ${BATCH_NS} --timeout=120s

# Alternative: Install Valkey (wire-protocol compatible with Redis)
# helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/valkey \
#     --namespace ${BATCH_NS} --create-namespace \
#     --set architecture=standalone \
#     --set auth.enabled=false
# kubectl rollout status statefulset/redis-valkey-primary -n ${BATCH_NS} --timeout=120s
# Note: when using Valkey, update the redis-url secret below to use:
#   redis://redis-valkey-primary.${BATCH_NS}.svc.cluster.local:6379/0

# Install PostgreSQL
PG_PASSWORD="<your-password>"   # set once, referenced below
helm upgrade --install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
    --namespace ${BATCH_NS} --create-namespace \
    --set "auth.postgresPassword=${PG_PASSWORD}" \
    --set auth.database=batch
kubectl rollout status statefulset/postgresql -n ${BATCH_NS} --timeout=120s

# Install MinIO (S3-compatible object storage for batch files)
MINIO_USER=<your-minio-user>
MINIO_PASSWORD=<your-minio-password>
MINIO_BUCKET=batch-gateway

kubectl apply -f - <<EOF
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

until kubectl get deployment minio -n ${BATCH_NS} &>/dev/null; do sleep 5; done
kubectl rollout status deployment/minio -n ${BATCH_NS} --timeout=180s

# Create application secret
kubectl create secret generic batch-gateway-secrets \
    --namespace ${BATCH_NS} \
    --from-literal=redis-url="redis://redis-master.${BATCH_NS}.svc.cluster.local:6379/0" \
    --from-literal=postgresql-url="postgresql://postgres:${PG_PASSWORD}@postgresql.${BATCH_NS}.svc.cluster.local:5432/batch?sslmode=disable" \
    --from-literal=s3-secret-access-key="${MINIO_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

> **Note**: Redis auth is disabled for demo purposes. For production, enable Redis authentication.

</details>

<details>
<summary>Create LLMBatchGateway CR</summary>

```bash
# Get model URL from the Internal Gateway service
INTERNAL_GW_SVC=$(kubectl get svc -n ${RHAIIS_NS} \
    -l "gateway.networking.k8s.io/gateway-name=batch-internal-gateway" \
    -o jsonpath='{.items[0].metadata.name}')
MODEL_URL="http://${INTERNAL_GW_SVC}.${RHAIIS_NS}.svc.cluster.local/${LLM_NS}/${ISVC_NAME}"

kubectl apply -f - <<EOF
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
      region: us-east-1
      endpoint: http://minio.${BATCH_NS}.svc.cluster.local:9000
      accessKeyId: ${MINIO_USER}
      bucket: ${MINIO_BUCKET}
      usePathStyle: true
      autoCreateBucket: true
  apiServer:
    replicas: 1
    config:
      batchAPI:
        passThroughHeaders:
        - Authorization
  processor:
    replicas: 1
    globalInferenceGateway:
      url: ${MODEL_URL}
      requestTimeout: 5m
      maxRetries: 3
      initialBackoff: 1s
      maxBackoff: 60s
      inferenceObjective: batch-sheddable
  gc:
    interval: 30m
  tls:
    enabled: true
    certManager:
      issuerName: opendatahub-selfsigned-issuer
      issuerKind: ClusterIssuer
      dnsNames:
      - batch-gateway-apiserver
      - batch-gateway-apiserver.${BATCH_NS}.svc.cluster.local
      - localhost
EOF

# Wait for the batch gateway to be ready
kubectl wait llmbatchgateway/batch-gateway -n ${BATCH_NS} \
    --for=condition=Ready --timeout=300s
```

> - **`processor.globalInferenceGateway.url`**: Points to the Internal Gateway's model endpoint. The Internal Gateway enforces AuthPolicy (model access check) but not TokenRateLimitPolicy.
> - **`processor.globalInferenceGateway.inferenceObjective`**: The `InferenceObjective` CRD name sent as the `x-gateway-inference-objective` header. EPP uses this to assign the request to the batch priority band (priority -1, sheddable).
> - **`tls.certManager`**: Enables TLS for the batch API server using cert-manager. In this demo the DestinationRule (see [3.6](#36-configure-httproute-and-policies-for-batch-gateway)) uses `insecureSkipVerify: true` because we use a self-signed certificate; in production, configure a trusted CA.
> - **File storage**: This example uses S3-compatible storage (MinIO). To use a PVC instead, replace `fileStorage.s3` with:
>   ```yaml
>   fileStorage:
>     fs:
>       basePath: /tmp/batch-gateway
>       claimName: <your-pvc-name>
>   ```
>   The PVC must have `ReadWriteMany` access mode (requires NFS, CephFS, or similar).

</details>

### 3.6 Configure HTTPRoute and Policies for Batch Gateway

Set the variable used throughout this section (re-set if starting a new shell):
```bash
BATCH_NS=batch-api
RHAIIS_NS=redhat-ods-applications
```

Create the batch route, authentication policy, and rate limit:

<details>
<summary>Create HTTPRoute for Batch API Server</summary>

```bash
# Batch HTTPRoute (on the same inference-gateway used for LLM traffic)
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-route
  namespace: ${BATCH_NS}
spec:
  parentRefs:
  - name: inference-gateway
    namespace: ${RHAIIS_NS}
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
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: batch-gateway-backend-tls
  namespace: ${RHAIIS_NS}
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
kubectl apply -f - <<EOF
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
kubectl apply -f - <<EOF
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
LLM_NS=llm   # any user-defined namespace
BATCH_NS=batch-api
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
RHAIIS_NS=redhat-ods-applications
```

### 4.1 Setup Test Accounts

```bash
# Get Gateway address
GW_ADDR=$(kubectl get gateway inference-gateway -n ${RHAIIS_NS} \
    -o jsonpath='{.status.addresses[0].value}')
GW_URL="http://${GW_ADDR}"

# If the gateway IP is not reachable externally, use port-forward:
# kubectl port-forward svc/inference-gateway-istio -n ${RHAIIS_NS} 8080:80 &
# GW_URL="http://localhost:8080"

# Create authorized SA with RBAC to access the LLMInferenceService
kubectl create serviceaccount test-authorized-sa -n ${LLM_NS} 2>/dev/null || true
kubectl apply -f - <<EOF
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

AUTH_TOKEN=$(kubectl create token test-authorized-sa -n ${LLM_NS} \
    --audience=https://kubernetes.default.svc --duration=60m)

# Create unauthorized SA (no RBAC)
kubectl create serviceaccount test-unauthorized-sa -n ${LLM_NS} 2>/dev/null || true
UNAUTH_TOKEN=$(kubectl create token test-unauthorized-sa -n ${LLM_NS} \
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
# but the processor forwards requests to the batch-llm-route (Internal Gateway)
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

## 5. AKS-Specific Considerations

This section documents AKS platform differences that apply regardless of install method (operator or Helm).

### Gateway Networking

Gateway Services on AKS provision an Azure Load Balancer. For internal-only clusters, annotate the relevant Service:

**Operator path (this guide):**

```bash
kubectl annotate svc inference-gateway-istio -n ${RHAIIS_NS} \
  service.beta.kubernetes.io/azure-load-balancer-internal=true --overwrite
```

**Helm path:** annotate `istio-gateway-istio` in `istio-ingress` — see [§8 Helm Install](#8-helm-install-alternative).

Clients access the gateway from within the VNet (peered networks, VPN, ExpressRoute).

### File Storage

AKS default storage classes (`managed-csi`, `managed-premium`) are block storage and only support `ReadWriteOnce`. The batch-gateway requires shared access across apiserver, processor, and gc pods when using filesystem storage.

**Option A — S3-compatible (recommended):** Use MinIO as documented in [§3.5](#35-install-batch-gateway). No AKS-specific changes required.

**Option B — Azure Files with pre-created storage account:** The built-in `azurefile-csi` and `azurefile-csi-premium` StorageClasses will fail if the subscription enforces HTTPS-only on storage accounts (the CSI driver creates accounts with HTTP enabled, which violates the policy). Pre-create the storage account and file share, then reference them via a static PV.

1. Register the storage provider (if not already registered):

```bash
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv
# Wait until: Registered
```

2. Create a storage account and file share:

```bash
az storage account create \
  --name <storage-account-name> \
  --resource-group <aks-resource-group> \
  --location <region> \
  --sku Premium_LRS \
  --kind FileStorage \
  --https-only true \
  --allow-shared-key-access true

az storage share-rm create \
  --storage-account <storage-account-name> \
  --resource-group <aks-resource-group> \
  --name batch-gateway \
  --quota 100
```

3. Create a Kubernetes secret with the storage account key:

```bash
STORAGE_KEY=$(az storage account keys list \
  --account-name <storage-account-name> \
  --resource-group <aks-resource-group> \
  --query "[0].value" -o tsv)

kubectl create secret generic azure-files-secret \
  --namespace batch-api \
  --from-literal=azurestorageaccountname=<storage-account-name> \
  --from-literal=azurestorageaccountkey="$STORAGE_KEY"
```

4. Create PV and PVC:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: batch-gateway-files-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: file.csi.azure.com
    volumeHandle: <storage-account-name>-batch-gateway
    volumeAttributes:
      shareName: batch-gateway
    nodeStageSecretRef:
      name: azure-files-secret
      namespace: batch-api
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: batch-gateway-files
  namespace: batch-api
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 100Gi
  volumeName: batch-gateway-files-pv
EOF
```

5. Configure batch-gateway to use the PVC:

**Operator path** — update the `LLMBatchGateway` CR:

```yaml
spec:
  fileStorage:
    fs:
      basePath: /tmp/batch-gateway
      claimName: batch-gateway-files
```

**Helm path** — see [§8 Helm Install](#8-helm-install-alternative).

### Monitoring CRDs

The llm-d simulated-accelerators values enable `PodMonitor` resources. AKS clusters do not ship the Prometheus Operator CRDs by default. These options apply to the [Helm install path](#8-helm-install-alternative).

**Option A — Install only the CRDs** (charts deploy successfully; no scraping):

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
```

**Option B — Install the full Prometheus Operator** (CRDs + metric scraping):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

**Option C — Enable AKS managed Prometheus** (Azure Monitor):

Enable [Azure Monitor managed service for Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview) on the cluster. This supports PodMonitor/ServiceMonitor CRDs natively.

**Option D — Disable monitoring** (skip PodMonitor entirely):

```bash
# InferencePool (GAIE)
--set inferenceExtension.monitoring.prometheus.enabled=false

# ModelService
--set decode.monitoring.podmonitor.enabled=false \
--set prefill.monitoring.podmonitor.enabled=false
```

### AKS Known Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| GC pod reports `0/1 Ready` (v0.1.0 only) | Startup probe misconfiguration; fixed in later versions | Upgrade to v0.2.0+, or ignore — no functional impact |
| `azurefile-csi` / `azurefile-csi-premium` PVC provisioning fails | Subscription policy requires HTTPS-only storage accounts; CSI driver creates accounts without HTTPS | Pre-create storage account with `--https-only true` (see File Storage Option B above) |
| `Microsoft.Storage` provider not registered | `az storage account create` returns `SubscriptionNotFound` | Run `az provider register --namespace Microsoft.Storage` and wait for `Registered` state |

## 6. Differences from RHOAI Guide

| Aspect | RHOAI (OCP) | AKS (this guide) |
|--------|-------------|-------------------|
| Platform stack | RHOAI operator (OLM) | RHAIIS Helm chart (`rhai-on-xks-chart`) |
| CLI | `oc` | `kubectl` |
| Gateway class | `openshift-default` | `istio` (via RHAIIS Sail Operator) |
| External gateway | `openshift-ai-inference` in `openshift-ingress` | `inference-gateway` in `redhat-ods-applications` |
| Internal gateway namespace | `openshift-ingress` | `redhat-ods-applications` |
| Batch gateway operator | Managed by RHOAI DataScienceCluster | `llm-d-batch-gateway-operator` via kustomize (no OLM) |
| Auth/Rate limiting | RHCL (OLM) | Kuadrant (Helm) |
| TLS certificates | OpenShift serving certs | cert-manager (installed by RHAIIS) |
| Gateway hostname | DNS-based (`llm-inference.apps.<domain>`) | IP-based (LoadBalancer external IP) |

## 7. Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| RHAIIS pods `ImagePullBackOff` | Pull secret missing registry credentials | Check `~/pull-secret.txt` covers all registries (see [rhai-on-xks-chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md)) |
| `inference-gateway` not Programmed | Istio not ready | `kubectl get pods -n istio-system` and check Sail Operator |
| `LLMInferenceService` stuck | Controller not ready or missing CRDs | `kubectl logs -n redhat-ods-applications -l app=llmisvc-controller-manager` |
| `LLMBatchGateway` CR not accepted | CRD not installed | `kubectl get pods -n redhat-ods-applications -l app.kubernetes.io/name=llm-d-batch-gateway-operator`; verify operator is running |
| Gateway unreachable externally | AKS internal LB or NSG rules | Use `kubectl port-forward` or allowlist your IP |
| Gateway unreachable from client | Internal LB; client outside VNet | Access from within the VNet or use an in-cluster test pod |
| Pods `Pending` on PVC | Dynamic provisioning failed (HTTPS policy or wrong storage class) | Use pre-created storage account ([§5 File Storage](#file-storage) Option B) or MinIO/S3 (Option A) |
| PVC mount fails with `No such file or directory` | File share does not exist in the storage account | Create it with `az storage share-rm create --resource-group <rg> --storage-account <name> --name batch-gateway` |
| PVC mount fails | AKS block storage doesn't support RWX | Use MinIO/S3 (recommended) or Azure Files with pre-created storage account |
| File upload returns S3 error | `s3-secret-access-key` does not match `MINIO_ROOT_PASSWORD` | Recreate the `batch-gateway-secrets` secret with matching credentials |
| Pods `CrashLoopBackOff` with URL parse error | Special characters in `postgresql-url` | URL-encode the password in the connection string |
| `inference-gateway-istio` OOMKilled | Kuadrant wasm plugin exceeds default 1Gi memory | Increase memory to 2Gi in the `inference-gateway-config` ConfigMap (`data.deployment` → `containers[].resources.limits.memory`) and wait for rollout — do not patch the deployment directly, the Istio gateway controller will revert it |
| Batch requests return 403 | User lacks RBAC on `llminferenceservices` | Create Role/RoleBinding for `get llminferenceservices/<isvc-name>` |
| Curl returns 000 (timeout) | External IP not routable from workstation | Port-forward: `kubectl port-forward svc/inference-gateway-istio -n redhat-ods-applications 8080:80` |
| TokenRateLimitPolicy not Enforced | No HTTPRoutes attached to target gateway | Create HTTPRoute first, policy enforces automatically |

## 8. Helm Install (Alternative)

This guide uses the **batch-gateway operator** on RHAIIS. For AKS deployments using open-source **Helm charts** instead (llm-d stack + batch-gateway Helm chart, without RHAIIS), follow [deploy-k8s.md](deploy-k8s.md).

Apply the AKS platform considerations in [§5](#5-aks-specific-considerations) when following the Helm guide — especially gateway networking (`istio-gateway-istio` in `istio-ingress`), file storage, and monitoring CRDs.

### Internal Load Balancer (Helm path)

```bash
kubectl annotate svc istio-gateway-istio -n istio-ingress \
  service.beta.kubernetes.io/azure-load-balancer-internal=true --overwrite
```

### File Storage (Helm path)

After creating the Azure Files PV/PVC in [§5 File Storage](#file-storage), install batch-gateway with:

```bash
helm upgrade --install batch-gateway ./charts/batch-gateway \
  --namespace batch-api \
  --set global.fileClient.type=fs \
  --set global.fileClient.fs.basePath=/tmp/batch-gateway \
  --set global.fileClient.fs.pvcName=batch-gateway-files \
  # ... remaining flags per deploy-k8s.md §3.7
```

### OCI Chart Registry

The published OCI chart is available at `oci://ghcr.io/llm-d-incubation/charts/batch-gateway`. Use this as an alternative to the local chart path when deploying without a source checkout:

```bash
helm upgrade --install batch-gateway \
  oci://ghcr.io/llm-d-incubation/charts/batch-gateway \
  --version 0.2.0 \
  --namespace batch-api \
  # ... same --set flags as deploy-k8s.md §3.7
```
