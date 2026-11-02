#!/usr/bin/env bash

if [[ -n "${NSM_OVS_FIREWALL_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_FIREWALL_SH_LOADED=1

firewall_init_runtime_context() {
    FIREWALL_RUNTIME_ROOT="${FIREWALL_ASSETS_ROOT}"
    FIREWALL_K8S_DIR="${FIREWALL_K8S_ASSETS_DIR}"
    FIREWALL_VERIFY_SCRIPT="${FIREWALL_VERIFY_ASSET_SCRIPT}"
}

firewall_init_context() {
    firewall_init_runtime_context
}

firewall_require_runtime_assets() {
    [[ -d "${FIREWALL_K8S_ASSETS_DIR}" ]] || die "firewall k8s directory not found: ${FIREWALL_K8S_ASSETS_DIR}"
    [[ -f "${FIREWALL_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "firewall kustomization not found: ${FIREWALL_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${FIREWALL_VERIFY_ASSET_SCRIPT}" ]] || die "firewall verify script not found or not executable: ${FIREWALL_VERIFY_ASSET_SCRIPT}"
}

firewall_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${FIREWALL_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${FIREWALL_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

firewall_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before firewall operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(firewall_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before firewall operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

firewall_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

firewall_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    firewall_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

firewall_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if firewall_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

firewall_wait_ready() {
    local timeout=${1:-120s}

    k8s_wait_deployment_available "${FIREWALL_NAMESPACE}" "${FIREWALL_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${FIREWALL_NAMESPACE}" "${FIREWALL_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${FIREWALL_NAMESPACE}" "${FIREWALL_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${FIREWALL_NAMESPACE}" "${FIREWALL_MIDDLE_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${FIREWALL_NAMESPACE}" "${FIREWALL_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${FIREWALL_NAMESPACE}" "${FIREWALL_CLIENT_POD_SELECTOR}" "${timeout}"
}

firewall_client_pod_name() {
    k8s_get_first_pod_name "${FIREWALL_NAMESPACE}" "${FIREWALL_CLIENT_POD_SELECTOR}"
}

firewall_server_pod_name() {
    k8s_get_first_pod_name "${FIREWALL_NAMESPACE}" "${FIREWALL_SERVER_POD_SELECTOR}"
}

firewall_check_client_interface() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(firewall_client_pod_name)"
    [[ -n "${client_pod}" ]] || die "firewall client pod not found in namespace ${FIREWALL_NAMESPACE}"

    "${kubectl_bin}" exec -n "${FIREWALL_NAMESPACE}" "${client_pod}" -c client -- ip link show nsm-1 >/dev/null
    "${kubectl_bin}" exec -n "${FIREWALL_NAMESPACE}" "${client_pod}" -c client -- ip addr show nsm-1 >/dev/null
}

firewall_try_ping_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(firewall_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    "${kubectl_bin}" exec -n "${FIREWALL_NAMESPACE}" "${client_pod}" -c client -- ping -c 2 "${FIREWALL_SERVER_IPV4}"
}

firewall_start_server_iperf_once() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(firewall_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "firewall server pod not found in namespace ${FIREWALL_NAMESPACE}"

    "${kubectl_bin}" exec -n "${FIREWALL_NAMESPACE}" "${server_pod}" -c server -- sh -eu -c '
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

firewall_try_iperf_server() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(firewall_client_pod_name)"
    [[ -n "${client_pod}" ]] || return 1

    firewall_start_server_iperf_once
    "${kubectl_bin}" exec -n "${FIREWALL_NAMESPACE}" "${client_pod}" -c client -- sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${FIREWALL_SERVER_IPV4}' -p 5201 -t 10"
}

firewall_try_verify_script() {
    [[ -x "${FIREWALL_VERIFY_SCRIPT}" ]] || return 1
    NS_NAMESPACE="${FIREWALL_NAMESPACE}" \
    NSM_SYSTEM_NAMESPACE="${NSM_SYSTEM_NAMESPACE}" \
    CLIENT_POD_PREFIX="${FIREWALL_CLIENT_DEPLOYMENT_NAME}-" \
    TEMPLATE_POD_PREFIX="${FIREWALL_DEPLOYMENT_NAME}-" \
    SERVER_POD_PREFIX="${FIREWALL_SERVER_DEPLOYMENT_NAME}-" \
    CLIENT_IFACE="nsm-1" \
    CLIENT_CONTAINER="client" \
    CLIENT_CMD_CONTAINER="cmd-nsc" \
    TEMPLATE_CONTAINER="nse" \
    SERVER_CONTAINER="server" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${FIREWALL_VERIFY_SCRIPT}"
}
