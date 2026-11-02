#!/usr/bin/env bash

if [[ -n "${NSM_OVS_DPI_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_DPI_SH_LOADED=1

dpi_init_runtime_context() {
    DPI_RUNTIME_ROOT="${DPI_ASSETS_ROOT}"
    DPI_K8S_DIR="${DPI_K8S_ASSETS_DIR}"
    DPI_VERIFY_SCRIPT="${DPI_VERIFY_ASSET_SCRIPT}"
}

dpi_init_context() {
    dpi_init_runtime_context
}

dpi_require_runtime_assets() {
    [[ -d "${DPI_K8S_ASSETS_DIR}" ]] || die "dpi k8s directory not found: ${DPI_K8S_ASSETS_DIR}"
    [[ -f "${DPI_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "dpi kustomization not found: ${DPI_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${DPI_VERIFY_ASSET_SCRIPT}" ]] || die "dpi verify script not found or not executable: ${DPI_VERIFY_ASSET_SCRIPT}"
}

dpi_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${DPI_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${DPI_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

dpi_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before dpi operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(dpi_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before dpi operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

dpi_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

dpi_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    dpi_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

dpi_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if dpi_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

dpi_wait_ready() {
    local timeout=${1:-120s}

    k8s_wait_deployment_available "${DPI_NAMESPACE}" "${DPI_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${DPI_NAMESPACE}" "${DPI_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${DPI_NAMESPACE}" "${DPI_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${DPI_NAMESPACE}" "${DPI_MIDDLE_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${DPI_NAMESPACE}" "${DPI_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${DPI_NAMESPACE}" "${DPI_CLIENT_POD_SELECTOR}" "${timeout}"
}

dpi_client_pod_name() {
    k8s_get_first_pod_name "${DPI_NAMESPACE}" "${DPI_CLIENT_POD_SELECTOR}"
}

dpi_server_pod_name() {
    k8s_get_first_pod_name "${DPI_NAMESPACE}" "${DPI_SERVER_POD_SELECTOR}"
}

dpi_check_client_interface() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(dpi_client_pod_name)"
    [[ -n "${client_pod}" ]] || die "dpi client pod not found in namespace ${DPI_NAMESPACE}"

    "${kubectl_bin}" exec -n "${DPI_NAMESPACE}" "${client_pod}" -c client -- ip link show nsm-1 >/dev/null
    "${kubectl_bin}" exec -n "${DPI_NAMESPACE}" "${client_pod}" -c client -- ip addr show nsm-1 >/dev/null
}

dpi_try_ping_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(dpi_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    "${kubectl_bin}" exec -n "${DPI_NAMESPACE}" "${client_pod}" -c client -- ping -c 2 "${DPI_SERVER_IPV4}"
}

dpi_start_server_iperf_once() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(dpi_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "dpi server pod not found in namespace ${DPI_NAMESPACE}"

    "${kubectl_bin}" exec -n "${DPI_NAMESPACE}" "${server_pod}" -c server -- sh -eu -c '
check_listener() {
    if command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -q ":5201 "; then
        return 0
    fi
    if command -v netstat >/dev/null 2>&1 && netstat -lntp 2>/dev/null | grep -q ":5201 "; then
        return 0
    fi
    return 1
}

if check_listener; then
    exit 0
fi

rm -f /tmp/iperf3-server.log
nohup iperf3 -s -1 -p 5201 >/tmp/iperf3-server.log 2>&1 </dev/null &
sleep 1
check_listener
'
}

dpi_try_iperf_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(dpi_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    dpi_start_server_iperf_once
    "${kubectl_bin}" exec -n "${DPI_NAMESPACE}" "${client_pod}" -c client -- sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${DPI_SERVER_IPV4}' -p 5201 -t 10"
}

dpi_try_verify_script() {
    [[ -x "${DPI_VERIFY_SCRIPT}" ]] || return 1
    NS_NAMESPACE="${DPI_NAMESPACE}" \
    NSM_SYSTEM_NAMESPACE="${NSM_SYSTEM_NAMESPACE}" \
    CLIENT_POD_PREFIX="${DPI_CLIENT_DEPLOYMENT_NAME}-" \
    DPI_POD_PREFIX="${DPI_DEPLOYMENT_NAME}-" \
    SERVER_POD_PREFIX="${DPI_SERVER_DEPLOYMENT_NAME}-" \
    CLIENT_IFACE="nsm-1" \
    CLIENT_CONTAINER="client" \
    CLIENT_CMD_CONTAINER="cmd-nsc" \
    DPI_CONTAINER="nse" \
    SERVER_CONTAINER="server" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${DPI_VERIFY_SCRIPT}"
}
