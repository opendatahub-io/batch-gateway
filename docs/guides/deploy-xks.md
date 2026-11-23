# Batch Gateway on XKS with RHAII

This guide demonstrates how to deploy batch-gateway on external Kubernetes services (Azure, CoreWeave) using the **batch-gateway operator** on top of [RHAII](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md), using [Kuadrant](https://kuadrant.io/) for authentication, authorization, and rate limiting.

> **Note**: The batch gateway does not depend on Kuadrant. This guide uses Kuadrant for gateway-level auth and rate limiting, but any policy engine that works with Gateway API can be used instead.

> **Note**: This guide is for XKS clusters **without** OpenShift. If you have OpenShift, see [deploy-rhoai.md](deploy-rhoai.md).

## 1. Architecture Overview

### 1.1 Data Flow

**Batch inference flow**:
1. Client sends a batch request (e.g. `POST /v1/batches`) to the inference Gateway (`inference-gateway`) with a Kubernetes token
2. Gateway matches `/v1/batches`, `/v1/files` → **batch-route** (HTTPRoute)
    - **AuthPolicy** on the batch-route performs authentication only (kubernetesTokenReview, no authorization check) — unauthenticated requests are rejected with 401
    - **RateLimitPolicy** on the batch-route enforces per-user request rate limiting (e.g. 20 req/min), keyed by Kubernetes username (user or ServiceAccount) from TokenReview — excess requests are rejected with 429
    - Authenticated request is forwarded to **batch-gateway apiserver**, which stores the batch job
3. **Processor** dequeues the batch job and submits inference requests to the PostgreSQL-backed SQL request queue. The `llm-d-async` processor dispatches them through a separate **Internal Gateway** (`batch-internal-gateway`) — a ClusterIP-only Gateway that is not externally accessible — with the user's original token.
4. The Internal Gateway matches `/{ns}/{isvc-name}/v1/*` → **batch-llm-route** (HTTPRoute)
    - **AuthPolicy** on the batch-llm-route performs authentication and authorization (SubjectAccessReview — checks if the original user can `get llminferenceservices/<name>`) — if the user lacks permission, the request is rejected with 403
    - **No TokenRateLimitPolicy** — batch inference requests are exempt from per-user token rate limits
5. Request is routed to **InferencePool** → **EPP** (endpoint picker) → **vLLM** model server. EPP and the async dispatch gate use **flow control** to prioritize interactive requests over batch requests (see [1.5 Flow Control](#15-flow-control)). The response returns through the PostgreSQL-backed SQL result queue, and the Processor adds it to the batch job's output file

### 1.2 Authentication

Both the LLM route and the batch route use **kubernetesTokenReview** for authentication. Clients provide a valid Kubernetes token via the `Authorization: Bearer <token>` header. The token must include the audience `https://kubernetes.default.svc`. Tokens are typically created from a ServiceAccount using `kubectl create token`.

- **LLM route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**
- **Batch route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**

### 1.3 Authorization Model

Model access is controlled through Kubernetes RBAC. Users need `get` permission on the specific `LLMInferenceService` resource to access a model. This is granted by creating a Role and RoleBinding in the model's namespace.

- **LLM route**: SubjectAccessReview checks if user can `get llminferenceservices/<name>` — unauthorized requests are rejected with **403**
- **Batch route**: No authorization check — authorization is enforced by the batch-llm-route on the Internal Gateway when the processor forwards inference requests with the user's original token

### 1.4 Security boundary: batch-route vs batch-llm-route

For security and operations readers: **admission on the batch API is not the same as authorization for inference.**

- **batch-route** proves the caller has a valid Kubernetes token and applies batch-side **RateLimitPolicy**. Invalid or missing credentials are rejected with **401**; excess batch API traffic is rejected with **429**. It does **not** evaluate whether the caller may use a specific `LLMInferenceService`.
- **batch-llm-route** (on the Internal Gateway) runs **authentication and authorization** (SubjectAccessReview on `llminferenceservices` as above) on each inference request the processor sends. The Internal Gateway is ClusterIP-only — it has no external Route or Ingress, ensuring batch inference traffic stays cluster-internal. **No TokenRateLimitPolicy** is applied, so batch requests are exempt from per-user token rate limits. A user can create a batch job and still see **per-request failures** (often surfaced as failed lines or job errors) when the batch-llm-route returns **403** — this is **by design**, not a bypass of model access control.

The `Authorization` header is included in `passThroughHeaders` by default. Without it, the Internal Gateway cannot attribute inference traffic to the original caller and model-level checks cannot run as intended.

### 1.5 Flow Control

Flow control ensures interactive inference requests are always served before batch requests. The EPP (Endpoint Picker Plugin) uses GIE's flow control feature to assign requests to priority bands based on the `x-gateway-inference-objective` header:

| Priority Band | Priority | Workload | Behavior Under Saturation |
|---------------|----------|----------|---------------------------|
| Interactive | 100 | Interactive requests | Dispatched first |
| Default | 0 | Requests without an objective header | Dispatched before batch |
| Batch | -1 (sheddable) | Batch requests | Shed immediately; processor retries with backoff |

When the backend is not saturated, both interactive and batch requests are dispatched freely. When saturation reaches 1.0, batch requests (priority -1) are shed at admission while interactive requests continue to be served.

This is configured through three components:

1. **EndpointPickerConfig** in the LLMInferenceService CR (`spec.router.scheduler.config.inline`) enables the `flowControl` feature gate and defines priority bands, fairness policies, and saturation detection thresholds.
2. **InferenceObjective resources** map objective names to priority levels. The batch processor sends the `x-gateway-inference-objective: batch-sheddable` header, which EPP resolves to priority -1.
3. **Batch processor `inferenceObjective` config** sets which `InferenceObjective` name is sent in the header on each inference request.

For full details on flow control configuration, see the [Flow Control Setup Guide](flow-control-setup.md).

## 2. Prerequisites

- XKS cluster (Kubernetes 1.28+) with GPU nodes (or CPU nodes for simulator testing)
- **RHAII installed with Batch Gateway enabled** — follow the [rhai-on-xks-chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md) to install or upgrade RHAII with the values below
- CLI tools: `kubectl`, `helm`, `curl`, `jq`
- Pull secret at `~/pull-secret.json` (for quay.io/rhoai and registry.redhat.io images)
- **CKS**: NVIDIA device plugin is pre-installed by CoreWeave. No additional GPU setup needed.

### Verify RHAII Installation

Before proceeding, confirm RHAII is healthy:

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

### Enable Batch Gateway in the RHAII xKS chart

Batch Gateway is managed by the AI Gateway operator on xKS. Add the following
to the values used to install or upgrade `rhai-on-xks-chart`:

```yaml
components:
  kserve:
    gateway:
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              llm-d.ai/gateway-route: "true"
  aigateway:
    enabled: true
    spec:
      batchGateway:
        managementState: Managed
```

Run the chart's normal `helm upgrade --install` command with these values and
the required `--set-file imagePullSecret.dockerConfigJson=/path/to/auth.json`
option. The chart configures the Batch Gateway operator's ServiceAccount to use
the release pull secret and the AI Gateway operator deploys the Batch Gateway
operator with the release's digest-pinned images.

> **Note**: `components.kserve.gateway.allowedRoutes.namespaces` is required by
> the chart — the install fails without it. The `llm-d.ai/gateway-route` label
> matches the namespaces labeled in [§3.2](#32-deploy-model-with-llminferenceservice)
> and [§3.5](#35-install-batch-gateway), and the chart-level `modelsAsAService`
> settings are not needed here because MaaS stays `Removed` (the default) for a
> Batch-Gateway-only install.

Do not install the Batch Gateway operator separately from the upstream
Kustomize overlay when using this chart. The chart manages its lifecycle and
image selection. You still need to copy `rhai-pull-secret` into each model
workload namespace as shown in [Deploy a simulated model with
LLMInferenceService](#32-deploy-model-with-llminferenceservice).

## 3. Installation Steps

### 3.0 Prepare Infrastructure


<details>
<summary>Patch inference-gateway to allow routes from labeled namespaces</summary>

By default, the RHAII inference-gateway only allows HTTPRoutes from `redhat-ods-applications` (`allowedRoutes.namespaces.from: Same`). Batch-gateway needs to attach routes from the `batch-api` namespace, and model workloads live in the `llm` namespace. Fresh installs using the values above create the gateway with a label selector already; if your gateway already exists with `from: Same`, patch it to restrict attachment to explicitly labeled namespaces only:

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
```

> The `llm` and `batch-api` namespaces are labeled with `llm-d.ai/gateway-route=true` later when they are created (steps 3.2 and 3.5 respectively).


> **Security**: Only namespaces with the `llm-d.ai/gateway-route: "true"` label can attach HTTPRoutes to the inference-gateway. On RHOAI (OpenShift), this patch is not needed because all batch-gateway HTTPRoutes are deployed in the same namespace as the gateway.

> **Note**: If the RHAII cloud-manager reconciles the gateway back to `Same`, you may need to disable gateway management or use a separate gateway for batch traffic.

</details>

### 3.1 Install Kuadrant (Optional)

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

<details>
<summary>CKS alternative: Install RHCL via rhaii-on-xks helmfile</summary>

On CKS, Kuadrant is installed as RHCL (Red Hat Connectivity Link) via the rhaii-on-xks helmfile:

```bash
cd ~/redhat/rhaii-on-xks
make deploy-rhcl
```

</details>

### 3.2 Deploy model with LLMInferenceService

Follow the [RHAII on xKS deployment guide](https://github.com/opendatahub-io/rhaii-on-xks/blob/main/docs/deploying-rhaii-helmcharts-on-xks-ea2.md) to deploy a model, or use the simulated model below for testing.

The following example deploys a simulated model with `LLMInferenceService`.

<details>
<summary>Deploy a simulated model with LLMInferenceService</summary>

```bash
LLM_NS=llm   # any user-defined namespace; label it llm-d.ai/gateway-route=true below
RHAII_NS=redhat-ods-applications
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

kubectl create namespace "${LLM_NS}" 2>/dev/null || true
kubectl label namespace "${LLM_NS}" llm-d.ai/gateway-route=true --overwrite

# RHAII creates rhai-pull-secret in ${RHAII_NS}. Copy it into ${LLM_NS} so the
# storage-initializer init container (triggered by hf:// model URIs) and workload
# pods can pull quay.io/rhoai images.
kubectl create secret generic rhai-pull-secret \
  --namespace="${LLM_NS}" \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(
    kubectl get secret rhai-pull-secret -n "${RHAII_NS}" \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
  )" \
  --dry-run=client -o yaml | kubectl apply -f -

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
    uri: hf://facebook/opt-125m
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

> **Pull secret**: The `hf://` model URI triggers a `storage-initializer` init container that pulls `quay.io/rhoai/odh-kserve-storage-initializer-rhel9`. Copy `rhai-pull-secret` into `${LLM_NS}` before applying the CR (run the full §3.2 block in one shell so `RHAII_NS` and `LLM_NS` are set). Without it, pods fail with `Init:ImagePullBackOff` / `401 UNAUTHORIZED`.

> **Flow control config**: The `scheduler.config.inline` EndpointPickerConfig enables the `flowControl` feature gate with two priority bands: interactive (priority 100, round-robin fairness, FCFS ordering) and batch (priority -1, sheddable, SLO-deadline ordering). The `saturationDetector` monitors backend queue depth and KV-cache utilization to trigger head-of-line blocking when the system is saturated. See [1.5 Flow Control](#15-flow-control) for details.

</details>

<details>
<summary>Check LLMInferenceService deployment</summary>

> **Note**: The `LLMInferenceService` CRD automatically creates the model server Deployment, InferencePool, EPP, and HTTPRoute.

```bash
kubectl get all -n ${LLM_NS}
kubectl get httproute -n ${LLM_NS}
```

</details>

### 3.3 Create InferenceObjective Resources

Create `InferenceObjective` resources that map the `x-gateway-inference-objective` header value to a priority band in EPP's flow control. The batch processor sends the `batch-sheddable` objective on each inference request.

<details>
<summary>Create InferenceObjective resources</summary>

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

### 3.4 Configure AuthPolicy and TokenRateLimitPolicy for inference-gateway (Optional — requires Kuadrant)

Apply authentication, authorization, and token rate limiting for direct inference requests via the inference-gateway.

> **Rate limiting identity**: Authorino rules use `auth.identity.user.username`, but Kuadrant's wasm-shim rate limit counters use a flattened path (`auth.identity.username`). Each AuthPolicy that backs a RateLimitPolicy or TokenRateLimitPolicy must expose identity via a `response.success.filters.identity` block (below).

<details>
<summary>Apply AuthPolicy on inference-gateway</summary>

> **Note**: The AuthPolicy targets the inference Gateway (not HTTPRoute) because LLMInferenceService dynamically generates the HTTPRoute name.

```bash
RHAII_NS=redhat-ods-applications

kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: inference-gateway-auth
  namespace: ${RHAII_NS}
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
    response:
      success:
        filters:
          identity:
            json:
              properties:
                username:
                  selector: auth.identity.user.username
EOF

kubectl wait authpolicy/inference-gateway-auth \
    --for="condition=Enforced=true" \
    -n ${RHAII_NS} --timeout=180s
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
  namespace: ${RHAII_NS}
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
      - expression: auth.identity.username
EOF

# Wait for policy to be enforced
kubectl wait tokenratelimitpolicy/inference-token-limit \
    --for="condition=Enforced=true" \
    -n ${RHAII_NS} --timeout=180s
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
RHAII_NS=redhat-ods-applications
```

<details>
<summary>Verify the chart-managed batch-gateway operator</summary>

After enabling `components.aigateway.spec.batchGateway.managementState: Managed`
in the RHAII xKS chart, wait for the AI Gateway operator to deploy the Batch
Gateway operator:

```bash
kubectl rollout status deploy/llm-d-batch-gateway-operator \
  -n redhat-ods-applications --timeout=120s
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
# Create a parametersRef ConfigMap to mount the RHAII CA bundle on the gateway's Envoy.
# This is needed because model workloads use TLS and the DestinationRule references
# /var/run/secrets/rhai/ca.crt for certificate validation.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: batch-internal-gateway-config
  namespace: ${RHAII_NS}
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
  namespace: ${RHAII_NS}
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
    -n ${RHAII_NS} gateway/batch-internal-gateway
```

> **Key annotation**: `networking.istio.io/service-type: ClusterIP` forces the Gateway's Service to be ClusterIP instead of LoadBalancer, ensuring it is not externally accessible.

> **parametersRef**: The ConfigMap mounts the RHAII CA bundle (`rhai-ca-bundle`) into the gateway's Envoy proxy at `/var/run/secrets/rhai/ca.crt`. This is required because model workload services use TLS and the existing DestinationRule references this CA path for certificate validation.

> **HTTP only**: The Internal Gateway uses HTTP (port 80) with no TLS listener. Since traffic is cluster-internal (processor → Internal Gateway → InferencePool), TLS to the model workload is handled by the Istio DestinationRule (originating TLS to the backend using the RHAII CA bundle).

</details>

<details>
<summary>Create batch-llm-route (HTTPRoute on Internal Gateway)</summary>

```bash
# Discover the InferencePool owned by the LLMInferenceService
POOL_NAME=$(kubectl get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-llm-route
  namespace: ${LLM_NS}
spec:
  parentRefs:
  - name: batch-internal-gateway
    namespace: ${RHAII_NS}
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
    - group: inference.networking.x-k8s.io
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
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
EOF
```

> **Same path pattern**: The batch-llm-route uses the same `/{namespace}/{isvc-name}/v1/*` path pattern as the auto-generated LLM route on the external Gateway. This allows the processor to use the same URL format.

> **URL rewrite**: Each rule strips the `/{namespace}/{isvc-name}` prefix before forwarding to the InferencePool, matching the rewrite behavior of the auto-generated LLM route. Istio injects the `ext_proc` filter when it sees InferencePool backendRefs, so EPP flow control applies to batch traffic the same way as interactive traffic.

</details>

<details>
<summary>Apply AuthPolicy for batch-llm-route (Optional — requires Kuadrant)</summary>

> **Requires Kuadrant**: Skip this block if Kuadrant is not installed.

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
<summary>Create namespace</summary>

```bash
kubectl create namespace "${BATCH_NS}" 2>/dev/null || true
kubectl label namespace "${BATCH_NS}" llm-d.ai/gateway-route=true --overwrite
```

</details>

> **Note**: This SQL-transport example requires PostgreSQL and S3-compatible object storage. Redis/Valkey remains supported as an alternative async transport; if you select it, configure `asyncConfig.redis` and add the `redis-url` Secret key instead.
>
> **Development-only PostgreSQL:** The Bitnami example below does not configure PostgreSQL TLS and uses `sslmode=disable` for an in-cluster smoke test. Production deployments must use customer-managed PostgreSQL with TLS, protected credentials, backups, persistence, and HA. Replace the URL with the provider's TLS-verified connection string; do not copy `sslmode=disable`. The operator CR does not configure a database CA, so use the PostgreSQL client's supported trust mechanism.

<details>
<summary>Install development PostgreSQL</summary>

```bash
PG_PASSWORD="<your-password>"   # set once, referenced below
helm upgrade --install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
    --namespace ${BATCH_NS} --create-namespace \
    --version 18.7.12 \
    --set "auth.postgresPassword=${PG_PASSWORD}" \
    --set auth.database=batch
kubectl rollout status statefulset/postgresql -n ${BATCH_NS} --timeout=120s
```

</details>

<details>
<summary>Install MinIO (S3-compatible object storage)</summary>

```bash
MINIO_USER="<your-minio-user>"
MINIO_PASSWORD="<your-minio-password>"
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
```

> **Demo only**: MinIO uses `emptyDir` — data is lost on pod restart. For production, use a PVC with `ReadWriteMany` or a managed S3-compatible service.

</details>

<details>
<summary>Create application secret</summary>

```bash
kubectl create secret generic batch-gateway-secrets \
    --namespace ${BATCH_NS} \
    --from-literal=postgresql-url="postgresql://postgres:${PG_PASSWORD}@postgresql.${BATCH_NS}.svc.cluster.local:5432/batch?sslmode=disable" \
    --from-literal=s3-secret-access-key="${MINIO_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

> Update the connection URLs above if you are using existing PostgreSQL or S3 services.

</details>

#### 3.5.1 Async dispatch

The operator deploys `llm-d-async` alongside the batch-gateway processor. The batch processor writes requests to PostgreSQL and the async processor releases them to the Internal Gateway according to the configured dispatch gate.

This example uses the `prometheus-budget` gate. Prometheus must be available in the model namespace and must scrape the EPP and model-server metrics. The model-server scrape adds the `inference_pool` label because the model server does not emit it natively.

Set the model pool and Prometheus endpoint before creating the resource. The
endpoint must be reachable from the async processor and expose the EPP and
model-server metrics required by the `prometheus-budget` gate:

```bash
POOL_NAME=$(kubectl get inferencepool -n ${LLM_NS} -o json | \
    jq -r --arg owner "${ISVC_NAME}" \
    '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' | head -1)
INTERNAL_GW_SVC=$(kubectl get svc -n ${RHAII_NS} \
    -l "gateway.networking.k8s.io/gateway-name=batch-internal-gateway" \
    -o jsonpath='{.items[0].metadata.name}')
MODEL_URL="http://${INTERNAL_GW_SVC}.${RHAII_NS}.svc.cluster.local/${LLM_NS}/${ISVC_NAME}"
: "${PROMETHEUS_URL:?Set PROMETHEUS_URL to your Prometheus query endpoint}"
```

For a minimal Prometheus deployment and scrape configuration, see the Prometheus section in the [RHOAI async deployment example](deploy-rhoai.md#3102-option-2-async-dispatch). For AKS and CoreWeave, use the actual endpoint created by the selected Prometheus installation and configure its required authentication and CA trust. Managed Prometheus may require an authenticated in-cluster proxy or equivalent endpoint. The `LLMBatchGateway` example accepts the query URL; provider-specific authentication and CA configuration must be provided by the Prometheus deployment or proxy.

Create an async `LLMBatchGateway` resource:

```bash
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
    modelGateways:
      "${MODEL_NAME}":
        inferencePoolName: "${POOL_NAME}"
        inferenceObjective: batch-sheddable
    asyncConfig:
      replicas: 1
      concurrency: 8
      drainTimeout: 2m
      resultPollTimeout: 30s
      inferenceGateway:
        url: "${MODEL_URL}"
      prometheusURL: "${PROMETHEUS_URL}"
      prometheusCacheTTL: "0s"
      sql:
        maxConnections: 8
        pollIntervalMs: 500
        batchSize: 10
        queuesConfig:
        - name: "llm-d-async:requests:${POOL_NAME}"
          workerPoolID: default-workers
          requestPathURL: /v1/chat/completions
          gateType: prometheus-budget
          gateParams:
            pool: "${POOL_NAME}"
            namespace: "${LLM_NS}"
            max_concurrency: "100"
            baseline: "0.05"
            fallback: "1.0"
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
      issuerName: opendatahub-selfsigned-issuer
      issuerKind: ClusterIssuer
      dnsNames:
      - batch-gateway-apiserver
      - batch-gateway-apiserver.${BATCH_NS}.svc.cluster.local
      - localhost
EOF

kubectl wait llmbatchgateway/batch-gateway -n ${BATCH_NS} \
    --for=condition=Ready --timeout=300s
```

Async-specific configuration:

- `modelGateways.<model>.inferencePoolName` identifies the target InferencePool.
- `asyncConfig.sql.queuesConfig` must name the request queue consumed by the async processor.
- `asyncConfig.inferenceGateway.url` points to the ClusterIP-only Internal Gateway.
- `prometheus-budget` controls dispatch based on available inference capacity.
- `workerPools` limits async processor concurrency.

The operator deploys the async processor automatically. Do not install a second async processor manually for this `LLMBatchGateway` resource.

### 3.6 Configure HTTPRoute and Policies for Batch Gateway

Set the variable used throughout this section (re-set if starting a new shell):
```bash
BATCH_NS=batch-api
RHAII_NS=redhat-ods-applications
```

Create the batch route, and optionally the authentication policy and rate limit (requires Kuadrant):

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
    namespace: ${RHAII_NS}
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
  namespace: ${RHAII_NS}
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
<summary>Create AuthPolicy for Batch API Server (Optional — requires Kuadrant)</summary>

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
    response:
      success:
        filters:
          identity:
            json:
              properties:
                username:
                  selector: auth.identity.user.username
EOF
```

</details>

<details>
<summary>Create RateLimitPolicy for Batch API Server (Optional — requires Kuadrant)</summary>

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
      - expression: auth.identity.username
EOF
```

</details>

> **CKS gotcha**: EPP pods may crash with "failed waiting for InferenceModelRewrite Informer to sync". This is an RBAC gap — the EPP ServiceAccount lacks `llm-d.ai` API group permissions. Fix per LLMInferenceService:

```bash
kubectl apply -n ${LLM_NS} -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: epp-llmd-fix
rules:
- apiGroups: ["llm-d.ai"]
  resources: ["inferencemodelrewrites", "inferenceobjectives"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: epp-llmd-fix
subjects:
- kind: ServiceAccount
  name: ${ISVC_NAME}-epp-sa
roleRef:
  kind: Role
  name: epp-llmd-fix
  apiGroup: rbac.authorization.k8s.io
EOF
```

## 4. Test

Set the variables used throughout this section (these were defined during installation — re-set them if starting a new shell):
```bash
LLM_NS=llm   # any user-defined namespace
BATCH_NS=batch-api
MODEL_NAME="facebook/opt-125m"
ISVC_NAME=$(echo "${MODEL_NAME}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
RHAII_NS=redhat-ods-applications
```

### 4.1 Setup Test Accounts

```bash
# Get Gateway address
GW_ADDR=$(kubectl get gateway inference-gateway -n ${RHAII_NS} \
    -o jsonpath='{.status.addresses[0].value}')
GW_URL="https://${GW_ADDR}"

# If the gateway IP is not reachable externally, use port-forward:
# kubectl port-forward svc/inference-gateway-istio -n ${RHAII_NS} 8443:443 &
# GW_URL="https://localhost:8443"

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

### 4.2 LLM Authentication (Requires Kuadrant)

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

### 4.3 LLM Authorization (Requires Kuadrant)

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

### 4.4 LLM Token Rate Limit (Requires Kuadrant)

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

### 4.5 Batch Authentication (Requires Kuadrant)

```bash
# Unauthenticated -> 401
curl -sk -o /dev/null -w "%{http_code}\n" ${GW_URL}/v1/batches

# Authenticated -> 200
curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" ${GW_URL}/v1/batches
```

### 4.6 Batch Authorization (batch-llm-route enforcement) (Requires Kuadrant)

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

### 4.8 Batch Request Rate Limit (Requires Kuadrant)

```bash
# Send 25 rapid requests — expect 429 after 20 (rate limit: 20 req/min)
for i in $(seq 1 25); do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${AUTH_TOKEN}" ${GW_URL}/v1/batches)
    echo "Request $i: $http_code"
done
```

## 5. Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `istio-system` | Istio control plane (istiod) — installed by RHAII |
| `redhat-ods-applications` | KServe, inference-gateway, RHAII controllers, and batch-gateway-operator — installed by RHAII |
| `llm` (example; any user-defined namespace) | LLMInferenceService, model servers, InferencePool, EPP, InferenceObjective resources |
| `redhat-ods-operator` | RHAI operator — installed by RHAII |
| `cert-manager` | cert-manager — installed by RHAII |
| `kuadrant-system` | Kuadrant operator, Authorino, Limitador |
| `batch-api` | batch-gateway (apiserver + processor + async-processor + gc), PostgreSQL |

## 6. Platform-Specific Considerations

### AKS

This section documents AKS platform differences.

### Gateway Networking

Gateway Services on AKS provision an Azure Load Balancer. For internal-only clusters, annotate the relevant Service:

```bash
kubectl annotate svc inference-gateway-istio -n ${RHAII_NS} \
  service.beta.kubernetes.io/azure-load-balancer-internal=true --overwrite
```

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

5. Configure batch-gateway to use the PVC by updating the `LLMBatchGateway` CR:

```yaml
spec:
  fileStorage:
    fs:
      basePath: /tmp/batch-gateway
      claimName: batch-gateway-files
```

### Monitoring CRDs

AKS clusters do not ship the Prometheus Operator CRDs by default. If any component creates `PodMonitor` or `ServiceMonitor` resources, install the CRDs.

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

**Option C — Enable managed Prometheus** (cloud provider monitoring):

Enable [Azure Monitor managed service for Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview) on the cluster. This supports PodMonitor/ServiceMonitor CRDs natively.

### AKS Known Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| GC pod reports `0/1 Ready` (v0.1.0 only) | Startup probe misconfiguration; fixed in later versions | Upgrade to v0.2.0+, or ignore — no functional impact |
| `azurefile-csi` / `azurefile-csi-premium` PVC provisioning fails | Subscription policy requires HTTPS-only storage accounts; CSI driver creates accounts without HTTPS | Pre-create storage account with `--https-only true` (see File Storage Option B above) |
| `Microsoft.Storage` provider not registered | `az storage account create` returns `SubscriptionNotFound` | Run `az provider register --namespace Microsoft.Storage` and wait for `Registered` state |

### CKS (CoreWeave)

- **Storage**: CoreWeave provides `shared-vast` with ReadWriteMany — no Azure Files setup needed for filesystem storage mode
- **NVIDIA device plugin**: Pre-installed by CoreWeave, no additional GPU setup
- **PKI naming**: The RHAII helmfile creates certificates with `opendatahub-*` names, while the rhai-on-xks-chart expects `rhai-*` names. On shared clusters, you may need both sets of PKI resources
- **Monitoring CRDs**: CKS clusters do not ship Prometheus Operator CRDs by default. If components fail on missing PodMonitor/ServiceMonitor resources:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.80.0/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.80.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
```

## 7. Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| RHAII pods `ImagePullBackOff` | Pull secret missing registry credentials | Check `~/pull-secret.json` covers all registries (see [rhai-on-xks-chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md)) |
| Model pods `Init:ImagePullBackOff` in `llm` | `rhai-pull-secret` not copied into model namespace | Copy secret from `redhat-ods-applications` before applying the CR (see [§3.2](#32-deploy-model-with-llminferenceservice)); delete pods to retry |
| `inference-gateway` not Programmed | Istio not ready | `kubectl get pods -n istio-system` and check Sail Operator |
| `LLMInferenceService` stuck | Controller not ready or missing CRDs | `kubectl logs -n redhat-ods-applications -l app=llmisvc-controller-manager` |
| `LLMBatchGateway` CR not accepted | CRD not installed | `kubectl get pods -n redhat-ods-applications -l app.kubernetes.io/name=llm-d-batch-gateway-operator`; verify operator is running |
| Gateway unreachable externally | Internal LB or cloud security group rules | Use `kubectl port-forward` or allowlist your IP |
| Gateway unreachable from client | Internal LB; client outside VNet | Access from within the VNet or use an in-cluster test pod |
| Pods `Pending` on PVC | Dynamic provisioning failed (HTTPS policy or wrong storage class) | Use pre-created storage account ([§6 File Storage](#file-storage) Option B) or MinIO/S3 (Option A) |
| PVC mount fails with `No such file or directory` | File share does not exist in the storage account | Create it with `az storage share-rm create --resource-group <rg> --storage-account <name> --name batch-gateway` |
| PVC mount fails | Block storage doesn't support RWX | Use MinIO/S3 (recommended) or cloud-provider shared file storage with pre-created storage account |
| File upload returns S3 error | `s3-secret-access-key` does not match `MINIO_ROOT_PASSWORD` | Recreate the `batch-gateway-secrets` secret with matching credentials |
| Pods `CrashLoopBackOff` with URL parse error | Special characters in `postgresql-url` | URL-encode the password in the connection string |
| `inference-gateway-istio` OOMKilled | Kuadrant wasm plugin exceeds default 1Gi memory | Increase memory to 2Gi in the `inference-gateway-config` ConfigMap (`data.deployment` → `containers[].resources.limits.memory`) and wait for rollout — do not patch the deployment directly, the Istio gateway controller will revert it |
| Batch requests return 403 | User lacks RBAC on `llminferenceservices` | Create Role/RoleBinding for `get llminferenceservices/<isvc-name>` |
| Curl returns 000 (timeout) | External IP not routable from workstation | Port-forward: `kubectl port-forward svc/inference-gateway-istio -n redhat-ods-applications 8443:443` |
| TokenRateLimitPolicy not Enforced | No HTTPRoutes attached to target gateway | Create HTTPRoute first, policy enforces automatically |
| RateLimitPolicy `Enforced=True` but no 429 | Wasm-shim cannot resolve `auth.identity` for rate limit counters (check gateway logs for `NoSuchKey("identity")`); ratelimit `failureMode: allow` passes traffic through | Add `response.success.filters.identity` to the AuthPolicy (see [§3.4](#34-configure-authpolicy-and-tokenratelimitpolicy-for-inference-gateway-optional--requires-kuadrant)) and use `auth.identity.username` (not `auth.identity.user.username`) in RateLimitPolicy/TokenRateLimitPolicy counters |
| EPP pods CrashLoopBackOff | Missing `llm-d.ai` RBAC (CKS) | Apply Role/RoleBinding fix (see after step 3.6) |
| CRD field manager conflict | Pre-existing CRDs on shared cluster | `kubectl apply --server-side --force-conflicts` |
