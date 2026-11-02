#!/usr/bin/env bash

if [[ -n "${NSM_OVS_VPN_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_VPN_SH_LOADED=1

vpn_init_runtime_context() {
    VPN_RUNTIME_ROOT="${VPN_ASSETS_ROOT}"
    VPN_K8S_DIR="${VPN_K8S_ASSETS_DIR}"
    VPN_VERIFY_SCRIPT="${VPN_VERIFY_ASSET_SCRIPT}"
    VPN_CLEANUP_SCRIPT="${VPN_CLEANUP_ASSET_SCRIPT}"
    VPN_TCP_SECONDS="${VPN_TCP_SECONDS:-10}"
    VPN_UDP_SECONDS="${VPN_UDP_SECONDS:-10}"
    VPN_VERIFY_PING="${VPN_VERIFY_PING:-false}"
    VPN_CLIENT_CONTAINER="${VPN_CLIENT_CONTAINER:-client}"
    VPN_SERVER_CONTAINER="${VPN_SERVER_CONTAINER:-server}"
    VPN_MIDDLE_CONTAINER="${VPN_MIDDLE_CONTAINER:-nse}"
    VPN_READY_TIMEOUT_SECONDS="${VPN_READY_TIMEOUT_SECONDS:-60}"
    VPN_READY_POLL_SECONDS="${VPN_READY_POLL_SECONDS:-2}"
    VPN_CLIENT_ROUTE_TIMEOUT_SECONDS="${VPN_CLIENT_ROUTE_TIMEOUT_SECONDS:-30}"
    VPN_ROUTE_SETTLE_SECONDS="${VPN_ROUTE_SETTLE_SECONDS:-2}"
}

vpn_init_context() {
    vpn_init_runtime_context
}

vpn_require_runtime_assets() {
    [[ -d "${VPN_K8S_ASSETS_DIR}" ]] || die "vpn k8s directory not found: ${VPN_K8S_ASSETS_DIR}"
    [[ -f "${VPN_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "vpn kustomization not found: ${VPN_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${VPN_VERIFY_ASSET_SCRIPT}" ]] || die "vpn verify script not found or not executable: ${VPN_VERIFY_ASSET_SCRIPT}"
    [[ -x "${VPN_CLEANUP_ASSET_SCRIPT}" ]] || die "vpn cleanup script not found or not executable: ${VPN_CLEANUP_ASSET_SCRIPT}"
}

vpn_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${VPN_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${VPN_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

vpn_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before vpn operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(vpn_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before vpn operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

vpn_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

vpn_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    vpn_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

vpn_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if vpn_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

vpn_exec_in_pod() {
    local pod_name=$1
    local container_name=$2
    shift 2

    k8s_exec -n "${VPN_NAMESPACE}" "${pod_name}" -c "${container_name}" -- "$@"
}

vpn_exec_sh_in_pod() {
    local pod_name=$1
    local container_name=$2
    local command=$3

    k8s_exec -n "${VPN_NAMESPACE}" "${pod_name}" -c "${container_name}" -- sh -c "${command}"
}

vpn_pod_logs() {
    local pod_name=$1
    local container_name=$2

    "${KUBECTL:-kubectl}" logs -n "${VPN_NAMESPACE}" "${pod_name}" -c "${container_name}" 2>/dev/null || true
}

vpn_middle_pod_has_ready_log() {
    local pod_name=$1

    [[ -n "${pod_name}" ]] || return 1
    grep -q "vpn service ready:" < <(vpn_pod_logs "${pod_name}" "${VPN_MIDDLE_CONTAINER}")
}

vpn_middle_pod_has_handshake() {
    local pod_name=$1
    local wg_output

    [[ -n "${pod_name}" ]] || return 1
    wg_output="$(vpn_exec_sh_in_pod "${pod_name}" "${VPN_MIDDLE_CONTAINER}" 'wg show 2>/dev/null || true' 2>/dev/null || true)"
    grep -q "latest handshake:" <<<"${wg_output}" || return 1
    ! grep -q "latest handshake: never" <<<"${wg_output}"
}

vpn_middle_pod_ready_source() {
    local pod_name=$1

    if vpn_middle_pod_has_ready_log "${pod_name}"; then
        printf 'ready-log'
        return 0
    fi

    if vpn_middle_pod_has_handshake "${pod_name}"; then
        printf 'wg-handshake'
        return 0
    fi

    return 1
}

vpn_wait_ready_log() {
    local deployment_name=$1
    local timeout_seconds=${2:-60}
    local deadline

    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        if grep -q "vpn service ready:" < <("${KUBECTL:-kubectl}" logs -n "${VPN_NAMESPACE}" "deployment/${deployment_name}" -c "${VPN_MIDDLE_CONTAINER}" 2>/dev/null || true); then
            return 0
        fi
        sleep "${VPN_READY_POLL_SECONDS}"
    done

    echo "timed out waiting for vpn service ready log from ${deployment_name}" >&2
    return 1
}

vpn_wait_initial_middle_ready() {
    local timeout_seconds=${1:-${VPN_READY_TIMEOUT_SECONDS}}
    local deadline poll_seconds
    local encrypt_pod decrypt_pod
    local encrypt_ready_log=0 decrypt_ready_log=0

    deadline=$((SECONDS + timeout_seconds))
    poll_seconds="${VPN_READY_POLL_SECONDS}"

    while (( SECONDS < deadline )); do
        encrypt_pod="$(vpn_encrypt_pod_name)"
        decrypt_pod="$(vpn_decrypt_pod_name)"

        if (( encrypt_ready_log == 0 )) && vpn_middle_pod_has_ready_log "${encrypt_pod}"; then
            encrypt_ready_log=1
        fi
        if (( decrypt_ready_log == 0 )) && vpn_middle_pod_has_ready_log "${decrypt_pod}"; then
            decrypt_ready_log=1
        fi

        if (( encrypt_ready_log == 1 && decrypt_ready_log == 1 )); then
            log_info "vpn initial ready confirmed via ready-log: encrypt pod=${encrypt_pod}; decrypt pod=${decrypt_pod}"
            return 0
        fi

        sleep "${poll_seconds}"
    done

    log_warn "vpn initial ready-log incomplete within ${timeout_seconds}s: encrypt=${encrypt_ready_log} decrypt=${decrypt_ready_log}; falling back to middle runtime readiness"
    vpn_wait_middle_runtime_ready "${timeout_seconds}"
}

vpn_wait_middle_runtime_ready() {
    local timeout_seconds=${1:-${VPN_READY_TIMEOUT_SECONDS}}
    local deadline poll_seconds
    local encrypt_pod decrypt_pod
    local encrypt_ready_source="" decrypt_ready_source=""

    deadline=$((SECONDS + timeout_seconds))
    poll_seconds="${VPN_READY_POLL_SECONDS}"

    while (( SECONDS < deadline )); do
        encrypt_pod="$(vpn_encrypt_pod_name)"
        decrypt_pod="$(vpn_decrypt_pod_name)"
        encrypt_ready_source="$(vpn_middle_pod_ready_source "${encrypt_pod}" 2>/dev/null || true)"
        decrypt_ready_source="$(vpn_middle_pod_ready_source "${decrypt_pod}" 2>/dev/null || true)"

        if [[ -n "${encrypt_ready_source}" && -n "${decrypt_ready_source}" ]]; then
            log_info "vpn middle runtime ready: encrypt pod=${encrypt_pod} source=${encrypt_ready_source}; decrypt pod=${decrypt_pod} source=${decrypt_ready_source}"
            return 0
        fi

        sleep "${poll_seconds}"
    done

    log_warn "vpn middle runtime readiness timed out: encrypt pod=${encrypt_pod:-<none>} source=${encrypt_ready_source:-missing}; decrypt pod=${decrypt_pod:-<none>} source=${decrypt_ready_source:-missing}"
    return 1
}

vpn_client_route_get_output() {
    local client_pod=$1

    vpn_exec_sh_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" "ip route get ${VPN_TARGET_IPV4}" 2>/dev/null || true
}

vpn_client_has_nsm_interface() {
    local client_pod=$1

    vpn_exec_sh_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" 'ip link show dev nsm-1 >/dev/null 2>&1'
}

vpn_client_route_uses_nsm() {
    local client_pod=$1
    local route_get_output

    route_get_output="$(vpn_client_route_get_output "${client_pod}")"
    grep -Eq '(^|[[:space:]])dev[[:space:]]nsm-1([[:space:]]|$)' <<<"${route_get_output}"
}

vpn_log_client_network_state() {
    local phase=$1
    local client_pod

    client_pod="$(vpn_client_pod_name)"
    if [[ -z "${client_pod}" ]]; then
        log_warn "vpn client network snapshot (${phase}) skipped: client pod not found"
        return 1
    fi

    log_info "vpn client network snapshot (${phase}) pod=${client_pod} target=${VPN_TARGET_IPV4}"
    log_info "client ip -o link show (${phase})"
    vpn_exec_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" ip -o link show || true
    log_info "client ip addr (${phase})"
    vpn_exec_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" ip addr || true
    log_info "client ip route (${phase})"
    vpn_exec_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" ip route || true
    log_info "client ip route get ${VPN_TARGET_IPV4} (${phase})"
    vpn_exec_in_pod "${client_pod}" "${VPN_CLIENT_CONTAINER}" ip route get "${VPN_TARGET_IPV4}" || true
}

vpn_wait_client_target_route_ready() {
    local timeout_seconds=${1:-${VPN_CLIENT_ROUTE_TIMEOUT_SECONDS}}
    local deadline poll_seconds settle_seconds
    local client_pod route_get_output=""

    deadline=$((SECONDS + timeout_seconds))
    poll_seconds="${VPN_READY_POLL_SECONDS}"
    settle_seconds="${VPN_ROUTE_SETTLE_SECONDS}"

    while (( SECONDS < deadline )); do
        client_pod="$(vpn_client_pod_name)"

        if [[ -n "${client_pod}" ]] && vpn_client_has_nsm_interface "${client_pod}" && vpn_client_route_uses_nsm "${client_pod}"; then
            route_get_output="$(vpn_client_route_get_output "${client_pod}")"
            log_info "vpn client target route ready: pod=${client_pod} route=${route_get_output}"
            if (( settle_seconds > 0 )); then
                sleep "${settle_seconds}"
            fi
            return 0
        fi

        sleep "${poll_seconds}"
    done

    log_warn "vpn client route readiness timed out for target ${VPN_TARGET_IPV4}; expected nsm-1 path"
    vpn_log_client_network_state "route-timeout" || true
    return 1
}

vpn_wait_ready() {
    local timeout=${1:-180s}

    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_ENCRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_DECRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_ENCRYPT_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_DECRYPT_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_CLIENT_POD_SELECTOR}" "${timeout}"
    vpn_wait_initial_middle_ready "${VPN_READY_TIMEOUT_SECONDS}"
}

vpn_wait_recovery_ready() {
    local timeout=${1:-180s}

    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_ENCRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_DECRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_ENCRYPT_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_DECRYPT_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_CLIENT_POD_SELECTOR}" "${timeout}"
    vpn_wait_middle_runtime_ready "${VPN_READY_TIMEOUT_SECONDS}"
    vpn_wait_client_target_route_ready "${VPN_CLIENT_ROUTE_TIMEOUT_SECONDS}"
}

vpn_encrypt_pod_name() {
    k8s_get_first_pod_name "${VPN_NAMESPACE}" "${VPN_ENCRYPT_POD_SELECTOR}"
}

vpn_decrypt_pod_name() {
    k8s_get_first_pod_name "${VPN_NAMESPACE}" "${VPN_DECRYPT_POD_SELECTOR}"
}

vpn_server_pod_name() {
    k8s_get_first_pod_name "${VPN_NAMESPACE}" "${VPN_SERVER_POD_SELECTOR}"
}

vpn_client_pod_name() {
    k8s_get_first_pod_name "${VPN_NAMESPACE}" "${VPN_CLIENT_POD_SELECTOR}"
}

vpn_run_verify_smoke() {
    NS_NAMESPACE="${VPN_NAMESPACE}" \
    TARGET_IP="${VPN_TARGET_IPV4}" \
    TCP_SECONDS="${VPN_TCP_SECONDS}" \
    UDP_SECONDS="${VPN_UDP_SECONDS}" \
    RUN_PING_CHECK="${VPN_VERIFY_PING}" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${VPN_VERIFY_SCRIPT}"
}

vpn_scale_client_down() {
    local timeout=${1:-120s}
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" scale "deployment/${VPN_CLIENT_DEPLOYMENT_NAME}" -n "${VPN_NAMESPACE}" --replicas=0 >/dev/null
    "${kubectl_bin}" wait --for=delete pod -l "${VPN_CLIENT_POD_SELECTOR}" -n "${VPN_NAMESPACE}" --timeout="${timeout}" >/dev/null 2>&1 || true
}

vpn_scale_deployment() {
    local deployment_name=$1
    local replicas=$2
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" scale "deployment/${deployment_name}" -n "${VPN_NAMESPACE}" --replicas="${replicas}" >/dev/null
}

vpn_wait_role_pods_deleted() {
    local selector=$1
    local timeout=${2:-120s}
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" wait --for=delete pod -l "${selector}" -n "${VPN_NAMESPACE}" --timeout="${timeout}" >/dev/null 2>&1 || true
}

vpn_scale_server_down() {
    local timeout=${1:-120s}

    vpn_scale_deployment "${VPN_SERVER_DEPLOYMENT_NAME}" 0
    vpn_wait_role_pods_deleted "${VPN_SERVER_POD_SELECTOR}" "${timeout}"
}

vpn_scale_middle_down() {
    local timeout=${1:-120s}

    vpn_scale_deployment "${VPN_ENCRYPT_DEPLOYMENT_NAME}" 0
    vpn_scale_deployment "${VPN_DECRYPT_DEPLOYMENT_NAME}" 0
    vpn_wait_role_pods_deleted "${VPN_ENCRYPT_POD_SELECTOR}" "${timeout}"
    vpn_wait_role_pods_deleted "${VPN_DECRYPT_POD_SELECTOR}" "${timeout}"
}

vpn_scale_middle_up() {
    local timeout=${1:-180s}

    vpn_scale_deployment "${VPN_DECRYPT_DEPLOYMENT_NAME}" 1
    vpn_scale_deployment "${VPN_ENCRYPT_DEPLOYMENT_NAME}" 1
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_DECRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_ENCRYPT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_DECRYPT_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_ENCRYPT_POD_SELECTOR}" "${timeout}"
}

vpn_scale_server_up() {
    local timeout=${1:-180s}

    vpn_scale_deployment "${VPN_SERVER_DEPLOYMENT_NAME}" 1
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_SERVER_POD_SELECTOR}" "${timeout}"
}

vpn_scale_client_up() {
    local timeout=${1:-180s}

    vpn_scale_deployment "${VPN_CLIENT_DEPLOYMENT_NAME}" 1
    k8s_wait_deployment_available "${VPN_NAMESPACE}" "${VPN_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${VPN_NAMESPACE}" "${VPN_CLIENT_POD_SELECTOR}" "${timeout}"
}

vpn_run_cleanup_check() {
    NS_NAMESPACE="${VPN_NAMESPACE}" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${VPN_CLEANUP_SCRIPT}"
}
