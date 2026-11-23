# MaaS Integration

This guide walks through deploying batch-gateway on the [MaaS (Models-as-a-Service)][MaaS] platform with authentication, request rate limiting, and token rate limiting.

batch-gateway is deployed by the [batch-gateway-operator] via the **LLMBatchGateway** custom resource — no manual Helm install of the batch-gateway chart is required. The operator renders the same chart from the CR and keeps the workloads reconciled.

This guide focuses on the MaaS integration: exposing the batch API through the MaaS gateway, API-key authentication, policies, and credential pass-through to models.

[MaaS]: https://github.com/opendatahub-io/models-as-a-service
[batch-gateway-operator]: https://github.com/opendatahub-io/llm-d-batch-gateway-operator
[models-as-a-service]: https://github.com/opendatahub-io/models-as-a-service

## Prerequisites

- OpenShift cluster (self-managed)
- [oc]
- [kubectl]
- [Helm]
- [kustomize]
- [jq]
- `htpasswd` (from `httpd-tools` or `apache2-utils`)
- Cluster admin access

[oc]: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html
[kubectl]: https://kubernetes.io/docs/tasks/tools/
[Helm]: https://helm.sh
[kustomize]: https://kustomize.io
[jq]: https://jqlang.github.io/jq/

## Architecture

![MaaS Integration Architecture](diagrams/maas-integration-arch.png)

MaaS provides the gateway, Istio, Kuadrant, cert-manager, and model serving infrastructure. On top of that:

- The **batch-gateway-operator** (an ODH/RHOAI AI Gateway sub-component) reconciles the **LLMBatchGateway** CR and deploys the API server, processor, async-processor, and garbage collector, plus the TLS certificate and the Gateway API HTTPRoute.
- Inference requests are dispatched asynchronously through PostgreSQL-backed SQL dispatch queues (`spec.processor.asyncConfig.sql`); the **async-processor** calls models through the MaaS gateway using HTTPS, forwarding the original user's credentials.

Because PostgreSQL already backs batch job state, the SQL transport keeps the deployment to a single stateful dependency — no Redis is required.

All authentication uses **MaaS API keys** (`sk-oai-*`). Users create API keys via the MaaS API using their OpenShift token, then use API keys for both batch API and model inference requests.

## 1. Install MaaS Platform and the Batch Gateway Operator

Install MaaS following the [MaaS installation guide](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md) (see also the repository's [quickstart](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/quickstart.md)): install the ODH/RHOAI operator, create the `maas-db-config` Secret, create the `maas-default-gateway` Gateway, then enable MaaS in your DataScienceCluster. The install path and the Gateway's route selector are release-specific — always follow the installation guide for your platform release. For the Gateway created by `scripts/setup-gateway.sh`, the namespaces allowed to attach HTTPRoutes are controlled by `NAMESPACE_SELECTOR_LABELS` (see [section 4.5](#45-httproute--created-by-the-operator)).

The batch-gateway-operator is deployed by the same `aigateway` component, so enable both sub-components in one DataScienceCluster:

```bash
$ kubectl apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v3
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    aigateway:
      managementState: Managed
      modelsAsAService:
        managementState: Managed
      batchGateway:
        managementState: Managed
EOF
```

> **Note — DSC API version**: this guide targets RHOAI 3.6 / the 3.6 batch-gateway-operator chart, which serves `datasciencecluster.opendatahub.io/v3`. Earlier ODH releases serve `v2`. Use the version served by the installed CRD as the source of truth:
>
> ```bash
> $ kubectl api-versions | grep datasciencecluster.opendatahub.io
> datasciencecluster.opendatahub.io/v3
> ```

Verify the operators and MaaS are running (on RHOAI the applications land in `redhat-ods-applications`; on ODH in `opendatahub`):

```bash
$ kubectl get deploy -n redhat-ods-applications | grep -E "maas|batch-gateway"
maas-controller                             1/1     1            1           5m
maas-ui                                     1/1     1            1           5m
llm-d-batch-gateway-operator                1/1     1            1           4m

$ kubectl get deploy,svc -n redhat-ai-gateway-infra | grep maas-api
deployment.apps/maas-api                    1/1     1            1           5m
service/maas-api                            ClusterIP   172.30.113.208   <none>   8443/TCP
```

> **Note — maas-api namespace**: the namespace of the `maas-api` Service is needed for the AuthPolicy in [section 5.2](#52-batch-authpolicy). It depends on the install model: `redhat-ai-gateway-infra` (RHOAI, DSC-managed, infrastructure namespace separation), `odh-ai-gateway-infra` (ODH with namespace separation), or `opendatahub` (ODH `deploy.sh`). Discover it with:
>
> ```bash
> $ MAAS_API_NS=$(kubectl get deploy -A -o json | jq -r '.items[] | select(.metadata.name=="maas-api").metadata.namespace')
> $ echo "${MAAS_API_NS}"
> redhat-ai-gateway-infra
> ```

> **Note — upstream MaaS repo**: on a cluster without the ODH/RHOAI operator you can install MaaS with `./scripts/deploy.sh` from the [models-as-a-service] repo. The remainder of this guide is identical either way.

Earlier versions of this guide required a manual RBAC patch (`maas-api-extra` ClusterRole) so maas-api could read the MaaS controller CRDs. This is no longer needed: the rules now ship in the MaaS repo (`deployment/base/maas-api/rbac/`) and are deployed with the maas-api workload by the maas-controller. Two ClusterRoles are bound to the `maas-api` ServiceAccount:

- `maas-api` — the main role, reconciled by the operator. Grants `get/list/watch` on `maassubscriptions`, `maasmodelrefs`, `maasauthpolicies` (plus `aitenants`, `maastenantconfigs`, `aiguardrails` in newer snapshots).
- `maas-api-supplemental` — not managed by the operator, so its rules persist across reconciliation cycles; it mirrors runtime permissions the operator's bundled manifests may not yet include.

The old patch's other grants are deliberately absent and not needed: maas-api only reads the `maas-db-config` Secret in its own namespace (granted by name), and nothing in maas-api uses the `services.opendatahub.io` `auths` resource.

Create a self-signed ClusterIssuer for batch-gateway TLS certificates (MaaS installs the cert-manager operator but does not create a ClusterIssuer):

```bash
$ kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

Verify the gateway is ready:

```bash
$ kubectl get gateway maas-default-gateway -n openshift-ingress
NAME                  CLASS              ADDRESS                                                                   PROGRAMMED
maas-default-gateway  openshift-default  a21489c11403d41af85eacc10d35ba35-1844165445.us-east-1.elb.amazonaws.com   True
```

## 2. Create Test User

Create the test user and group **before** deploying model policies (MaaSAuthPolicy references the group).

> **Note**: `oc patch oauth cluster --type=merge` with `spec.identityProviders` **replaces** the whole identity provider list. On clusters that already have identity providers, append the new provider to the existing list instead of replacing it.

```bash
# Create htpasswd user
$ htpasswd -cbB /tmp/htpasswd testuser testpass
$ oc create secret generic htpass-secret \
    --from-file=htpasswd=/tmp/htpasswd \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -

# Add htpasswd identity provider
$ oc patch oauth cluster --type=merge -p '
spec:
  identityProviders:
  - name: htpasswd
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret'

# Wait for OAuth restart
$ sleep 30

# Create group and add user
$ oc adm groups new tier-free-users
$ oc adm groups add-users tier-free-users testuser
```

## 3. Deploy a Sample Model

Clone the [models-as-a-service] repository — the sample manifests and the `setup-gateway.sh` script used later in this guide come from it:

```bash
$ git clone https://github.com/opendatahub-io/models-as-a-service.git /tmp/maas
```

Deploy the simulator-based LLMInferenceService:

```bash
$ kubectl create namespace llm
$ kustomize build /tmp/maas/docs/samples/models/simulator | kubectl apply -f -
```

Wait for the model to be ready. The model's router creates an `InferencePool` named `<model>-inference-pool`, which the LLMBatchGateway CR references in [section 4.3](#43-create-the-llmbatchgateway-cr):

```bash
$ kubectl rollout status deploy/facebook-opt-125m-simulated-kserve -n llm --timeout=300s
$ oc wait llminferenceservice/facebook-opt-125m-simulated -n llm \
    --for=condition=Ready --timeout=300s

$ kubectl get inferencepool -n llm
NAME                                      AGE
facebook-opt-125m-simulated-inference-pool   30s
```

## 4. Deploy Batch Gateway

### 4.1 Create Namespace and Databases

**The LLMBatchGateway operator does not provision or manage PostgreSQL.** PostgreSQL is a customer-managed external dependency, backing both batch job state and — with the SQL transport used in this guide — the async request/result queues.

- **Production**: bring your own PostgreSQL service (managed instance or in-cluster database you operate) with persistence, backups, credential protection, TLS, and HA managed outside this guide, and provide its connection URL through the `postgresql-url` key of the credentials Secret below. Never use the example credentials.
- **Development only**: the Bitnami Helm install below is a disposable development convenience for trying this guide on a test cluster. It embeds the weak `postgres:postgres` credential and disables persistence — do **not** use it as the production path, and never commit real credentials to the manifests.

```bash
$ kubectl create namespace batch-api

# DEVELOPMENT ONLY — disposable, non-persistent, weak credentials
$ helm repo add bitnami https://charts.bitnami.com/bitnami
$ helm install postgresql bitnami/postgresql -n batch-api \
    --set auth.postgresPassword=postgres \
    --set primary.persistence.enabled=false \
    --wait --timeout 120s
```

> **Note — Redis transport**: `asyncConfig.redis` (Redis/Valkey sorted sets) is still supported and selects the `redis-sortedset` transport. Only then is a Redis instance required and `redis-url` must be added to the credentials Secret.

### 4.2 Create Secret and PVC

The credentials Secret is referenced by `spec.secretRef`. Required keys:

- `postgresql-url` — PostgreSQL connection URL, used for job state **and** the SQL dispatch queues (the async-processor reads the same key)
- `maas-gateway-ca` — (this guide) CA certificate that signed the MaaS gateway's TLS certificate, used by the async-processor for inference calls

`redis-url` is only required when using the `redis-sortedset` transport; it is omitted here.

The async-processor calls models through the MaaS gateway over HTTPS. The gateway's listener certificate is signed by the cluster's internal ingress CA, so the async-processor needs that CA to verify it — this guide mounts the CA and verifies the chain, leaving `insecureSkipVerify` unset. The API accepts `asyncConfig.tls.insecureSkipVerify` (it is not rejected by CRD validation); production policy must prohibit disabling certificate verification. Extract the CA from the certificate chain referenced by the Gateway:

```bash
# Certificate secret used by the MaaS gateway listener
$ GW_CERT_SECRET=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}')

# tls.crt holds the chain <leaf><CA>; keep the last certificate (the CA)
$ kubectl get secret "${GW_CERT_SECRET}" -n openshift-ingress \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/maas-gw-chain.pem
$ awk '/BEGIN CERTIFICATE/{i++} {print > ("/tmp/maas-gw-ca-" i ".pem")}' /tmp/maas-gw-chain.pem
$ MAAS_GW_CA=$(ls /tmp/maas-gw-ca-*.pem | sort -V | tail -1)
$ openssl x509 -in "${MAAS_GW_CA}" -noout -subject
subject=CN=ingress-operator@1777551671
```

> **Note**: if the MaaS gateway uses a certificate signed by a public CA, skip the `maas-gateway-ca` key **and remove the entire `asyncConfig.tls` block** from the CR in [section 4.3](#43-create-the-llmbatchgateway-cr) — the async-processor trusts system roots by default and `asyncConfig.tls` is not needed. Keeping the block without the referenced key in the Secret fails.

```bash
# DEVELOPMENT example — uses the disposable Bitnami instance from 4.1.
# In production, point postgresql-url at your customer-managed PostgreSQL
# (with TLS and credential protection); do not reuse these credentials.
$ kubectl create secret generic batch-gateway-secrets -n batch-api \
    --from-literal=postgresql-url=postgresql://postgres:postgres@postgresql.batch-api.svc.cluster.local:5432/postgres \
    --from-file=maas-gateway-ca="${MAAS_GW_CA}"

# PVC for file storage
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: batch-gateway-files
  namespace: batch-api
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
EOF
```

### 4.3 Create the LLMBatchGateway CR

The CR replaces the Helm install. Everything the Helm flags used to configure is now a CR field:

| Helm flag (old guide) | LLMBatchGateway field |
|---|---|
| `global.secretName` | `spec.secretRef.name` |
| `global.dbClient.type` | `spec.dbBackend` |
| `global.fileClient.*` | `spec.fileStorage.fs` / `spec.fileStorage.s3` |
| `processor.config.modelGateways.<model>.*` | `spec.processor.modelGateways.<model>.*` |
| `processor.config.asyncDispatch.transport` | `spec.processor.asyncConfig.sql` (this guide) or `spec.processor.asyncConfig.redis` |
| `apiserver.config.batchAPI.passThroughHeaders` | `spec.apiServer.config.batchAPI.passThroughHeaders` |
| `apiserver.tls.certManager.*` | `spec.tls.certManager.*` |
| (manual HTTPRoute, see 4.5) | `spec.httpRoute.*` |

Container images are **not** set in the CR — the platform controls them through the operator deployment (see the operator's [ODH installation guide](https://github.com/opendatahub-io/llm-d-batch-gateway-operator/blob/main/docs/odh-installation.md)). `spec.processor.asyncConfig` is **required**: the operator always dispatches asynchronously through the async-processor and has no synchronous path. (`processor.dispatchMode` is retained in the API for compatibility, but only `async` is allowed and the operator ignores it; new manifests should omit it.)

> **Note — image compatibility check**: the SQL transport requires `batch-gateway` and `llm-d-async` images built with SQL producer support, and the async-only operator release removed the legacy synchronous dispatch fields. An older platform/operator bundle can accept this CR and still fail at runtime, so verify the deployed image versions **before** selecting `asyncConfig.sql`:
>
> ```bash
> # Operator and rendered workload images must come from an async-capable,
> # SQL-producer-capable release (RHOAI 3.6 or the 3.6 operator chart)
> $ kubectl get deploy llm-d-batch-gateway-operator -n redhat-ods-applications \
>     -o jsonpath='{.spec.template.spec.containers[*].image}'
> $ kubectl get deploy batch-gateway-async-processor -n batch-api \
>     -o jsonpath='{.spec.template.spec.containers[*].image}'
> ```
>
> If the async-processor image predates SQL producer support, `asyncConfig.sql` cannot dispatch — use a newer operator/platform release before applying the CR in this guide.

`passThroughHeaders={Authorization,X-MaaS-Subscription}` ensures the API key and subscription header are stored with each batch job and forwarded to the model for authentication and rate limiting. **Credential boundary**: Authorino validates the API key at the MaaS gateway on each inference call and strips or replaces `Authorization` before the model backend, so the model never sees the raw credential — but the stored header **is** retained in PostgreSQL with the job records for the job retention period. Anyone with read access to the batch database (or its backups) can read the stored API keys; restrict database access accordingly and prefer short-lived API keys for batch workloads. The async-processor reaches the MaaS gateway via its **external hostname** (`https://maas.<cluster-domain>`) so that the certificate's SAN matches the hostname — the internal service DNS name does not match the certificate SAN. `asyncConfig.tls` points the async-processor at the `maas-gateway-ca` key of the credentials Secret for certificate verification.

`asyncConfig.sql` selects the PostgreSQL dispatch transport. The processor and the async-processor both read the connection URL from the Secret's `postgresql-url` key, so no extra credentials are needed. `sql.maxConnections` caps the processor's SQL pool per replica (default 8) — budget `processor replicas × maxConnections` plus the async-processor's own pool against PostgreSQL `max_connections`.

```bash
$ CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
$ POOL_NAME=facebook-opt-125m-simulated-inference-pool

$ kubectl apply -f - <<EOF
apiVersion: batch.llm-d.ai/v1alpha1
kind: LLMBatchGateway
metadata:
  name: batch-gateway
  namespace: batch-api
spec:
  secretRef:
    name: batch-gateway-secrets
  dbBackend: postgresql
  fileStorage:
    fs:
      basePath: /tmp/batch-gateway
      claimName: batch-gateway-files
  apiServer:
    config:
      batchAPI:
        passThroughHeaders:
        - Authorization
        - X-MaaS-Subscription
  processor:
    modelGateways:
      facebook/opt-125m:
        inferencePoolName: ${POOL_NAME}
    asyncConfig:
      resultPollTimeout: 30s
      inferenceGateway:
        url: https://maas.${CLUSTER_DOMAIN}/llm/facebook-opt-125m-simulated
      sql:
        maxConnections: 8
        queuesConfig:
        - name: "llm-d-async:requests:${POOL_NAME}"
          requestPathURL: /v1/chat/completions
          workerPoolID: default-workers
      workerPools:
      - name: default-workers
        workers: 4
        gateType: local-max-concurrency
        gateParams:
          limit: "2"
      tls:
        secretName: batch-gateway-secrets
        caCertKey: maas-gateway-ca
  gc: {}
  tls:
    enabled: true
    certManager:
      issuerName: selfsigned-issuer
      issuerKind: ClusterIssuer
      dnsNames:
      - batch-gateway-apiserver
      - batch-gateway-apiserver.batch-api.svc.cluster.local
      - localhost
  httpRoute:
    enabled: true
    parentRefs:
    - name: maas-default-gateway
      namespace: openshift-ingress
EOF
```

The `asyncConfig` block above is the minimum for MaaS: the queue name follows the `llm-d-async:requests:<inferencePoolName>` convention and must match the `modelGateways` entry, and the inference gateway URL points at the model's MaaS route. See the [RHOAI deployment guide](deploy-rhoai.md) for the full dispatch configuration reference (gates, worker pools, Prometheus integration).

> **Note — flow control**: this guide assumes the model's `InferencePool` carries **batch-only traffic** (no direct MaaS model-inference requests). The `gateType: local-max-concurrency` gate only caps async worker concurrency; it does not assign a flow-control priority band or sheddability, so it provides **no priority separation** against direct inference traffic sharing the same pool. If direct and batch traffic share the `InferencePool`, set `modelGateways.<model>.inferenceObjective` (e.g. `batch-sheddable`) so the batch traffic lands in a sheddable low-priority band — see the [flow-control setup guide](flow-control-setup.md).

> **Note — SQL result queues**: with the SQL transport the processor polls one result queue per model, and SQL result reads are destructive. Each model gateway entry must therefore resolve to its own result queue (default `llm-d-async:results:<inferencePoolName>`) and use a distinct `inferencePoolName`; setting only one of `requestQueueName` / `resultQueueName` is rejected. The SQL transport requires batch-gateway and llm-d-async images built with SQL producer support.

Wait for the CR to become Ready (the operator deploys `<name>-apiserver`, `<name>-processor`, `<name>-async-processor`, `<name>-gc` and reports replica counts in the CR status):

```bash
$ kubectl wait --for=condition=Ready llmbatchgateway/batch-gateway -n batch-api --timeout=300s
llmbatchgateway.batch.llm-d.ai/batch-gateway condition met

$ kubectl get llmbatchgateway -n batch-api
NAMESPACE   NAME            READY   API-READY   PROC-READY   GC-READY   ASYNC-READY   AGE
batch-api   batch-gateway   True    1           1            1          1            90s
```

### 4.4 Create DestinationRule

The MaaS gateway terminates TLS, then re-encrypts to the apiserver (which also has TLS via cert-manager). The operator does not manage Istio resources, so create the DestinationRule once per cluster:

```bash
$ kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: batch-gateway-backend-tls
  namespace: openshift-ingress
spec:
  host: batch-gateway-apiserver.batch-api.svc.cluster.local
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 8000
      tls:
        mode: SIMPLE
        insecureSkipVerify: true
EOF
```

### 4.5 HTTPRoute — created by the operator

The manual HTTPRoute step is gone: with `spec.httpRoute.enabled: true` the operator creates an HTTPRoute named `<cr-name>-apiserver` attached to the gateways listed in `spec.httpRoute.parentRefs`, with path-prefix rules for `/v1/batches` and `/v1/files` and the apiserver Service as backend.

#### Gateway route attachment (namespace labels)

By default the MaaS gateway's listener only accepts HTTPRoutes from the same namespace, so the route created in `batch-api` is not accepted until the namespaces are allowed. Prefer a **label-based selector** over an exact namespace allow-list — it is less brittle as namespaces are added:

1. Label **every** namespace that must attach to this Gateway — at minimum `batch-api` and `llm`, plus the MaaS infrastructure namespace (`redhat-ai-gateway-infra` / `odh-ai-gateway-infra`) and any application namespace already serving routes on it:

```bash
$ kubectl label namespace batch-api llm maas-gateway-access=true
```

2. Re-run `setup-gateway.sh` from the [models-as-a-service] checkout with the same `INGRESS_MODE` and the namespace selector labels:

```bash
$ cd /tmp/maas
$ NAMESPACE_SELECTOR_LABELS=maas-gateway-access=true ./scripts/setup-gateway.sh
```

All existing route namespaces must be labeled **before** switching the listener selector, or their routes stop being accepted. Finally verify the route reports `Accepted=True`:

```bash
$ kubectl get httproute batch-gateway-apiserver -n batch-api
NAME                      HOSTNAMES   AGE
batch-gateway-apiserver               2m

$ kubectl get httproute batch-gateway-apiserver -n batch-api \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
True
```

## 5. Create Policies

### 5.1 Security boundary: batch HTTPRoute vs LLM (model) route

**Admission on the batch HTTPRoute is not authorization for model inference.** The policies below validate the MaaS API key and rate-limit batch API usage (**401** / **429** as configured). The auto-generated **model-route** policies (from MaaSModelRef / MaaSAuthPolicy) perform **model access** checks; a valid batch submission can still yield inference **403** or failed batch lines when the user lacks group access — by design. Use **`passThroughHeaders`** on the LLMBatchGateway so the processor forwards **`Authorization`** (and **`X-MaaS-Subscription`** if required) on processor-initiated inference calls; otherwise the gateway cannot enforce the same boundary as for direct model clients.

### 5.2 Batch AuthPolicy

The MaaS gateway has a default-deny policy. Create a per-route AuthPolicy for the operator-managed HTTPRoute that validates MaaS API keys via the same HTTP callback that MaaS uses for model routes:

```bash
$ kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: batch-auth
  namespace: batch-api
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-gateway-apiserver
  rules:
    metadata:
      apiKeyValidation:
        http:
          url: "https://maas-api.${MAAS_API_NS}.svc.cluster.local:8443/internal/v1/api-keys/validate"
          contentType: application/json
          method: POST
          body:
            expression: '{"key": request.headers.authorization.replace("Bearer ", "")}'
        metrics: false
        priority: 0
    authentication:
      api-keys:
        plain:
          selector: request.headers.authorization
        metrics: false
        priority: 0
    authorization:
      api-key-valid:
        patternMatching:
          patterns:
          - selector: auth.metadata.apiKeyValidation.valid
            operator: eq
            value: "true"
        metrics: false
        priority: 0
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid:
                  selector: auth.metadata.apiKeyValidation.username
                keyId:
                  selector: auth.metadata.apiKeyValidation.keyId
            metrics: false
            priority: 0
        headers:
          X-MaaS-Username:
            plain:
              selector: auth.metadata.apiKeyValidation.username
            metrics: false
            priority: 0
          X-MaaS-Key-Id:
            plain:
              selector: auth.metadata.apiKeyValidation.keyId
            metrics: false
            priority: 0
      unauthenticated:
        code: 401
        message:
          value: "Authentication required"
      unauthorized:
        code: 403
        message:
          value: "Access denied"
EOF
```

This AuthPolicy validates API keys by calling the MaaS API's `/internal/v1/api-keys/validate` endpoint — the same mechanism MaaS uses for model inference routes. Authorino sends the API key to maas-api, which checks the hash against PostgreSQL and returns `{valid, username, groups, keyId}`.

### 5.3 Batch RateLimitPolicy

Request-count-based rate limiting on the batch HTTPRoute, keyed per user:

```bash
$ kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: batch-ratelimit
  namespace: batch-api
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-gateway-apiserver
  limits:
    per-user:
      rates:
      - limit: 20
        window: 1m
      counters:
      - expression: auth.identity.userid
EOF
```

### 5.4 MaaS Model Policies

Register the model in MaaS and configure token-based rate limiting on the model inference route. The MaaS controller automatically generates the gateway authentication policy and a `TokenRateLimitPolicy` from these CRs.

> **Note**: MaaSAuthPolicy and MaaSSubscription must be in the `models-as-a-service` namespace (the namespace the MaaS controller watches).

```bash
$ kubectl create namespace models-as-a-service

# Register model in MaaS
$ kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: facebook-opt-125m-simulated
  namespace: llm
spec:
  modelRef:
    kind: LLMInferenceService
    name: facebook-opt-125m-simulated
EOF

# Grant access to user group
$ kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: batch-model-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - name: facebook-opt-125m-simulated
      namespace: llm
  subjects:
    groups:
      - name: tier-free-users
EOF

# Token rate limit (500 tokens/min)
$ kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: batch-test-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: tier-free-users
  modelRefs:
    - name: facebook-opt-125m-simulated
      namespace: llm
      tokenRateLimits:
        - limit: 500
          window: 1m
EOF
```

Wait for the MaaS controller to reconcile:

```bash
# MaaSModelRef should be Ready
$ kubectl get maasmodelref -n llm
NAME                          PHASE   AGE
facebook-opt-125m-simulated   Ready   30s

# AuthPolicies should be Enforced
$ kubectl get authpolicy -A
NAMESPACE          NAME                ENFORCED
batch-api          batch-auth          True
openshift-ingress  maas-gateway-auth   True

# TokenRateLimitPolicy should be auto-generated
$ kubectl get tokenratelimitpolicy -n llm
NAME                                    AGE
maas-trlp-facebook-opt-125m-simulated   30s
```

## 6. Testing

### 6.1 Get Gateway Endpoint and API Key

```bash
$ HOST="https://maas.$(kubectl get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}')"

# Login as test user in a temporary kubeconfig (preserves admin session)
$ TEMP_KUBECONFIG=$(mktemp)
$ KUBECONFIG="$TEMP_KUBECONFIG" oc login "$(oc whoami --show-server)" \
    -u testuser -p testpass --insecure-skip-tls-verify
$ USER_TOKEN=$(KUBECONFIG="$TEMP_KUBECONFIG" oc whoami -t)
$ rm -f "$TEMP_KUBECONFIG"

# Create MaaS API key (used for all subsequent requests)
$ API_KEY=$(curl -sSk \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d '{"name":"batch-test","expiration":"1h"}' \
    "${HOST}/maas-api/v1/api-keys" | jq -r .key)

$ echo "API key: ${API_KEY:0:20}..."
```

### 6.2 Test Batch API Authentication

```bash
# Without API key → 401
$ curl -sSk -o /dev/null -w "%{http_code}\n" "${HOST}/v1/batches"
401

# With API key → 200
$ curl -sSk -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer ${API_KEY}" "${HOST}/v1/batches"
200
```

### 6.3 Test Batch API Request Rate Limiting

Send 25 requests to trigger the 20 req/min limit:

```bash
$ for i in {1..25}; do
    curl -sSk -o /dev/null -w "Request $i: %{http_code}\n" \
      -H "Authorization: Bearer ${API_KEY}" "${HOST}/v1/batches"
    sleep 0.1
  done
```

Expected: first ~20 return `200`, then `429`.

### 6.4 Test Model Token Rate Limiting

Send inference requests to exhaust the 500 token budget:

```bash
# Wait for rate limit window to reset
$ sleep 60

$ for i in {1..15}; do
    curl -sSk -o /dev/null -w "Request $i: %{http_code}\n" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-MaaS-Subscription: batch-test-subscription" \
      -H "Content-Type: application/json" \
      -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hi"}],"max_tokens":100}' \
      "${HOST}/llm/facebook-opt-125m-simulated/v1/chat/completions"
    sleep 0.2
  done
```

Expected: a few `200`s followed by `429`s.

### 6.5 Test Batch E2E Lifecycle

Wait for rate limit windows to reset, then test the full batch lifecycle:

```bash
$ sleep 60

# Upload input file
$ cat > /tmp/batch-input.jsonl <<JSONL
{"custom_id":"req-1","method":"POST","url":"/v1/chat/completions","body":{"model":"facebook/opt-125m","messages":[{"role":"user","content":"Hello"}],"max_tokens":10}}
JSONL

$ FILE_ID=$(curl -sSk -X POST "${HOST}/v1/files" \
    -H "Authorization: Bearer ${API_KEY}" \
    -F "purpose=batch" -F "file=@/tmp/batch-input.jsonl" | jq -r .id)

# Create batch
$ BATCH_ID=$(curl -sSk -X POST "${HOST}/v1/batches" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "X-MaaS-Subscription: batch-test-subscription" \
    -H "Content-Type: application/json" \
    -d "{\"input_file_id\":\"${FILE_ID}\",\"endpoint\":\"/v1/chat/completions\",\"completion_window\":\"24h\"}" \
    | jq -r .id)

# Poll until completed
$ while true; do
    STATUS=$(curl -sSk "${HOST}/v1/batches/${BATCH_ID}" \
      -H "Authorization: Bearer ${API_KEY}" | jq -r .status)
    echo "Status: ${STATUS}"
    [[ "$STATUS" =~ ^(completed|failed|expired|cancelled)$ ]] && break
    sleep 5
  done
```

The batch completing proves that `passThroughHeaders` works: the async-processor forwarded the API key through the MaaS gateway to the model, passing the gateway's auth policy on the model route.

## 7. How passThroughHeaders Works

```
1. User sends batch request with API key and subscription
   POST /v1/batches
   Authorization: Bearer sk-oai-xxx
   X-MaaS-Subscription: my-subscription

2. MaaS gateway validates API key (AuthPolicy on batch-gateway-apiserver route)
   → Authorino calls /internal/v1/api-keys/validate
   → Forwards request to batch-gateway-apiserver

3. Apiserver stores Authorization and X-MaaS-Subscription headers with the batch job

4. Processor dequeues the job, reads the stored headers,
   and enqueues each inference request on the PostgreSQL
   dispatch queue (SQL transport) with the headers attached

5. Async-processor pulls the request from the queue and sends it to the
   model through the MaaS gateway, forwarding the stored headers:
   POST /llm/<model>/v1/chat/completions
   Authorization: Bearer sk-oai-xxx
   X-MaaS-Subscription: my-subscription

6. MaaS gateway validates the same API key again (auth policy on model route)
   → Authorino calls /internal/v1/api-keys/validate
   → Checks group membership via MaaSAuthPolicy
   → Applies token rate limit from the specified MaaSSubscription
   → Forwards to LLMInferenceService
```

The async-processor authenticates to the model using the **original user's API key**, not a service account. By also forwarding `X-MaaS-Subscription`, users with multiple subscriptions can specify which subscription's token budget to use. If omitted, MaaS auto-selects the subscription (only works when the user has exactly one).

**Gateway-to-backend credential boundary**: on each processor-initiated call, Authorino validates the forwarded API key at the MaaS gateway (step 6) and strips or replaces the `Authorization` header before the request reaches the model backend, so the model never sees the raw credential. On the storage side, the stored headers live in PostgreSQL with the job records for the job retention period — anyone with read access to the batch database (or its backups) can read the stored API keys, so restrict database access and prefer short-lived API keys for batch workloads.

## 8. Cleanup

```bash
# Batch gateway: deleting the CR removes the deployments, services,
# configmaps, certificate, and the operator-managed HTTPRoute
$ kubectl delete ratelimitpolicy batch-ratelimit -n batch-api
$ kubectl delete authpolicy batch-auth -n batch-api
$ kubectl delete llmbatchgateway batch-gateway -n batch-api
$ kubectl delete destinationrule batch-gateway-backend-tls -n openshift-ingress
$ helm uninstall postgresql -n batch-api
$ kubectl delete pvc batch-gateway-files -n batch-api
$ kubectl delete secret batch-gateway-secrets -n batch-api
$ kubectl delete namespace batch-api

# MaaS model policies
$ kubectl delete maassubscription batch-test-subscription -n models-as-a-service
$ kubectl delete maasauthpolicy batch-model-access -n models-as-a-service
$ kubectl delete maasmodelref facebook-opt-125m-simulated -n llm
$ kubectl delete namespace llm

# ClusterIssuer
$ kubectl delete clusterissuer selfsigned-issuer

# Test user
$ oc delete group tier-free-users
$ oc delete user testuser
$ oc delete identity htpasswd:testuser

# Operators and MaaS platform (removes batch-gateway-operator and MaaS)
# DESTRUCTIVE — fresh/test clusters only. This sets the shared DataScienceCluster
# aigateway component to Removed and tears down MaaS/AI Gateway and operator
# workloads that may be used by other applications. On any shared cluster, skip
# this and delete only the resources created by this guide.
$ kubectl patch datasciencecluster default-dsc --type merge \
    -p '{"spec":{"components":{"aigateway":{"managementState":"Removed"}}}}'
```

## 9. Cluster Resource Inventory

**Namespace: `openshift-ingress`**

| Kind | Name | Created By |
|------|------|------------|
| Gateway | `maas-default-gateway` | MaaS install |
| AuthPolicy | `maas-gateway-auth` | MaaS controller (auto) |
| DestinationRule | `batch-gateway-backend-tls` | User |

**Namespace: `batch-api`**

| Kind | Name | Created By |
|------|------|------------|
| LLMBatchGateway | `batch-gateway` | User |
| Deployment | `batch-gateway-apiserver` | Operator (from CR) |
| StatefulSet | `batch-gateway-processor` | Operator (from CR) |
| Deployment | `batch-gateway-async-processor` | Operator (from CR) |
| Deployment | `batch-gateway-gc` | Operator (from CR) |
| Certificate | `batch-gateway-apiserver-tls` | Operator (from CR, via cert-manager) |
| HTTPRoute | `batch-gateway-apiserver` | Operator (from CR) |
| AuthPolicy | `batch-auth` | User |
| RateLimitPolicy | `batch-ratelimit` | User |
| Secret | `batch-gateway-secrets` | User |
| PVC | `batch-gateway-files` | User |

**Namespace: `llm`**

| Kind | Name | Created By |
|------|------|------------|
| LLMInferenceService | `facebook-opt-125m-simulated` | User |
| InferencePool | `facebook-opt-125m-simulated-inference-pool` | Model router (auto) |
| MaaSModelRef | `facebook-opt-125m-simulated` | User |
| HTTPRoute | `facebook-opt-125m-simulated-kserve-route` | MaaS controller (auto) |
| TokenRateLimitPolicy | `maas-trlp-facebook-opt-125m-simulated` | MaaS controller (auto) |

**Namespace: `models-as-a-service`**

| Kind | Name | Created By |
|------|------|------------|
| MaaSAuthPolicy | `batch-model-access` | User |
| MaaSSubscription | `batch-test-subscription` | User |

## 10. References

- [MaaS Platform](https://github.com/opendatahub-io/models-as-a-service)
- [MaaS installation guide](https://opendatahub-io.github.io/models-as-a-service/)
- [batch-gateway-operator](https://github.com/opendatahub-io/llm-d-batch-gateway-operator)
- [Operator ODH installation guide](https://github.com/opendatahub-io/llm-d-batch-gateway-operator/blob/main/docs/odh-installation.md)
- [RHOAI deployment guide (dispatch configuration)](deploy-rhoai.md)
- [Kuadrant AuthPolicy](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/authpolicy/)
- [Kuadrant RateLimitPolicy](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/ratelimitpolicy/)
- [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [Batch API spec (OpenAI compatible)](https://developers.openai.com/api/reference/resources/batches)
