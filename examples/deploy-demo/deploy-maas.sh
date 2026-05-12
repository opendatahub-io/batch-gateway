#!/bin/bash
set -euo pipefail

# ── Deploy batch-gateway on MaaS platform ────────────────────────────────────
#
# Deploys batch-gateway integrated with MaaS (Models-as-a-Service) platform.
# MaaS provides: Gateway, Istio, Kuadrant, cert-manager, AuthPolicy, TokenRateLimitPolicy.
# This script only deploys: MaaS platform + sample model + batch-gateway + HTTPRoute.
#
# Prerequisites:
#   - OpenShift cluster (self-managed, not ROSA/HyperShift)
#   - oc, helm, kustomize, jq, htpasswd CLI tools
#   - Cluster admin access
#
# MaaS repo: https://github.com/opendatahub-io/models-as-a-service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"

# ── Configuration (set before sourcing common.sh to override its defaults) ──
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"

LLM_NAMESPACE="${LLM_NAMESPACE:-llm}"

GATEWAY_CLASS_NAME="${GATEWAY_CLASS_NAME:-openshift-default}"
BATCH_INTERNAL_GATEWAY_NAME="${BATCH_INTERNAL_GATEWAY_NAME:-batch-internal-gateway}"
BATCH_INTERNAL_GATEWAY_NAMESPACE="${BATCH_INTERNAL_GATEWAY_NAMESPACE:-${GATEWAY_NAMESPACE}}"

# ── MaaS-specific Configuration ─────────────────────────────────────────────
MAAS_REPO="${MAAS_REPO:-https://github.com/opendatahub-io/models-as-a-service.git}"
MAAS_REF="${MAAS_REF:-main}"
MAAS_DIR="${MAAS_DIR:-/tmp/maas}"
MAAS_NAMESPACE="${MAAS_NAMESPACE:-opendatahub}"
# maas-controller only watches this namespace for MaaSAuthPolicy and MaaSSubscription CRs.
# CRs created in other namespaces (e.g. opendatahub) will be ignored by the controller.
MAAS_POLICY_NAMESPACE="${MAAS_POLICY_NAMESPACE:-models-as-a-service}"

# MaaS test users
MAAS_TEST_USER="${MAAS_TEST_USER:-testuser}"
MAAS_TEST_PASS="${MAAS_TEST_PASS:-testpass}"
MAAS_TEST_GROUP="${MAAS_TEST_GROUP:-tier-free-users}"
# Unauthorized user (valid OpenShift user, has subscription but NOT authorized to access the model)
MAAS_UNAUTH_USER="${MAAS_UNAUTH_USER:-testuser-unauth}"
MAAS_UNAUTH_PASS="${MAAS_UNAUTH_PASS:-testpass}"
MAAS_UNAUTH_GROUP="${MAAS_UNAUTH_GROUP:-tier-unauth-users}"

# Model served by MaaS simulator sample
MAAS_MODEL_NAME="${MAAS_MODEL_NAME:-facebook/opt-125m}"
# LLMInferenceService name after kustomize (namePrefix "facebook-opt-125m-" + resource name "simulated")
MAAS_ISVC_NAME="${MAAS_ISVC_NAME:-facebook-opt-125m-simulated}"

# ── Install MaaS Platform ───────────────────────────────────────────────────

install_maas() {
    step "Installing MaaS platform..."

    if kubectl get deployment maas-api -n "${MAAS_NAMESPACE}" &>/dev/null; then
        log "MaaS API already deployed in '${MAAS_NAMESPACE}'. Skipping."
        return
    fi

    # Apply RBAC before deploy.sh so maas-api can read maas-db-config on first boot.
    # The SA doesn't exist yet but K8s allows binding to a future SA.
    # TODO: Remove once the ODH operator includes these permissions natively.
    # In operator mode, ODH creates the maas-api SA but not the ClusterRole from
    # deployment/base/maas-api/rbac/clusterrole.yaml (that only applies in kustomize mode).
    # Ref: models-as-a-service/deployment/base/maas-api/rbac/clusterrole.yaml
    step "Pre-creating maas-api RBAC for MaaS CRDs..."
    kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: maas-api-extra
rules:
  # maas-api watches MaaSSubscription and MaaSModelRef for subscription selection
  # and model listing. These CRDs come from maas-controller, not the ODH operator,
  # so the operator-managed ClusterRole doesn't include them.
- apiGroups: ["maas.opendatahub.io"]
  resources: ["maassubscriptions", "maasmodelrefs"]
  verbs: ["get", "list", "watch"]
  # maas-api reads the maas-db-config secret for the PostgreSQL connection URL.
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["maas-db-config"]
  verbs: ["get"]
  # SAR-based admin authorization (replaces hardcoded admin list)
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
  # HTTPRoutes for model route resolution
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: maas-api-extra
subjects:
- kind: ServiceAccount
  name: maas-api
  namespace: ${MAAS_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: maas-api-extra
  apiGroup: rbac.authorization.k8s.io
EOF

    step "Cloning MaaS repo (${MAAS_REF})..."
    rm -rf "${MAAS_DIR}"
    git clone --depth 1 --branch "${MAAS_REF}" "${MAAS_REPO}" "${MAAS_DIR}"

    step "Running MaaS deploy script..."
    (cd "${MAAS_DIR}" && MAAS_REF="${MAAS_REF}" ./scripts/deploy.sh)

    log "MaaS platform installed."
}

# ── Deploy Sample Model ─────────────────────────────────────────────────────

deploy_sample_model() {
    step "Deploying sample model (simulator) in namespace '${LLM_NAMESPACE}'..."

    local isvc_name="${MAAS_ISVC_NAME}"

    if kubectl get llminferenceservice "${isvc_name}" -n "${LLM_NAMESPACE}" &>/dev/null; then
        log "Sample model '${isvc_name}' already exists. Skipping."
        return
    fi

    kubectl get namespace "${LLM_NAMESPACE}" &>/dev/null || kubectl create namespace "${LLM_NAMESPACE}"
    kubectl label namespace "${LLM_NAMESPACE}" llm-d.ai/gateway-route=true --overwrite

    local samples_dir="${MAAS_DIR}/docs/samples/models/simulator"
    if [ ! -d "${samples_dir}" ]; then
        die "MaaS samples not found at ${samples_dir}. Run install first."
    fi

    # Ensure spec.router.scheduler is set so RHOAI creates InferencePool + EPP
    local model_yaml="${samples_dir}/model.yaml"
    if [ -f "${model_yaml}" ] && ! yq -e 'select(.kind == "LLMInferenceService").spec.router.scheduler' "${model_yaml}" &>/dev/null; then
        yq -i '(select(.kind == "LLMInferenceService") | .spec.router.scheduler) = {}' "${model_yaml}"
        log "Added 'spec.router.scheduler: {}' to ${model_yaml}"
    fi

    kustomize build "${samples_dir}" | kubectl apply -f -
    wait_for_deployment "${isvc_name}-kserve" "${LLM_NAMESPACE}" 300s

    step "Waiting for LLMInferenceService to be ready..."
    if ! oc wait "llminferenceservice/${isvc_name}" -n "${LLM_NAMESPACE}" \
            --for=condition=Ready --timeout=300s 2>/dev/null; then
        oc get "llminferenceservice/${isvc_name}" -n "${LLM_NAMESPACE}" -o yaml 2>/dev/null || true
        oc get events -n "${LLM_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
        die "Model '${isvc_name}' did not become ready"
    fi
    log "Sample model '${isvc_name}' is ready."
}

# ── Batch LLM HTTPRoute on Internal Gateway ─────────────────────────────────
# Routes batch processor inference traffic through the Internal Gateway (ClusterIP)
# to the same InferencePool, preserving EPP but bypassing TokenRateLimitPolicy.

create_batch_llm_httproute() {
    local isvc_name="${MAAS_ISVC_NAME}"

    step "Discovering InferencePool for LLMInferenceService '${isvc_name}'..."
    local pool_name
    pool_name=$(kubectl get inferencepool -n "${LLM_NAMESPACE}" -o json | \
        jq -r --arg owner "${isvc_name}" \
        '.items[] | select(.metadata.ownerReferences[]?.name == $owner) | .metadata.name' \
        2>/dev/null | head -1)
    [ -z "${pool_name}" ] && die "No InferencePool owned by LLMInferenceService '${isvc_name}' found in namespace '${LLM_NAMESPACE}'."
    log "InferencePool: ${pool_name} (owned by ${isvc_name})"

    step "Creating batch-llm-route on Internal Gateway..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: batch-llm-route
  namespace: ${LLM_NAMESPACE}
spec:
  parentRefs:
  - name: ${BATCH_INTERNAL_GATEWAY_NAME}
    namespace: ${BATCH_INTERNAL_GATEWAY_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NAMESPACE}/${isvc_name}/v1/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/completions
    backendRefs:
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: ${pool_name}
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NAMESPACE}/${isvc_name}/v1/chat/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/chat/completions
    backendRefs:
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: ${pool_name}
  - matches:
    - path:
        type: PathPrefix
        value: /${LLM_NAMESPACE}/${isvc_name}
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: ${pool_name}
EOF

    log "batch-llm-route created: /${LLM_NAMESPACE}/${isvc_name}/* -> InferencePool/${pool_name} (via Internal Gateway)"
}

# ── AuthPolicy for batch LLM route (Internal Gateway) ──────────────────────
# API key authentication via maas-api callback, NO TokenRateLimitPolicy.
# Model-level authorization was validated at batch job creation time.

apply_batch_llm_auth_policy() {
    local isvc_name="${MAAS_ISVC_NAME}"
    local source_policy="maas-auth-${isvc_name}"

    step "Copying AuthPolicy '${source_policy}' for batch-llm-route (no TokenRateLimitPolicy)..."

    local policy_json
    policy_json=$(kubectl get authpolicy "${source_policy}" -n "${LLM_NAMESPACE}" -o json 2>/dev/null)
    if [ -z "${policy_json}" ]; then
        warn "AuthPolicy '${source_policy}' not found in namespace '${LLM_NAMESPACE}'."
        warn "Ensure MaaSAuthPolicy is reconciled before running this step."
        return 1
    fi

    echo "${policy_json}" \
        | jq '{
            apiVersion: .apiVersion,
            kind: .kind,
            metadata: {
                name: "batch-llm-route-auth",
                namespace: .metadata.namespace
            },
            spec: (.spec | .targetRef = {
                group: "gateway.networking.k8s.io",
                kind: "HTTPRoute",
                name: "batch-llm-route"
            })
        }' \
        | kubectl apply -f - \
        || die "Failed to apply batch-llm-route AuthPolicy (source: ${source_policy})"

    log "batch-llm-route AuthPolicy applied (copied from ${source_policy}, no TokenRateLimitPolicy)."
}

# ── Batch Gateway (MaaS) ──────────────────────────────────────────────────────

deploy_batch_gateway_maas() {
    banner "Installing Batch Gateway"

    local isvc_name="${MAAS_ISVC_NAME}"

    # Route batch processor through the Internal Gateway (ClusterIP, no token rate limit)
    # instead of the external MaaS Gateway. The Internal Gateway still uses EPP and
    # enforces AuthPolicy (API key validation).
    local internal_gw_svc
    internal_gw_svc=$(kubectl get svc -n "${BATCH_INTERNAL_GATEWAY_NAMESPACE}" \
        -l "gateway.networking.k8s.io/gateway-name=${BATCH_INTERNAL_GATEWAY_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -z "${internal_gw_svc}" ] && die "No service found for Internal Gateway '${BATCH_INTERNAL_GATEWAY_NAME}'."
    local model_url="http://${internal_gw_svc}.${BATCH_INTERNAL_GATEWAY_NAMESPACE}.svc.cluster.local/${LLM_NAMESPACE}/${isvc_name}"
    log "Model URL (via Internal Gateway): ${model_url}"

    local model_key="${MAAS_MODEL_NAME}"

    local helm_args=(
        --set "processor.config.modelGateways.${model_key}.url=${model_url}"
        --set "processor.config.modelGateways.${model_key}.requestTimeout=${GW_REQUEST_TIMEOUT}"
        --set "processor.config.modelGateways.${model_key}.maxRetries=${GW_MAX_RETRIES}"
        --set "processor.config.modelGateways.${model_key}.initialBackoff=${GW_INITIAL_BACKOFF}"
        --set "processor.config.modelGateways.${model_key}.maxBackoff=${GW_MAX_BACKOFF}"
        --set "apiserver.config.batchAPI.passThroughHeaders={Authorization,X-MaaS-Subscription}"
    )

    do_deploy_batch_gateway "${helm_args[@]}"
}

# ── MaaS Model Policies (MaaSModelRef + MaaSAuthPolicy + MaaSSubscription) ───

MAAS_TOKEN_RATE_LIMIT="${MAAS_TOKEN_RATE_LIMIT:-500}"
MAAS_TOKEN_RATE_WINDOW="${MAAS_TOKEN_RATE_WINDOW:-1m}"

create_maas_model_policies() {
    local isvc_name="${MAAS_ISVC_NAME}"

    kubectl get namespace "${MAAS_POLICY_NAMESPACE}" &>/dev/null || kubectl create namespace "${MAAS_POLICY_NAMESPACE}"

    step "Creating MaaSModelRef for '${isvc_name}'..."
    kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${isvc_name}
  namespace: ${LLM_NAMESPACE}
spec:
  modelRef:
    kind: LLMInferenceService
    name: ${isvc_name}
EOF

    step "Creating MaaSAuthPolicy (grant '${MAAS_TEST_GROUP}' access to model)..."
    kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: batch-model-access
  namespace: ${MAAS_POLICY_NAMESPACE}
spec:
  modelRefs:
    - name: ${isvc_name}
      namespace: ${LLM_NAMESPACE}
  subjects:
    groups:
      - name: ${MAAS_TEST_GROUP}
EOF

    step "Creating MaaSSubscription for authorized group (token rate limit: ${MAAS_TOKEN_RATE_LIMIT} tokens/${MAAS_TOKEN_RATE_WINDOW})..."
    kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: batch-test-subscription
  namespace: ${MAAS_POLICY_NAMESPACE}
spec:
  owner:
    groups:
      - name: ${MAAS_TEST_GROUP}
  modelRefs:
    - name: ${isvc_name}
      namespace: ${LLM_NAMESPACE}
      tokenRateLimits:
        - limit: ${MAAS_TOKEN_RATE_LIMIT}
          window: ${MAAS_TOKEN_RATE_WINDOW}
EOF

    step "Creating MaaSSubscription for unauthorized group (has subscription, no model access)..."
    kubectl apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: batch-test-subscription-unauth
  namespace: ${MAAS_POLICY_NAMESPACE}
spec:
  owner:
    groups:
      - name: ${MAAS_UNAUTH_GROUP}
  modelRefs:
    - name: ${isvc_name}
      namespace: ${LLM_NAMESPACE}
      tokenRateLimits:
        - limit: ${MAAS_TOKEN_RATE_LIMIT}
          window: ${MAAS_TOKEN_RATE_WINDOW}
EOF

    # Wait for MaaSModelRef to be Ready (controller reconciles HTTPRoute + AuthPolicy)
    step "Waiting for MaaSModelRef to be Ready..."
    local retries=30 mr_ready=false
    for i in $(seq 1 "${retries}"); do
        local phase
        phase=$(kubectl get maasmodelref "${isvc_name}" -n "${LLM_NAMESPACE}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "${phase}" = "Ready" ]; then
            mr_ready=true
            break
        fi
        sleep 5
    done
    if ! ${mr_ready}; then
        # Controller can get stuck; bouncing may unstick it (known issue)
        warn "MaaSModelRef not ready after ${retries} retries, bouncing maas-controller..."
        kubectl rollout restart deployment/maas-controller -n "${MAAS_NAMESPACE}" 2>/dev/null || true
        kubectl rollout status deployment/maas-controller -n "${MAAS_NAMESPACE}" --timeout=180s 2>/dev/null || true
        for i in $(seq 1 30); do
            local phase
            phase=$(kubectl get maasmodelref "${isvc_name}" -n "${LLM_NAMESPACE}" \
                -o jsonpath='{.status.phase}' 2>/dev/null)
            if [ "${phase}" = "Ready" ]; then mr_ready=true; break; fi
            sleep 5
        done
    fi
    if ${mr_ready}; then
        log "MaaSModelRef ready."
    else
        die "MaaSModelRef still not ready after bounce."
    fi

    # Wait for all AuthPolicies to be enforced (Authorino reconcile)
    wait_for_auth_policies_enforced

    # Wait for TokenRateLimitPolicy to be generated from MaaSSubscription
    step "Waiting for TokenRateLimitPolicy..."
    for i in $(seq 1 30); do
        if kubectl get tokenratelimitpolicy -n "${LLM_NAMESPACE}" 2>/dev/null | grep -q "${isvc_name}"; then
            log "TokenRateLimitPolicy generated for model."
            return
        fi
        sleep 5
    done
    die "TokenRateLimitPolicy not found after 30 attempts."
}

# Wait for all Kuadrant AuthPolicies to be enforced across model namespaces
wait_for_auth_policies_enforced() {
    local timeout=180
    step "Waiting for AuthPolicies to be enforced (timeout: ${timeout}s)..."

    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        local all_enforced=true total=0
        while IFS=$'\t' read -r status message; do
            total=$((total + 1))
            # Enforced=True is ready; Enforced=False with "overridden" is also valid
            if [ "${status}" != "True" ] && [[ "${message}" != *overridden* ]]; then
                all_enforced=false
            fi
        done < <(kubectl get authpolicy -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Enforced")].status}{"\t"}{.status.conditions[?(@.type=="Enforced")].message}{"\n"}{end}' 2>/dev/null)

        if ${all_enforced} && [ $total -gt 0 ]; then
            log "All AuthPolicies enforced (${total} policies)."
            return
        fi
        echo "  Waiting... (${total} policies found, not all enforced yet)"
        sleep 10
    done
    die "AuthPolicies not all enforced after ${timeout}s."
    kubectl get authpolicy -A -o wide 2>/dev/null || true
}

# ── Batch Policies (MaaS API key auth + request rate limit) ──────────────────

apply_batch_auth_policy() {
    local api_key_url="https://maas-api.${MAAS_NAMESPACE}.svc.cluster.local:8443/internal/v1/api-keys/validate"

    step "Creating AuthPolicy for batch-route (MaaS API key validation)..."
    # Uses the same API key HTTP callback as MaaS-generated model AuthPolicies.
    # Authorino calls maas-api to validate the API key and extract user identity.
    # No model-level authorization here; that happens when batch processor calls the LLM route.
    kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: batch-auth
  namespace: ${BATCH_NAMESPACE}
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: batch-route
  rules:
    metadata:
      # Validate API key via MaaS API callback, returns {valid, username, groups, keyId}
      apiKeyValidation:
        http:
          url: "${api_key_url}"
          contentType: application/json
          method: POST
          body:
            expression: '{"key": request.headers.authorization.replace("Bearer ", "")}'
        metrics: false
        priority: 0
    authentication:
      # Plain authentication — actual validation is done in the metadata layer above
      api-keys:
        plain:
          selector: request.headers.authorization
        metrics: false
        priority: 0
    authorization:
      # Ensure the API key is valid
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
    log "batch-auth AuthPolicy applied (MaaS API key validation, targets batch-route)."
}

apply_batch_request_rate_limit() {
    step "Creating RateLimitPolicy for batch-route (per-user request count)..."
    kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: batch-ratelimit
  namespace: ${BATCH_NAMESPACE}
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
      - expression: auth.identity.userid
EOF
    log "batch-ratelimit applied (20 req/min per user)."
}

# ── Create MaaS Test User ───────────────────────────────────────────────────
#
# Demo-only: if you change MAAS_* user/password env vars and re-run install on the
# same cluster, delete htpass-secret first or OAuth may keep stale credentials:
#   oc delete secret htpass-secret -n openshift-config

create_maas_test_user() {
    step "Creating MaaS test users..."

    local need_oauth_update=false
    if oc get user "${MAAS_TEST_USER}" &>/dev/null 2>&1; then
        log "User '${MAAS_TEST_USER}' already exists. Skipping user creation."
    else
        need_oauth_update=true
    fi

    if ${need_oauth_update}; then
        # Create htpasswd with both authorized and unauthorized test users
        htpasswd -cbB /tmp/htpasswd "${MAAS_TEST_USER}" "${MAAS_TEST_PASS}"
        htpasswd -bB  /tmp/htpasswd "${MAAS_UNAUTH_USER}" "${MAAS_UNAUTH_PASS}"
        oc create secret generic htpass-secret \
            --from-file=htpasswd=/tmp/htpasswd \
            -n openshift-config \
            --dry-run=client -o yaml | oc apply -f -
        oc patch oauth cluster --type=merge -p "
spec:
  identityProviders:
  - name: htpasswd
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret"
        log "OAuth htpasswd identity provider configured. Waiting for restart..."
        sleep 30
    fi

    if ! oc get group "${MAAS_TEST_GROUP}" &>/dev/null 2>&1; then
        oc adm groups new "${MAAS_TEST_GROUP}"
    fi
    # Authorized user -> authorized group (has model access via MaaSAuthPolicy)
    oc adm groups add-users "${MAAS_TEST_GROUP}" "${MAAS_TEST_USER}" 2>/dev/null || true
    log "User '${MAAS_TEST_USER}' added to group '${MAAS_TEST_GROUP}'."

    # Unauthorized user -> unauth group (has subscription but NO model access)
    if ! oc get group "${MAAS_UNAUTH_GROUP}" &>/dev/null 2>&1; then
        oc adm groups new "${MAAS_UNAUTH_GROUP}"
    fi
    oc adm groups add-users "${MAAS_UNAUTH_GROUP}" "${MAAS_UNAUTH_USER}" 2>/dev/null || true
    log "User '${MAAS_UNAUTH_USER}' added to group '${MAAS_UNAUTH_GROUP}' (no model access)."
}

get_maas_gateway_host() {
    local cluster_domain
    cluster_domain=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null) \
        || die "Cannot detect cluster domain. Is this an OpenShift cluster?"
    echo "https://maas.${cluster_domain}"
}

get_maas_api_key() {
    local host="$1"
    local server_url
    server_url=$(oc whoami --show-server)

    # Use a temporary kubeconfig so we don't pollute the admin session
    local temp_kubeconfig
    temp_kubeconfig=$(mktemp)
    trap "rm -f '${temp_kubeconfig}'" RETURN

    # Login as test user to get OpenShift token
    KUBECONFIG="${temp_kubeconfig}" oc login "${server_url}" \
        -u "${MAAS_TEST_USER}" -p "${MAAS_TEST_PASS}" --insecure-skip-tls-verify &>/dev/null \
        || die "Failed to login as ${MAAS_TEST_USER}"
    local user_token
    user_token=$(KUBECONFIG="${temp_kubeconfig}" oc whoami -t) || die "Failed to get user token"

    # Create MaaS API key using OpenShift token
    local key_response
    key_response=$(curl -sSk \
        -H "Authorization: Bearer ${user_token}" \
        -H "Content-Type: application/json" \
        -X POST -d '{"name":"batch-e2e","expiresIn":"1h"}' \
        "${host}/maas-api/v1/api-keys")
    local api_key
    api_key=$(echo "${key_response}" | jq -r '.key // empty')

    if [ -z "${api_key}" ]; then
        die "Failed to create MaaS API key. Response: ${key_response}"
    fi
    echo "${api_key}"
}

check_prerequisites() {
    step "Checking prerequisites..."
    local missing=()
    for cmd in oc kubectl helm kustomize jq htpasswd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -gt 0 ] && die "Missing required tools: ${missing[*]}"

    oc whoami &>/dev/null || die "Not logged in to OpenShift. Run 'oc login' first."
    is_openshift || die "This script requires an OpenShift cluster (oc, OAuth, LLMInferenceService)."
    log "Connected to cluster: $(oc whoami --show-server)"
}

# ── Install ──────────────────────────────────────────────────────────────────

cmd_install() {
    banner "MaaS + Batch Gateway Setup"

    check_prerequisites

    install_maas
    create_selfsigned_issuer
    deploy_sample_model
    create_maas_model_policies

    create_batch_internal_gateway
    create_batch_llm_httproute
    apply_batch_llm_auth_policy
    check_batch_internal_gateway

    deploy_batch_gateway_maas
    apply_batch_auth_policy
    apply_batch_request_rate_limit

    create_maas_test_user

    local host
    host=$(get_maas_gateway_host)
    log "Setup complete!"
    log "  MaaS Gateway: ${host}"
    log "  Batch API:    ${host}/v1/batches"
    log "  Test user:    ${MAAS_TEST_USER} / ${MAAS_TEST_PASS} (group: ${MAAS_TEST_GROUP})"
    if [ -n "${BATCH_IMAGE_TAG}" ]; then
        log "  Batch Gateway image tag: ${BATCH_IMAGE_TAG}"
    fi
    if [ -n "${BATCH_RELEASE_VERSION}" ]; then
        log "  Batch Gateway version: ${BATCH_RELEASE_VERSION} (OCI chart)"
    elif [ "${BATCH_DEV_VERSION}" != "local" ]; then
        log "  Batch Gateway version: ${BATCH_DEV_VERSION} (commit chart)"
    else
        log "  Batch Gateway version: latest (local chart)"
    fi
    log ""
    log "Run '$0 test' to verify."
}

# ── Test ─────────────────────────────────────────────────────────────────────

cmd_test() {
    banner "Testing: MaaS + Batch Gateway"

    local gw_url
    gw_url=$(get_maas_gateway_host)
    log "MaaS Gateway: ${gw_url}"

    # Get MaaS API keys
    step "Obtaining MaaS API key for authorized user '${MAAS_TEST_USER}'..."
    local api_key
    api_key=$(get_maas_api_key "${gw_url}")
    log "API key obtained"

    step "Obtaining MaaS API key for unauthorized user '${MAAS_UNAUTH_USER}'..."
    local unauth_api_key
    unauth_api_key=$(MAAS_TEST_USER="${MAAS_UNAUTH_USER}" MAAS_TEST_PASS="${MAAS_UNAUTH_PASS}" \
        get_maas_api_key "${gw_url}")
    log "Unauthorized user API key obtained"

    local llm_url="${gw_url}/${LLM_NAMESPACE}/${MAAS_ISVC_NAME}/v1/chat/completions"
    local inference_payload="{\"model\":\"${MAAS_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":10}"

    check_batch_internal_gateway

    run_tests "${llm_url}" "${gw_url}" "${MAAS_MODEL_NAME}" \
        "Authorization: Bearer ${api_key}" \
        "Authorization: Bearer ${unauth_api_key}" \
        "${inference_payload}" \
        "X-MaaS-Subscription: batch-test-subscription"
}

# ── Uninstall ────────────────────────────────────────────────────────────────

cleanup_auth_resources() { true; }

cmd_uninstall() {
    set +e

    banner "Uninstalling All (Batch Gateway + MaaS)"

    # Batch gateway
    # Batch gateway resources
    step "Removing batch-gateway resources..."
    kubectl delete ratelimitpolicy batch-ratelimit -n "${BATCH_NAMESPACE}" 2>/dev/null || true
    kubectl delete authpolicy batch-auth -n "${BATCH_NAMESPACE}" 2>/dev/null || true
    kubectl delete httproute batch-route -n "${BATCH_NAMESPACE}" 2>/dev/null || true
    kubectl delete destinationrule "${BATCH_HELM_RELEASE}-backend-tls" -n "${GATEWAY_NAMESPACE}" 2>/dev/null || true
    helm uninstall "${BATCH_HELM_RELEASE}" -n "${BATCH_NAMESPACE}" --timeout 60s 2>/dev/null || true
    helm uninstall "${BATCH_REDIS_RELEASE}" -n "${BATCH_NAMESPACE}" --timeout 60s 2>/dev/null || true
    helm uninstall "${BATCH_POSTGRESQL_RELEASE}" -n "${BATCH_NAMESPACE}" --timeout 60s 2>/dev/null || true
    kubectl delete pvc "${BATCH_FILES_PVC_NAME}" -n "${BATCH_NAMESPACE}" 2>/dev/null || true
    kubectl delete namespace "${BATCH_NAMESPACE}" --timeout=60s 2>/dev/null || true
    log "Batch gateway uninstalled."

    # Internal Gateway resources (batch-llm-route)
    step "Removing Internal Gateway resources..."
    kubectl delete authpolicy batch-llm-route-auth -n "${LLM_NAMESPACE}" 2>/dev/null || true
    kubectl delete httproute batch-llm-route -n "${LLM_NAMESPACE}" 2>/dev/null || true
    kubectl delete gateway "${BATCH_INTERNAL_GATEWAY_NAME}" -n "${BATCH_INTERNAL_GATEWAY_NAMESPACE}" 2>/dev/null || true

    # RBAC patch created by this demo (safe to remove; does not delete MaaS core).
    kubectl delete clusterrolebinding maas-api-extra 2>/dev/null || true
    kubectl delete clusterrole maas-api-extra 2>/dev/null || true

    # Test user
    step "Removing test users..."
    oc delete group "${MAAS_TEST_GROUP}" 2>/dev/null || true
    oc delete group "${MAAS_UNAUTH_GROUP}" 2>/dev/null || true
    oc delete user "${MAAS_TEST_USER}" 2>/dev/null || true
    oc delete identity "htpasswd:${MAAS_TEST_USER}" 2>/dev/null || true
    oc delete user "${MAAS_UNAUTH_USER}" 2>/dev/null || true
    oc delete identity "htpasswd:${MAAS_UNAUTH_USER}" 2>/dev/null || true

    if is_demo_uninstall_all; then
        kubectl delete clusterissuer "${TLS_ISSUER_NAME}" 2>/dev/null || true

        # MaaS platform (reuse cleanup-odh.sh from MaaS repo)
        step "Removing MaaS platform..."
        local cleanup_script="${MAAS_DIR}/.github/hack/cleanup-odh.sh"
        if [ -f "${cleanup_script}" ]; then
            log "Using MaaS cleanup script: ${cleanup_script}"
            bash "${cleanup_script}" --include-crds || warn "cleanup-odh.sh returned non-zero"
        else
            warn "MaaS cleanup script not found at ${cleanup_script}, cleaning up manually..."
            kubectl delete datasciencecluster --all -A --timeout=180s 2>/dev/null || true
            kubectl delete dscinitialization --all -A --timeout=180s 2>/dev/null || true
            kubectl delete namespace "${MAAS_NAMESPACE}" --timeout=180s 2>/dev/null || true
            kubectl delete namespace "${MAAS_POLICY_NAMESPACE}" --timeout=60s 2>/dev/null || true
            kubectl delete namespace kuadrant-system --timeout=60s 2>/dev/null || true
            kubectl delete gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" 2>/dev/null || true
        fi

        # Operators not covered by cleanup-odh.sh
        step "Removing cert-manager and LWS operators..."
        local cm_csv
        cm_csv=$(kubectl get csv -n cert-manager-operator -o name 2>/dev/null | grep cert-manager || true)
        if [ -n "${cm_csv}" ]; then
            kubectl delete subscription openshift-cert-manager-operator -n cert-manager-operator 2>/dev/null || true
            kubectl delete "${cm_csv}" -n cert-manager-operator 2>/dev/null || true
        fi
        kubectl delete namespace cert-manager-operator --timeout=60s 2>/dev/null || true

        local lws_csv
        lws_csv=$(kubectl get csv -n openshift-lws-operator -o name 2>/dev/null | grep leader-worker || true)
        if [ -n "${lws_csv}" ]; then
            kubectl delete subscription leader-worker-set -n openshift-lws-operator 2>/dev/null || true
            kubectl delete "${lws_csv}" -n openshift-lws-operator 2>/dev/null || true
        fi
        kubectl delete namespace openshift-lws-operator --timeout=60s 2>/dev/null || true
    else
        warn "Skipping ClusterIssuer, MaaS/ODH cleanup, Kuadrant namespaces, and cert-manager/LWS operators (shared-cluster safety)."
        warn "For full teardown on an ephemeral cluster only: UNINSTALL_ALL=1 $0 uninstall"
    fi

    echo ""
    log "Uninstallation complete (batch-gateway + optional MaaS teardown)."

    set -e
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 {install|test|uninstall|help}"
    echo ""
    echo "Commands:"
    echo "  install    Install MaaS platform + sample model + batch-gateway"
    echo "  test       Run integration tests (MaaS auth + batch lifecycle)"
    echo "  uninstall  Remove batch-gateway + demo RBAC/users (use UNINSTALL_ALL=1 for MaaS/operators)"
    echo "  help       Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  MAAS_REF              MaaS branch or tag (default: main)"
    echo "  MAAS_TEST_USER        Test username (default: testuser)"
    echo "  MAAS_TEST_GROUP       Test user group (default: tier-free-users)"
    echo "  UNINSTALL_ALL            Set to 1 to run MaaS cleanup script / remove operators (ephemeral clusters only)"
    exit "${1:-0}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then usage 0; fi

case "$1" in
    install)   shift; cmd_install "$@" ;;
    test)      shift; cmd_test "$@" ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    help|-h|--help) usage 0 ;;
    *) echo "Error: Unknown command '$1'"; echo ""; usage 1 ;;
esac
