#!/usr/bin/env bash
# common-rhoai.sh — RHOAI/ODH-specific helpers (DSC-based deployment).
# Sourced by deploy-rhoai.sh and deploy-maas.sh after common.sh.

# ── DSC-based Batch Gateway Deployment ──────────────────────────────────
#
# do_deploy_batch_gateway_dsc isvc_name [pass_through_headers]
#
# Deploys batch-gateway via the LLMBatchGateway CR (operator-managed).
# Installs dependencies (Redis, PostgreSQL, MinIO/PVC), creates the CR,
# waits for it to be ready, and sets up HTTPRoute + DestinationRule.
#
# Args:
#   isvc_name             Model / InferenceService name (used in the model URL path)
#   pass_through_headers  Comma-separated list of HTTP headers to forward (optional, empty = none)

do_deploy_batch_gateway_dsc() {
    local isvc_name="$1"
    local pass_through_headers="${2:-}"

    local operator_type="${OPERATOR_TYPE:-rhoai}"
    local apps_namespace
    case "${operator_type}" in
        rhoai) apps_namespace="redhat-ods-applications" ;;
        odh)   apps_namespace="opendatahub" ;;
        *)     die "Unknown OPERATOR_TYPE: ${operator_type}" ;;
    esac

    step "Enabling aigateway + batchGateway in DataScienceCluster..."
    kubectl patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"aigateway":{"managementState":"Managed","batchGateway":{"managementState":"Managed"}}}}}'

    wait_for_deployment "ai-gateway-operator" "${apps_namespace}" 300s
    wait_for_deployment "llm-d-batch-gateway-operator" "${apps_namespace}" 300s
    wait_for_crd "llmbatchgateways.batch.llm-d.ai"

    kubectl get namespace "${BATCH_NAMESPACE}" &>/dev/null || kubectl create namespace "${BATCH_NAMESPACE}"
    kubectl label namespace "${BATCH_NAMESPACE}" llm-d.ai/gateway-route=true --overwrite

    install_batch_exchange
    install_batch_postgresql
    if [ "${BATCH_STORAGE_TYPE}" = "s3" ]; then
        install_batch_minio
    else
        create_batch_pvc
    fi
    create_batch_secret

    local internal_gw_svc
    internal_gw_svc=$(kubectl get svc -n "${BATCH_INTERNAL_GATEWAY_NAMESPACE}" \
        -l "gateway.networking.k8s.io/gateway-name=${BATCH_INTERNAL_GATEWAY_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -z "${internal_gw_svc}" ] && die "No service found for Internal Gateway '${BATCH_INTERNAL_GATEWAY_NAME}'."
    local model_url="http://${internal_gw_svc}.${BATCH_INTERNAL_GATEWAY_NAMESPACE}.svc.cluster.local/${LLM_NAMESPACE}/${isvc_name}"
    log "Model URL (via Internal Gateway): ${model_url}"

    local processor_inference_objective_yaml=""
    if [ "${ENABLE_FLOW_CONTROL}" = "true" ]; then
        processor_inference_objective_yaml="      inferenceObjective: ${BATCH_FLOW_CONTROL_OBJECTIVE}"
        log "Flow control: processor will send x-gateway-inference-objective: ${BATCH_FLOW_CONTROL_OBJECTIVE}"
    fi

    local file_storage_yaml
    if [ "${BATCH_STORAGE_TYPE}" = "s3" ]; then
        local minio_endpoint="http://${BATCH_MINIO_RELEASE}.${BATCH_NAMESPACE}.svc.cluster.local:9000"
        file_storage_yaml="    s3:
      region: ${MINIO_REGION}
      bucket: ${MINIO_BUCKET}
      endpoint: ${minio_endpoint}
      accessKeyId: ${MINIO_ROOT_USER}
      prefix: ${MINIO_BUCKET}
      usePathStyle: true
      autoCreateBucket: true"
    else
        file_storage_yaml="    fs:
      basePath: /tmp/batch-gateway
      claimName: ${BATCH_FILES_PVC_NAME}"
    fi

    local apiserver_batch_api_yaml=""
    if [ -n "${pass_through_headers}" ]; then
        local header_items=""
        IFS=',' read -ra _headers <<< "${pass_through_headers}"
        for h in "${_headers[@]}"; do
            header_items="${header_items}
        - ${h}"
        done
        apiserver_batch_api_yaml="    config:
      batchAPI:
        passThroughHeaders:${header_items}"
    fi

    step "Creating LLMBatchGateway CR..."
    kubectl apply -f - <<EOF
apiVersion: batch.llm-d.ai/v1alpha1
kind: LLMBatchGateway
metadata:
  name: ${BATCH_INSTANCE_NAME}
  namespace: ${BATCH_NAMESPACE}
spec:
  secretRef:
    name: ${BATCH_APP_SECRET_NAME}
  dbBackend: ${BATCH_DB_TYPE}
  fileStorage:
${file_storage_yaml}
  apiServer:
    replicas: 1
${apiserver_batch_api_yaml}
  processor:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: "1"
        memory: 1Gi
    globalInferenceGateway:
      url: ${model_url}
      requestTimeout: ${GW_REQUEST_TIMEOUT}
      maxRetries: ${GW_MAX_RETRIES}
      initialBackoff: ${GW_INITIAL_BACKOFF}
      maxBackoff: ${GW_MAX_BACKOFF}
${processor_inference_objective_yaml}
  gc:
    interval: 30m
  tls:
    enabled: true
    certManager:
      issuerName: ${TLS_ISSUER_NAME}
      issuerKind: ClusterIssuer
      dnsNames:
      - ${BATCH_INSTANCE_NAME}-apiserver
      - ${BATCH_INSTANCE_NAME}-apiserver.${BATCH_NAMESPACE}.svc.cluster.local
      - localhost
EOF

    step "Waiting for LLMBatchGateway to be ready..."
    kubectl wait llmbatchgateway/${BATCH_INSTANCE_NAME} -n "${BATCH_NAMESPACE}" \
        --for=condition=Ready --timeout=300s
    log "LLMBatchGateway is ready."

    step "Waiting for AIGateway to be ready..."
    kubectl wait aigateway/default-aigateway --for=condition=Ready --timeout=300s
    log "AIGateway is ready."

    # TODO: Change to die once https://github.com/opendatahub-io/ai-gateway-operator/issues/47 is fixed.
    step "Waiting for DataScienceCluster to be ready..."
    kubectl wait dsc/default-dsc --for=condition=Ready --timeout=60s \
        || warn "DataScienceCluster is not Ready (known issue: github.com/opendatahub-io/ai-gateway-operator/issues/47)"

    create_batch_httproute
    create_batch_destinationrule
}
