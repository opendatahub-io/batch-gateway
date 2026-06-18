# Demo Scripts

One-click deployment script for batch-gateway on OpenShift with RHOAI/ODH. Supports `install`, `test`, and `uninstall` commands.

## Overview

**Prerequisites**:

- **Tools**: `oc`, `kubectl`, `helm`, `jq`, `curl`.
- **Cluster access**: You must be logged in to an OpenShift cluster. Use `oc whoami` to verify.

## Usage

### install

```bash
bash examples/deploy-demo/deploy-rhoai.sh install
```

#### Components Installed

| Component | Details |
|-----------|---------|
| cert-manager | TLS certificate management (OLM operator) |
| LeaderWorkerSet | Pod group orchestration (OLM operator) |
| GatewayClass + Gateway | OpenShift default gateway (auto-installs Service Mesh / Istio) |
| Red Hat Connectivity Link | Productized Kuadrant — auth + rate limiting (OLM operator) |
| RHOAI / ODH operator | DSCInitialization + DataScienceCluster (configurable via `OPERATOR_TYPE`) |
| LLMInferenceService | KServe-managed model serving — CPU simulator (single model, default: facebook/opt-125m) |
| Redis | Exchange backend (Bitnami Helm chart, configurable via `BATCH_EXCHANGE_CLIENT_TYPE`) |
| PostgreSQL | Batch metadata store (Bitnami Helm chart) |
| MinIO | S3-compatible file storage (when `BATCH_STORAGE_TYPE=s3`) |
| Internal Gateway | ClusterIP gateway for batch processor → LLM inference (bypasses rate limits, preserves AuthPolicy) |
| InferenceObjective | GIE flow control CRDs — priority-based dispatch (interactive=100, batch=-1). Enabled by default (`ENABLE_FLOW_CONTROL=true`) |
| batch-gateway | apiserver + processor + gc (Helm chart) |

#### Routing & Policies

**External Gateway** (`openshift-ai-inference`, HTTPS:443):

| HTTPRoute | Backend | Auth | Rate Limit |
|-----------|---------|------|------------|
| LLM route (auto-created by LLMInferenceService controller) | InferencePool (direct inference) | kubernetesTokenReview + SubjectAccessReview (model-level authz on LLMInferenceService) | 500 tokens/1min per user on `/v1/chat/completions` only (TokenRateLimitPolicy) |
| `batch-route` | batch-gateway apiserver | kubernetesTokenReview only (no authz) | 20 req/1min per user (RateLimitPolicy) |

**Internal Gateway** (`batch-internal-gateway`, ClusterIP, HTTP:80):

| HTTPRoute | Backend | Auth | Rate Limit |
|-----------|---------|------|------------|
| `batch-llm-route` | InferencePool (batch processor access) | kubernetesTokenReview + SubjectAccessReview (model-level authz on LLMInferenceService) | — (none, by design) |

Batch-route has no authorization — model-level authz is enforced downstream when the batch processor forwards requests through the Internal Gateway's `batch-llm-route`.

#### Install Examples

**Batch-gateway chart source** — controls where the batch-gateway Helm chart and images come from:

| Mode | Command |
|------|---------|
| OCI chart v0.2.0 + RHOAI images (default) | `bash examples/deploy-demo/deploy-rhoai.sh install` |
| Different OCI chart version | `BATCH_RELEASE_VERSION=v0.3.0 bash examples/deploy-demo/deploy-rhoai.sh install` |
| Specific commit (dev chart) | `BATCH_DEV_VERSION=1f925ff bash examples/deploy-demo/deploy-rhoai.sh install` |
| Local chart | `BATCH_DEV_VERSION=local bash examples/deploy-demo/deploy-rhoai.sh install` |
| Custom batch-gateway images | `BATCH_IMAGE_TAG=my-tag` <br> `BATCH_APISERVER_REPO=my-registry/apiserver` <br> `BATCH_PROCESSOR_REPO=my-registry/processor` <br> `BATCH_GC_REPO=my-registry/gc` <br> `bash examples/deploy-demo/deploy-rhoai.sh install` |

> `BATCH_RELEASE_VERSION` and `BATCH_DEV_VERSION` cannot be used together.

**RHOAI / ODH platform** — controls which AI platform operator is installed (orthogonal to batch-gateway chart source, can be combined):

| Mode | Command |
|------|---------|
| Auto-detect latest RHOAI (default) | `bash examples/deploy-demo/deploy-rhoai.sh install` |
| Specific RHOAI version | `RHOAI_VERSION=3.4 bash examples/deploy-demo/deploy-rhoai.sh install` |
| Custom RHOAI catalog | `CUSTOM_CATALOG=quay.io/rhoai/rhoai-fbc-fragment:...` <br> `bash examples/deploy-demo/deploy-rhoai.sh install` |
| ODH instead of RHOAI | `OPERATOR_TYPE=odh bash examples/deploy-demo/deploy-rhoai.sh install` |

> See [Environment Variables](#environment-variables) for common parameters.

### test

```bash
bash examples/deploy-demo/deploy-rhoai.sh test
```

Creates temporary ServiceAccounts (authorized + unauthorized) with short-lived tokens and runs the following test groups:

| # | Test Group | What it verifies |
|---|------------|------------------|
| 1 | LLM Authn | Unauthenticated → 401, authenticated → 200 |
| 2 | LLM Authz | Unauthorized → 403, authorized → 200 |
| 3 | LLM Token Rate Limit | Repeated requests → 429 |
| 4 | Batch Authn | Unauthenticated → 401, authenticated → 200 |
| 5 | Batch Authz | Unauthorized user's batch → requests rejected with 403 by Internal Gateway |
| 6 | Batch Lifecycle | File upload → batch create → poll → completed → download output |
| 7 | Batch Request Rate Limit | Rapid requests → 429 |
| 8 | Flow Control (if enabled) | EPP metrics: interactive requests at default priority (0, no InferenceObjective header), batch at priority -1, pool saturation metric present |

Internal Gateway isolation is also verified before tests run (service type is ClusterIP, no Route/Ingress exposes it).

### uninstall

```bash
bash examples/deploy-demo/deploy-rhoai.sh uninstall
```

Default `uninstall` removes the batch-gateway footprint and associated gateway/policy resources:

- Helm releases and CRs in `BATCH_NAMESPACE` (including all HTTPRoutes)
- Both Gateways: `GATEWAY_NAME` and `BATCH_INTERNAL_GATEWAY_NAME`
- DestinationRule `${BATCH_HELM_RELEASE}-backend-tls`
- InferenceObjective resources in `LLM_NAMESPACE`
- Internal Gateway resources (`batch-llm-route`, `batch-llm-route-auth`) in `LLM_NAMESPACE`
- Kuadrant policies (`batch-route-auth`, `batch-ratelimit`, `inference-token-limit`)
- Demo RBAC (test ServiceAccounts, Role, RoleBinding) in `LLM_NAMESPACE`
- `BATCH_NAMESPACE` itself

It does **not** remove RHOAI/ODH operators, Connectivity Link (Kuadrant), cert-manager, LeaderWorkerSet, GatewayClass, LLMInferenceService, or the `LLM_NAMESPACE`—so other teams' platform pieces stay.

> **Note**: The default uninstall deletes the Gateway named `GATEWAY_NAME` (default: `openshift-ai-inference`). If this Gateway is shared with other teams, override `GATEWAY_NAME` or remove the Gateway deletion from the script before running.

**Do not use `UNINSTALL_ALL=1` on shared production or multi-team clusters** — that mode tears down operators and platform components others may depend on.

**Full teardown** (throwaway / dedicated demo cluster only) — prefix the command with `UNINSTALL_ALL=1`:

```bash
UNINSTALL_ALL=1 bash examples/deploy-demo/deploy-rhoai.sh uninstall
```

Use that only on **ephemeral or dedicated** demo clusters. See [issue #309](https://github.com/llm-d/llm-d-batch-gateway/issues/309) for background.

## Environment Variables

| Variable | Default | Scope | Description |
|----------|---------|-------|-------------|
| `BATCH_HELM_RELEASE` | `batch-gateway` | all | Helm release name |
| `BATCH_RELEASE_VERSION` | `v0.2.0` | all | OCI chart version. Cannot be used with `BATCH_DEV_VERSION` |
| `BATCH_DEV_VERSION` | — | all | Commit SHA for dev chart. Overrides `BATCH_RELEASE_VERSION`. `local` uses local chart |
| `BATCH_IMAGE_TAG` | `rhoai-3.5-ea.2` | all | Image tag for all components. Takes precedence over version-derived tags |
| `BATCH_APISERVER_REPO` | `quay.io/rhoai/odh-llm-d-batch-gateway-apiserver-rhel9` | all | Apiserver image repository |
| `BATCH_PROCESSOR_REPO` | `quay.io/rhoai/odh-llm-d-batch-gateway-processor-rhel9` | all | Processor image repository |
| `BATCH_GC_REPO` | `quay.io/rhoai/odh-llm-d-batch-gateway-gc-rhel9` | all | GC image repository |
| `BATCH_DB_TYPE` | `postgresql` | all | Database backend: `postgresql` or `redis` |
| `BATCH_STORAGE_TYPE` | `s3` | all | File storage: `fs` or `s3` |
| `DEMO_TLS_INSECURE_SKIP_VERIFY` | `1` | all | Disables TLS certificate verification for processor → model gateway and Istio Gateway → batch apiserver (**demo/lab only**, [CWE-295](https://cwe.mitre.org/data/definitions/295.html)). Default `1` since demo scripts use self-signed certs. Set to `0` if you have trusted CA certs. |
| `BATCH_NAMESPACE` | `batch-api` | all | Namespace for batch-gateway |
| `LLM_NAMESPACE` | `llm` | all | Namespace for model serving |
| `BATCH_EXCHANGE_CLIENT_TYPE` | `redis` | all | Exchange backend type (`redis` or `valkey`) |
| `GW_REQUEST_TIMEOUT` | `5m` | all | Model gateway HTTP request timeout |
| `GW_MAX_RETRIES` | `3` | all | Model gateway max retries |
| `GW_INITIAL_BACKOFF` | `1s` | all | Model gateway initial retry backoff |
| `GW_MAX_BACKOFF` | `60s` | all | Model gateway max retry backoff |
| `OPERATOR_TYPE` | `rhoai` | rhoai | Operator type: `rhoai` or `odh` |
| `CUSTOM_CATALOG` | — | rhoai | Custom catalog image for operator (creates CatalogSource) |
| `RHOAI_VERSION` | (auto-detected) | rhoai | RHOAI version (e.g. `3.4`). Auto-detected from PackageManifest if not set |
| `RHOAI_CHANNEL` | (auto-detected) | rhoai | RHOAI OLM channel (e.g. `stable-3.4`). Auto-detected if not set |
| `ODH_CHANNEL` | `fast-3` | rhoai | ODH OLM channel (used when `OPERATOR_TYPE=odh`) |
| `KUADRANT_NAMESPACE` | `kuadrant-system` | rhoai | Namespace for Connectivity Link (Kuadrant) |
| `GATEWAY_CLASS_NAME` | `openshift-default` | rhoai | GatewayClass name |
| `GATEWAY_NAME` | `openshift-ai-inference` | rhoai | Gateway resource name |
| `GATEWAY_NAMESPACE` | `openshift-ingress` | rhoai | Gateway namespace |
| `BATCH_INTERNAL_GATEWAY_NAME` | `batch-internal-gateway` | rhoai | Internal Gateway resource name |
| `BATCH_INTERNAL_GATEWAY_NAMESPACE` | `${GATEWAY_NAMESPACE}` | rhoai | Internal Gateway namespace |
| `MODEL_NAME` | `facebook/opt-125m` | rhoai | Model name for routing |
| `MODEL_URI` | `hf://sshleifer/tiny-gpt2` | rhoai | Model URI for LLMInferenceService |
| `MODEL_REPLICAS` | `1` | rhoai | Number of model replicas |
| `SIM_IMAGE` | `ghcr.io/llm-d/llm-d-inference-sim:v0.7.1` | rhoai | Simulator container image |
| `ENABLE_FLOW_CONTROL` | `true` | rhoai | Enable GIE priority-based flow control |
| `INTERACTIVE_FLOW_CONTROL_OBJECTIVE` | `interactive-default` | rhoai | InferenceObjective name for interactive requests (priority 100) |
| `BATCH_FLOW_CONTROL_OBJECTIVE` | `batch-sheddable` | rhoai | InferenceObjective name for batch requests (priority -1) |
| `UNINSTALL_ALL` | `0` | all | Set to `1` to remove RHOAI operators, Kuadrant, cert-manager, etc. (ephemeral clusters only) |
