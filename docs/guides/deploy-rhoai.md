# Batch Gateway on Red Hat OpenShift AI (RHOAI)

This guide demonstrates how to deploy batch-gateway on OpenShift with RHOAI (Red Hat OpenShift AI), using Red Hat Connectivity Link (Kuadrant) for authentication, authorization, and rate limiting.

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
| `batch-api` | batch-gateway (apiserver + processor), Redis, PostgreSQL |
| `llm` | LLMInferenceService, model servers, InferencePool, EPP |

### 1.2 Data Flow

![RHOAI Deployment Architecture](diagrams/deploy-rhoai-arch.png)


**Batch inference flow**:
1. Client sends a batch request (e.g. `POST /v1/batches`) to the OpenShift Gateway (`openshift-ai-inference`) with a Kubernetes token
2. Gateway matches `/v1/batches`, `/v1/files` → **batch-route** (HTTPRoute)
    - **AuthPolicy** on the batch-route performs authentication only (kubernetesTokenReview, no authorization check) — unauthenticated requests are rejected with 401
    - **RateLimitPolicy** on the batch-route enforces per-user request rate limiting (e.g. 20 req/min), keyed by Kubernetes username (user or ServiceAccount) from TokenReview — excess requests are rejected with 429
    - Authenticated request is forwarded to **batch-gateway apiserver**, which stores the batch job
3. **Processor** dequeues the batch job and sends inference requests through a separate **Internal Gateway** (`batch-internal-gateway`) — a ClusterIP-only Gateway that is not externally accessible — with the user's original token
4. The Internal Gateway matches `/{ns}/{isvc}/v1/*` → **batch-llm-route** (HTTPRoute)
    - **AuthPolicy** on the batch-llm-route performs authentication and authorization (SubjectAccessReview — checks if the original user can `get llminferenceservices/<name>`) — if the user lacks permission, the request is rejected with 403
    - **No TokenRateLimitPolicy** — batch inference requests are exempt from per-user token rate limits
5. Request is routed to **InferencePool** → **EPP** (endpoint picker) → **vLLM** model server, and the response is returned to the Processor, which adds the response to the batch job's output file

### 1.3 Authentication

Both the LLM route and the batch route use **kubernetesTokenReview** for authentication. Clients provide a valid Kubernetes token via the `Authorization: Bearer <token>` header. The token must include the audience `https://kubernetes.default.svc`. Tokens are typically created from a ServiceAccount using `oc create token`.

- **LLM route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**
- **Batch route**: Requires a valid Kubernetes token — unauthenticated requests are rejected with **401**

### 1.4 Authorization Model

Model access is controlled through Kubernetes RBAC. Users need `get` permission on the specific `LLMInferenceService` resource to access a model. This is granted by creating a Role and RoleBinding in the model's namespace (see [Enabling authentication and authorization for LLM inference service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/latest/html/deploying_models/deploying_models#enabling-authentication-and-authorization-for-llm-inference-service_rhoai-user) for details).

- **LLM route**: SubjectAccessReview checks if user can `get llminferenceservices/<name>` — unauthorized requests are rejected with **403**
- **Batch route**: No authorization check — authorization is enforced by the batch-llm-route on the Internal Gateway when the processor forwards inference requests with the user's original token

### 1.5 Security boundary: batch-route vs batch-llm-route

For security and operations readers: **admission on the batch API is not the same as authorization for inference.**

- **batch-route** proves the caller has a valid Kubernetes token and applies batch-side **RateLimitPolicy**. Invalid or missing credentials are rejected with **401**; excess batch API traffic is rejected with **429**. It does **not** evaluate whether the caller may use a specific `LLMInferenceService`.
- **batch-llm-route** (on the Internal Gateway) runs **authentication and authorization** (SubjectAccessReview on `llminferenceservices` as above) on each inference request the processor sends. The Internal Gateway is ClusterIP-only — it has no external Route or Ingress, ensuring batch inference traffic stays cluster-internal. **No TokenRateLimitPolicy** is applied, so batch requests are exempt from per-user token rate limits. A user can create a batch job and still see **per-request failures** (often surfaced as failed lines or job errors) when the batch-llm-route returns **403** — this is **by design**, not a bypass of model access control.

The `Authorization` header is included in `passThroughHeaders` by default. Without it, the Internal Gateway cannot attribute inference traffic to the original caller and model-level checks cannot run as intended.

## 2. Prerequisites
- OpenShift cluster 4.20 or later (required for Distributed Inference with llm-d).
- OpenShift Service Mesh v2 is not installed in the cluster.
- CLI tools: `oc`, `helm`, `curl`, `jq`.


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

Follow [Red Hat Connectivity Link docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3) to install RHCL

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

Follow [deploy model doc](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/latest/html/deploying_models/deploying_models#deploying-models-using-distributed-inference_rhoai-user) to deploy model with LLM-D

For more examples: [kserve samples repo](https://github.com/red-hat-data-services/kserve/tree/main/docs/samples/llmisvc) (switch to the `rhoai-<version>` branch matching your RHOAI version for version-specific samples)

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
apiVersion: serving.kserve.io/v1alpha1
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
    scheduler: {}
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

### 3.7 Configure TokenRateLimitPolicy for LLMInferenceService

Configure per-user token rate limiting for inference requests. See [Red Hat Connectivity Link docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3) for details. The following is an example configuration.

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
    -n openshift-ingress --timeout=120s
```
</details>

### 3.8 Install Batch Gateway

The batch processor routes inference requests through a separate, ClusterIP-only Internal Gateway to bypass the TokenRateLimitPolicy on the external Gateway while still enforcing model-level authorization (AuthPolicy).

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
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: ${POOL_NAME}
EOF
```

> **Same path pattern**: The batch-llm-route uses the same `/{namespace}/{isvc-name}/v1/*` path pattern as the auto-generated LLM route on the external Gateway. This allows the processor to use the same URL format.

> **URL rewrite**: Each rule strips the `/{namespace}/{isvc-name}` prefix before forwarding to the InferencePool, matching the rewrite behavior of the auto-generated LLM route.

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

Deploy batch-gateway with the model gateway URL pointing to the Internal Gateway:

<details>
<summary>Create namespace and install dependencies</summary>

```bash
oc create namespace "${BATCH_NS}" 2>/dev/null || true
oc label namespace "${BATCH_NS}" llm-d.ai/gateway-route=true --overwrite

# Install Redis (or Valkey — see alternative below)
helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/redis \
    --namespace ${BATCH_NS} --create-namespace \
    --set architecture=standalone \
    --set auth.enabled=false
oc rollout status statefulset/redis-master -n ${BATCH_NS} --timeout=120s

# Alternative: Install Valkey (wire-protocol compatible with Redis)
# helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/valkey \
#     --namespace ${BATCH_NS} --create-namespace \
#     --set architecture=standalone \
#     --set auth.enabled=false
# oc rollout status statefulset/redis-valkey-primary -n ${BATCH_NS} --timeout=120s
# Note: when using Valkey, update the redis-url secret below to use:
#   redis://redis-valkey-primary.${BATCH_NS}.svc.cluster.local:6379/0

# Install PostgreSQL
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
    --from-literal=redis-url="redis://redis-master.${BATCH_NS}.svc.cluster.local:6379/0" \
    --from-literal=postgresql-url="postgresql://postgres:${PG_PASSWORD}@postgresql.${BATCH_NS}.svc.cluster.local:5432/batch?sslmode=disable" \
    --from-literal=s3-secret-access-key="${MINIO_PASSWORD}" \
    --dry-run=client -o yaml | oc apply -f -
```

> **Note**: Redis auth is disabled for demo purposes. For production, enable Redis authentication.

</details>

<details>
<summary>Install batch-gateway</summary>

```bash
IMAGE_TAG=odh-stable
APISERVER_REPO=quay.io/opendatahub/odh-llm-d-batch-gateway-apiserver
PROCESSOR_REPO=quay.io/opendatahub/odh-llm-d-batch-gateway-processor
GC_REPO=quay.io/opendatahub/odh-llm-d-batch-gateway-gc
```

```bash
# Get model URL from the Internal Gateway service
INTERNAL_GW_SVC=$(oc get svc -n openshift-ingress \
    -l "gateway.networking.k8s.io/gateway-name=batch-internal-gateway" \
    -o jsonpath='{.items[0].metadata.name}')
MODEL_URL="http://${INTERNAL_GW_SVC}.openshift-ingress.svc.cluster.local/${LLM_NS}/${ISVC_NAME}"

# Install batch-gateway
helm upgrade --install batch-gateway ./charts/batch-gateway \
    --namespace ${BATCH_NS} \
    --set "apiserver.image.repository=${APISERVER_REPO}" \
    --set "apiserver.image.tag=${IMAGE_TAG}" \
    --set "processor.image.repository=${PROCESSOR_REPO}" \
    --set "processor.image.tag=${IMAGE_TAG}" \
    --set "gc.image.repository=${GC_REPO}" \
    --set "gc.image.tag=${IMAGE_TAG}" \
    --set "global.secretName=batch-gateway-secrets" \
    --set "global.dbClient.type=postgresql" \
    --set "global.fileClient.type=s3" \
    --set "global.fileClient.s3.endpoint=http://minio.${BATCH_NS}.svc.cluster.local:9000" \
    --set "global.fileClient.s3.region=us-east-1" \
    --set "global.fileClient.s3.accessKeyId=${MINIO_USER}" \
    --set "global.fileClient.s3.prefix=${MINIO_BUCKET}" \
    --set "global.fileClient.s3.usePathStyle=true" \
    --set "global.fileClient.s3.autoCreateBucket=true" \
    --set "processor.config.modelGateways.${MODEL_NAME}.url=${MODEL_URL}" \
    --set "processor.config.modelGateways.${MODEL_NAME}.requestTimeout=5m" \
    --set "processor.config.modelGateways.${MODEL_NAME}.maxRetries=3" \
    --set "processor.config.modelGateways.${MODEL_NAME}.initialBackoff=1s" \
    --set "processor.config.modelGateways.${MODEL_NAME}.maxBackoff=60s" \
    --set apiserver.tls.enabled=true \
    --set apiserver.tls.certManager.enabled=true \
    --set apiserver.tls.certManager.issuerName=selfsigned-issuer \
    --set apiserver.tls.certManager.issuerKind=ClusterIssuer \
    --set "apiserver.tls.certManager.dnsNames={batch-gateway-apiserver,batch-gateway-apiserver.${BATCH_NS}.svc.cluster.local,localhost}"
```

> - **`modelGateways.<model>.url`**: The processor uses this URL to send inference requests. It points to the Internal Gateway's model endpoint (discovered from the Internal Gateway Service), not the external Gateway or the model server directly. The Internal Gateway enforces AuthPolicy (model access check) but not TokenRateLimitPolicy.
> - **`passThroughHeaders`**: Defaults to `[Authorization]`, so the processor forwards the end user's bearer token on inference calls without extra configuration. Override this only if you need a different set of headers.
>
> - **`apiserver.tls.certManager.*`**: Enables TLS for the batch API server using cert-manager. The `issuerName` must match a ClusterIssuer (e.g. `selfsigned-issuer`). The `dnsNames` should include the Service name and FQDN for TLS certificate generation. In this demo the DestinationRule (see 3.9) uses `insecureSkipVerify: true` because we use a self-signed certificate; in production, configure a trusted CA and set `insecureSkipVerify: false`.
> - **File storage**: This example uses S3-compatible storage (MinIO). To use a PVC instead, replace the `s3` options with:
>   ```
>   --set "global.fileClient.type=fs"
>   --set "global.fileClient.fs.basePath=/tmp/batch-gateway"
>   --set "global.fileClient.fs.pvcName=batch-gateway-files"
>   ```
>   and create a PVC with `ReadWriteMany` access mode. Note that `ReadWriteMany` requires a storage class that supports RWX (e.g. NFS, CephFS, EFS). Block storage (e.g. gp2, gp3) does not support RWX.

</details>


### 3.9 Configure HTTPRoute and Policies for Batch Gateway

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
