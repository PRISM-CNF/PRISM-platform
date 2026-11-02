#!/usr/bin/env bash

if [[ -n "${NSM_OVS_TEMPLATE_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_TEMPLATE_SH_LOADED=1

template_init_runtime_context() {
    TEMPLATE_RUNTIME_ROOT="${TEMPLATE_ASSETS_ROOT}"
    TEMPLATE_K8S_DIR="${TEMPLATE_K8S_ASSETS_DIR}"
    TEMPLATE_VERIFY_SCRIPT="${TEMPLATE_VERIFY_ASSET_SCRIPT}"
}

template_init_source_context() {
    TEMPLATE_SOURCE_ROOT="${TEMPLATE_REPO_PATH}"
    TEMPLATE_SOURCE_DOCKERFILE="${TEMPLATE_SOURCE_ROOT}/Dockerfile"
}

template_init_context() {
    template_init_runtime_context
}

template_require_runtime_assets() {
    [[ -d "${TEMPLATE_K8S_ASSETS_DIR}" ]] || die "template k8s directory not found: ${TEMPLATE_K8S_ASSETS_DIR}"
    [[ -f "${TEMPLATE_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "template kustomization not found: ${TEMPLATE_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${TEMPLATE_VERIFY_ASSET_SCRIPT}" ]] || die "template verify script not found or not executable: ${TEMPLATE_VERIFY_ASSET_SCRIPT}"
}

template_require_source_tree() {
    [[ -d "${TEMPLATE_SOURCE_ROOT}" ]] || die "template source repo not found: ${TEMPLATE_SOURCE_ROOT}; build-template is a source-mode command"
    [[ -f "${TEMPLATE_SOURCE_DOCKERFILE}" ]] || die "template Dockerfile not found: ${TEMPLATE_SOURCE_DOCKERFILE}; build-template requires the source repo"
}

template_warn_if_gateway_present() {
    if k8s_namespace_exists "${TEMPLATE_GATEWAY_NAMESPACE:-nse-ovs-gateway}"; then
        log_warn "detected existing ${TEMPLATE_GATEWAY_NAMESPACE:-nse-ovs-gateway} namespace; template operations stay scoped to ${TEMPLATE_NAMESPACE} only"
        if [[ -n "${TEMPLATE_SERVER_CIDR_PREFIX:-}" ]]; then
            log_warn "template stack ${TEMPLATE_NAMESPACE} uses server CIDR ${TEMPLATE_SERVER_CIDR_PREFIX}; keep it distinct from gateway-side routes"
        fi
    fi
}

template_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${TEMPLATE_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${TEMPLATE_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

template_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before template operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(template_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before template operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

template_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

template_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    template_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

template_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if template_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

template_write_image_override_overlay() {
    local overlay_dir=$1
    local image_ref=$2
    local base_dir=${3:-${TEMPLATE_K8S_DIR}}

    mkdir -p "${overlay_dir}"
    cat > "${overlay_dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ${base_dir}

patches:
  - target:
      kind: Deployment
      name: ${TEMPLATE_DEPLOYMENT_NAME}
      namespace: ${TEMPLATE_NAMESPACE}
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: ${image_ref}
EOF
}

template_wait_ready() {
    local timeout=${1:-120s}

    k8s_wait_deployment_available "${TEMPLATE_NAMESPACE}" "${TEMPLATE_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${TEMPLATE_NAMESPACE}" "${TEMPLATE_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${TEMPLATE_NAMESPACE}" "${TEMPLATE_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${TEMPLATE_NAMESPACE}" "${TEMPLATE_MIDDLE_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${TEMPLATE_NAMESPACE}" "${TEMPLATE_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${TEMPLATE_NAMESPACE}" "${TEMPLATE_CLIENT_POD_SELECTOR}" "${timeout}"
}

template_client_pod_name() {
    k8s_get_first_pod_name "${TEMPLATE_NAMESPACE}" "${TEMPLATE_CLIENT_POD_SELECTOR}"
}

template_check_client_interface() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(template_client_pod_name)"
    [[ -n "${client_pod}" ]] || die "template client pod not found in namespace ${TEMPLATE_NAMESPACE}"

    "${kubectl_bin}" exec -n "${TEMPLATE_NAMESPACE}" "${client_pod}" -c client -- ip link show nsm-1 >/dev/null
    "${kubectl_bin}" exec -n "${TEMPLATE_NAMESPACE}" "${client_pod}" -c client -- ip addr show nsm-1 >/dev/null
}

template_try_ping_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(template_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    "${kubectl_bin}" exec -n "${TEMPLATE_NAMESPACE}" "${client_pod}" -c client -- ping -c 2 "${TEMPLATE_SERVER_IPV4}"
}

template_try_iperf_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(template_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    "${kubectl_bin}" exec -n "${TEMPLATE_NAMESPACE}" "${client_pod}" -c client -- sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${TEMPLATE_SERVER_IPV4}' -p 5201 -t 3 -P 2"
}

template_try_verify_script() {
    [[ -x "${TEMPLATE_VERIFY_SCRIPT}" ]] || return 1
    NS_NAMESPACE="${TEMPLATE_NAMESPACE}" \
    CLIENT_POD_PREFIX="${TEMPLATE_CLIENT_DEPLOYMENT_NAME}-" \
    TEMPLATE_POD_PREFIX="${TEMPLATE_DEPLOYMENT_NAME}-" \
    SERVER_POD_PREFIX="${TEMPLATE_SERVER_DEPLOYMENT_NAME}-" \
    CLIENT_IFACE="nsm-1" \
    CLIENT_CONTAINER="client" \
    CLIENT_CMD_CONTAINER="cmd-nsc" \
    TEMPLATE_CONTAINER="nse" \
    SERVER_CONTAINER="server" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${TEMPLATE_VERIFY_SCRIPT}"
}
