#!/usr/bin/env bash

if [[ -n "${NSM_OVS_NAT_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_NAT_SH_LOADED=1

nat_init_runtime_context() {
    NAT_RUNTIME_ROOT="${NAT_ASSETS_ROOT}"
    NAT_K8S_DIR="${NAT_K8S_ASSETS_DIR}"
    NAT_VERIFY_SCRIPT="${NAT_VERIFY_ASSET_SCRIPT}"
}

nat_init_context() {
    nat_init_runtime_context
}

nat_require_runtime_assets() {
    [[ -d "${NAT_K8S_ASSETS_DIR}" ]] || die "nat k8s directory not found: ${NAT_K8S_ASSETS_DIR}"
    [[ -f "${NAT_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "nat kustomization not found: ${NAT_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${NAT_VERIFY_ASSET_SCRIPT}" ]] || die "nat verify script not found or not executable: ${NAT_VERIFY_ASSET_SCRIPT}"
}

nat_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${NAT_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${NAT_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

nat_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before nat operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(nat_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before nat operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

nat_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

nat_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    nat_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

nat_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if nat_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

nat_wait_ready() {
    local timeout=${1:-120s}

    k8s_wait_deployment_available "${NAT_NAMESPACE}" "${NAT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${NAT_NAMESPACE}" "${NAT_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${NAT_NAMESPACE}" "${NAT_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${NAT_NAMESPACE}" "${NAT_MIDDLE_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${NAT_NAMESPACE}" "${NAT_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${NAT_NAMESPACE}" "${NAT_CLIENT_POD_SELECTOR}" "${timeout}"
}

nat_client_pod_name() {
    k8s_get_first_pod_name "${NAT_NAMESPACE}" "${NAT_CLIENT_POD_SELECTOR}"
}

nat_server_pod_name() {
    k8s_get_first_pod_name "${NAT_NAMESPACE}" "${NAT_SERVER_POD_SELECTOR}"
}

nat_steering_mode_is_legacy() {
    [[ "${NAT_STEERING_MODE:-auto}" == "legacy-inject" ]]
}

nat_client_exec() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(nat_client_pod_name)"
    [[ -n "${client_pod}" ]] || die "nat client pod not found in namespace ${NAT_NAMESPACE}"

    "${kubectl_bin}" exec -n "${NAT_NAMESPACE}" "${client_pod}" -c client -- "$@"
}

nat_server_exec() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(nat_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "nat server pod not found in namespace ${NAT_NAMESPACE}"

    "${kubectl_bin}" exec -n "${NAT_NAMESPACE}" "${server_pod}" -c server -- "$@"
}

nat_is_valid_mac() {
    local mac_value=${1:-}

    [[ "${mac_value}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

nat_normalize_mac() {
    local mac_value=${1:-}
    printf '%s\n' "${mac_value,,}"
}

nat_log_legacy_context() {
    log_info "nat legacy steering context: service_node=${NAT_STACK_VNF_NODE:-unknown} client_node=${NAT_STACK_CLIENT_NODE:-unknown} server_node=${NAT_STACK_SERVER_NODE:-unknown}"
    log_info "nat legacy steering values: virtual_ip=${NAT_VIRTUAL_IPV4:-unknown} virtual_port=${NAT_VIRTUAL_PORT:-unknown} backend_ip=${NAT_BACKEND_IPV4:-unknown} backend_port=${NAT_BACKEND_PORT:-unknown} service_cidr=${NAT_STACK_SERVICE_CIDR:-unknown}"
}

nat_server_data_interface() {
    local server_iface
    local backend_cidr=${NAT_SERVER_CIDR_PREFIX:-}

    [[ -n "${backend_cidr}" ]] || return 1

    server_iface="$(
        nat_server_exec sh -eu -c "
iface=''
if [ -d /sys/class/net/nsm-1 ]; then
    iface='nsm-1'
fi
if [ -z \"\$iface\" ]; then
    iface=\$(ip -o link show | awk -F': ' '
      {
        name = \$2
        sub(/ .*/, \"\", name)
        sub(/@.*/, \"\", name)
        if (name ~ /^nse-ovs-nat-/ || name ~ /^nse-ovs-/) {
          print name
          exit
        }
      }')
fi
if [ -z \"\$iface\" ]; then
    iface=\$(ip -o -4 addr show | awk '\$4 == \"${backend_cidr}\" { sub(/:$/, \"\", \$2); print \$2; exit }')
fi
[ -n \"\$iface\" ]
printf '%s\n' \"\$iface\"
" 2>/dev/null || true
    )"
    server_iface="${server_iface//$'\n'/}"
    server_iface="${server_iface//$'\r'/}"
    [[ -n "${server_iface}" ]] || return 1

    printf '%s\n' "${server_iface}"
}

nat_try_get_server_mac_from_server_pod() {
    local server_iface
    local server_mac

    server_iface="$(nat_server_data_interface)" || return 1
    server_mac="$(nat_server_exec sh -eu -c "cat '/sys/class/net/${server_iface}/address'" 2>/dev/null || true)"
    server_mac="${server_mac//$'\n'/}"
    server_mac="${server_mac//$'\r'/}"
    [[ -n "${server_mac}" ]] || return 1

    server_mac="$(nat_normalize_mac "${server_mac}")"
    nat_is_valid_mac "${server_mac}" || return 1
    printf '%s\n' "${server_mac}"
}

nat_try_get_server_mac_from_client_neigh() {
    local backend_mac

    nat_client_exec sh -eu -c "ping -c 1 -W 1 '${NAT_BACKEND_IPV4}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

    backend_mac="$(
        nat_client_exec sh -eu -c "
set -- \$(ip neigh show dev nsm-1 '${NAT_BACKEND_IPV4}' 2>/dev/null || true)
if [ \"\$#\" -ge 3 ] && [ \"\$1\" = '${NAT_BACKEND_IPV4}' ] && [ \"\$2\" = 'lladdr' ]; then
    printf '%s\n' \"\$3\"
fi
" 2>/dev/null || true
    )"
    backend_mac="${backend_mac//$'\n'/}"
    backend_mac="${backend_mac//$'\r'/}"
    [[ -n "${backend_mac}" ]] || return 1

    backend_mac="$(nat_normalize_mac "${backend_mac}")"
    nat_is_valid_mac "${backend_mac}" || return 1
    printf '%s\n' "${backend_mac}"
}

nat_resolve_server_mac() {
    local server_mac

    NAT_RESOLVED_SERVER_MAC=''
    NAT_SERVER_MAC_SOURCE=''

    if server_mac="$(nat_try_get_server_mac_from_server_pod)"; then
        NAT_RESOLVED_SERVER_MAC="${server_mac}"
        NAT_SERVER_MAC_SOURCE='server_pod'
        return 0
    fi

    if server_mac="$(nat_try_get_server_mac_from_client_neigh)"; then
        NAT_RESOLVED_SERVER_MAC="${server_mac}"
        NAT_SERVER_MAC_SOURCE='client_neigh'
        return 0
    fi

    return 1
}

nat_log_virtual_steering_snapshot() {
    local stage_label=$1
    local target_ipv4=${2:-${NAT_VIRTUAL_IPV4}}
    local snapshot

    log_info "nat legacy steering snapshot (${stage_label}) for virtual IP ${target_ipv4}"
    snapshot="$(
        nat_client_exec sh -eu -c "
echo 'ip route get ${target_ipv4}:'
ip route get '${target_ipv4}' 2>&1 || true
echo 'ip neigh show dev nsm-1:'
ip neigh show dev nsm-1 2>&1 || true
"
    )"
    printf '%s\n' "${snapshot}"
}

nat_apply_legacy_steering() {
    local server_mac

    nat_log_legacy_context
    nat_log_virtual_steering_snapshot "before-inject" "${NAT_VIRTUAL_IPV4}"
    if ! nat_resolve_server_mac; then
        die "nat legacy steering could not determine server MAC via server_pod or client_neigh"
    fi
    server_mac="${NAT_RESOLVED_SERVER_MAC}"
    log_info "nat legacy steering: resolved server MAC source=${NAT_SERVER_MAC_SOURCE} mac=${server_mac}"
    log_info "nat legacy steering: injecting virtual tuple route ${NAT_VIRTUAL_IPV4}/32 to nsm-1 with server MAC ${server_mac}"
    nat_client_exec sh -eu -c "
ip route replace '${NAT_VIRTUAL_IPV4}/32' dev nsm-1
ip neigh replace '${NAT_VIRTUAL_IPV4}' lladdr '${server_mac}' nud permanent dev nsm-1
"
    nat_log_virtual_steering_snapshot "after-inject" "${NAT_VIRTUAL_IPV4}"
}

nat_refresh_server_then_client() {
    local timeout=${1:-180s}
    local kubectl_bin=${KUBECTL:-kubectl}

    log_info "nat legacy steering mode: refreshing chain in server -> client order"

    "${kubectl_bin}" scale "deployment/${NAT_SERVER_DEPLOYMENT_NAME}" -n "${NAT_NAMESPACE}" --replicas=0 >/dev/null
    "${kubectl_bin}" scale "deployment/${NAT_CLIENT_DEPLOYMENT_NAME}" -n "${NAT_NAMESPACE}" --replicas=0 >/dev/null
    "${kubectl_bin}" wait --for=delete pod -n "${NAT_NAMESPACE}" -l "${NAT_SERVER_POD_SELECTOR}" --timeout="${timeout}" >/dev/null 2>&1 || true
    "${kubectl_bin}" wait --for=delete pod -n "${NAT_NAMESPACE}" -l "${NAT_CLIENT_POD_SELECTOR}" --timeout="${timeout}" >/dev/null 2>&1 || true

    "${kubectl_bin}" scale "deployment/${NAT_SERVER_DEPLOYMENT_NAME}" -n "${NAT_NAMESPACE}" --replicas=1 >/dev/null
    k8s_wait_deployment_available "${NAT_NAMESPACE}" "${NAT_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${NAT_NAMESPACE}" "${NAT_SERVER_POD_SELECTOR}" "${timeout}"

    "${kubectl_bin}" scale "deployment/${NAT_CLIENT_DEPLOYMENT_NAME}" -n "${NAT_NAMESPACE}" --replicas=1 >/dev/null
    k8s_wait_deployment_available "${NAT_NAMESPACE}" "${NAT_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${NAT_NAMESPACE}" "${NAT_CLIENT_POD_SELECTOR}" "${timeout}"

    log_success "nat legacy steering mode refresh completed"
}

nat_check_client_interface() {
    nat_client_exec ip link show nsm-1 >/dev/null
    nat_client_exec ip addr show nsm-1 >/dev/null
}

nat_virtual_route_via_nsm() {
    nat_client_exec sh -eu -c "ip route get '${NAT_VIRTUAL_IPV4}' 2>/dev/null | grep -Eq ' dev nsm-1( |$)'"
}

nat_virtual_neigh_present() {
    nat_client_exec sh -eu -c "ip neigh show dev nsm-1 '${NAT_VIRTUAL_IPV4}' 2>/dev/null | grep -Eq '^${NAT_VIRTUAL_IPV4}[[:space:]].*lladdr[[:space:]]'"
}

nat_try_ping_server() {
    nat_client_exec ping -c 2 "${NAT_SERVER_IPV4}"
}

nat_start_server_iperf_once() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(nat_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "nat server pod not found in namespace ${NAT_NAMESPACE}"

    "${kubectl_bin}" exec -n "${NAT_NAMESPACE}" "${server_pod}" -c server -- sh -eu -c "
check_listener() {
    if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ':${NAT_BACKEND_PORT} '; then
        return 0
    fi
    if command -v netstat >/dev/null 2>&1 && netstat -lnt 2>/dev/null | grep -q ':${NAT_BACKEND_PORT} '; then
        return 0
    fi
    return 1
}

if check_listener; then
    exit 0
fi

rm -f /tmp/iperf3-server.log
nohup iperf3 -s -1 -B '${NAT_BACKEND_IPV4}' -p '${NAT_BACKEND_PORT}' >/tmp/iperf3-server.log 2>&1 </dev/null &
sleep 1
check_listener
"
}

nat_try_iperf_server() {
    nat_start_server_iperf_once
    nat_client_exec sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${NAT_BACKEND_IPV4}' -p '${NAT_BACKEND_PORT}' -t 10"
}

nat_try_iperf_virtual_tuple() {
    nat_start_server_iperf_once
    if nat_steering_mode_is_legacy; then
        nat_apply_legacy_steering
    fi
    nat_client_exec sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${NAT_VIRTUAL_IPV4}' -p '${NAT_VIRTUAL_PORT}' -t 10"
}

nat_try_verify_script() {
    [[ -x "${NAT_VERIFY_SCRIPT}" ]] || return 1
    NS_NAMESPACE="${NAT_NAMESPACE}" \
    NSM_SYSTEM_NAMESPACE="${NSM_SYSTEM_NAMESPACE}" \
    CLIENT_POD_PREFIX="${NAT_CLIENT_DEPLOYMENT_NAME}-" \
    NAT_POD_PREFIX="${NAT_DEPLOYMENT_NAME}-" \
    SERVER_POD_PREFIX="${NAT_SERVER_DEPLOYMENT_NAME}-" \
    CLIENT_IFACE="nsm-1" \
    SERVER_IFACE="nsm-1" \
    CLIENT_CONTAINER="client" \
    CLIENT_CMD_CONTAINER="cmd-nsc" \
    NAT_CONTAINER="nse" \
    SERVER_CONTAINER="server" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${NAT_VERIFY_SCRIPT}"
}
