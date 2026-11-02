#!/usr/bin/env bash

if [[ -n "${NSM_OVS_LB_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_LB_SH_LOADED=1

lb_init_runtime_context() {
    LB_RUNTIME_ROOT="${LB_ASSETS_ROOT}"
    LB_K8S_DIR="${LB_K8S_ASSETS_DIR}"
    LB_VERIFY_SCRIPT="${LB_VERIFY_ASSET_SCRIPT}"
}

lb_init_context() {
    lb_init_runtime_context
}

lb_require_runtime_assets() {
    [[ -d "${LB_K8S_ASSETS_DIR}" ]] || die "lb k8s directory not found: ${LB_K8S_ASSETS_DIR}"
    [[ -f "${LB_K8S_ASSETS_DIR}/kustomization.yaml" ]] || die "lb kustomization not found: ${LB_K8S_ASSETS_DIR}/kustomization.yaml"
    [[ -x "${LB_VERIFY_ASSET_SCRIPT}" ]] || die "lb verify script not found or not executable: ${LB_VERIFY_ASSET_SCRIPT}"
}

lb_basic_allowed_wpool_namespaces() {
    local allowed_namespaces

    allowed_namespaces="${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
    if [[ -n "${LB_NAMESPACE:-}" ]]; then
        allowed_namespaces="${allowed_namespaces} ${LB_NAMESPACE}"
    fi

    printf '%s\n' "${allowed_namespaces}"
}

lb_require_basic_ready() {
    local allowed_wpool_namespaces

    log_info "checking basic environment before lb operation"
    if [[ ! -x "${BASIC_STATUS_WRAPPER}" ]]; then
        die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; verify the bundled assets"
    fi

    allowed_wpool_namespaces="$(lb_basic_allowed_wpool_namespaces)"

    if ! BASIC_EXP_WPOOL_ALLOWED_NAMESPACES="${allowed_wpool_namespaces}" "${BASIC_STATUS_WRAPPER}" >/dev/null; then
        if [[ "${NSM_OVS_ALLOW_BASIC_GAPS:-false}" == "true" ]]; then
            log_warn "basic environment check reported gaps before lb operation; continuing because NSM_OVS_ALLOW_BASIC_GAPS=true"
        else
            die "basic environment is not healthy; run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic first"
        fi
    fi
}

lb_render_dir() {
    local render_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" kustomize "${render_dir}" >/dev/null
}

lb_apply_dir() {
    local apply_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    lb_render_dir "${apply_dir}"
    "${kubectl_bin}" apply -k "${apply_dir}"
}

lb_delete_dir() {
    local delete_dir=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    if lb_render_dir "${delete_dir}"; then
        "${kubectl_bin}" delete -k "${delete_dir}" --ignore-not-found=true || true
    else
        log_warn "skipping kustomize delete because render failed: ${delete_dir}"
    fi
}

lb_wait_ready() {
    local timeout=${1:-120s}

    k8s_wait_deployment_available "${LB_NAMESPACE}" "${LB_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${LB_NAMESPACE}" "${LB_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_deployment_available "${LB_NAMESPACE}" "${LB_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${LB_NAMESPACE}" "${LB_MIDDLE_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${LB_NAMESPACE}" "${LB_SERVER_POD_SELECTOR}" "${timeout}"
    k8s_wait_pods_ready "${LB_NAMESPACE}" "${LB_CLIENT_POD_SELECTOR}" "${timeout}"
}

lb_client_pod_name() {
    k8s_get_first_pod_name "${LB_NAMESPACE}" "${LB_CLIENT_POD_SELECTOR}"
}

lb_server_pod_name() {
    k8s_get_first_pod_name "${LB_NAMESPACE}" "${LB_SERVER_POD_SELECTOR}"
}

lb_steering_mode_is_legacy() {
    [[ "${LB_STEERING_MODE:-auto}" == "legacy-inject" ]]
}

lb_client_exec() {
    local client_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    client_pod="$(lb_client_pod_name)"
    [[ -n "${client_pod}" ]] || die "lb client pod not found in namespace ${LB_NAMESPACE}"

    "${kubectl_bin}" exec -n "${LB_NAMESPACE}" "${client_pod}" -c client -- "$@"
}

lb_server_exec() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(lb_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "lb server pod not found in namespace ${LB_NAMESPACE}"

    "${kubectl_bin}" exec -n "${LB_NAMESPACE}" "${server_pod}" -c server -- "$@"
}

lb_is_valid_mac() {
    local mac_value=${1:-}

    [[ "${mac_value}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

lb_normalize_mac() {
    local mac_value=${1:-}
    printf '%s\n' "${mac_value,,}"
}

lb_extract_first_mac() {
    local raw_text=${1:-}
    local mac_value

    mac_value="$(printf '%s\n' "${raw_text}" | grep -Eio '([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}' | head -n1 || true)"
    [[ -n "${mac_value}" ]] || return 1

    mac_value="$(lb_normalize_mac "${mac_value}")"
    lb_is_valid_mac "${mac_value}" || return 1
    printf '%s\n' "${mac_value}"
}

lb_forwarder_pod_on_node() {
    local node_name=$1
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" get pods \
        -n "${BASIC_FORWARDER_NAMESPACE:-${NSM_SYSTEM_NAMESPACE:-nsm-system}}" \
        -l "app=${BASIC_FORWARDER_DAEMONSET_NAME:-forwarder-ovs}" \
        --field-selector "spec.nodeName=${node_name}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

lb_forwarder_exec_on_node() {
    local node_name=$1
    shift

    local forwarder_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    forwarder_pod="$(lb_forwarder_pod_on_node "${node_name}")"
    [[ -n "${forwarder_pod}" ]] || return 1

    "${kubectl_bin}" exec -n "${BASIC_FORWARDER_NAMESPACE:-${NSM_SYSTEM_NAMESPACE:-nsm-system}}" "${forwarder_pod}" -- "$@"
}

lb_legacy_candidate_nodes() {
    local candidate
    local seen=""

    for candidate in "${LB_STACK_CLIENT_NODE:-}" "${LB_STACK_SERVER_NODE:-}"; do
        [[ -n "${candidate}" ]] || continue
        if [[ " ${seen} " == *" ${candidate} "* ]]; then
            continue
        fi
        seen="${seen} ${candidate}"
        printf '%s\n' "${candidate}"
    done
}

lb_log_legacy_context() {
    log_info "lb legacy steering context: service_node=${LB_STACK_VNF_NODE:-unknown} client_node=${LB_STACK_CLIENT_NODE:-unknown} server_node=${LB_STACK_SERVER_NODE:-unknown}"
    log_info "lb legacy steering values: vip=${LB_VIP_IPV4:-unknown} backend=${LB_BACKEND_IPV4:-unknown} service_cidr=${LB_STACK_SERVICE_CIDR:-unknown}"
}

lb_server_data_interface() {
    local server_iface
    local backend_cidr=${LB_SERVER_CIDR_PREFIX:-}

    [[ -n "${backend_cidr}" ]] || return 1

    server_iface="$(
        lb_server_exec sh -eu -c "
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
        if (name ~ /^nse-ovs-lb-/) {
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

lb_try_get_server_mac_from_server_pod() {
    local server_iface
    local server_mac

    server_iface="$(lb_server_data_interface)" || return 1
    server_mac="$(lb_server_exec sh -eu -c "cat '/sys/class/net/${server_iface}/address'" 2>/dev/null || true)"
    server_mac="${server_mac//$'\n'/}"
    server_mac="${server_mac//$'\r'/}"
    [[ -n "${server_mac}" ]] || return 1

    server_mac="$(lb_normalize_mac "${server_mac}")"
    lb_is_valid_mac "${server_mac}" || return 1
    printf '%s\n' "${server_mac}"
}

lb_try_get_server_mac_from_client_neigh() {
    local backend_mac

    lb_client_exec sh -eu -c "ping -c 1 -W 1 '${LB_BACKEND_IPV4}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

    backend_mac="$(
        lb_client_exec sh -eu -c "
set -- \$(ip neigh show dev nsm-1 '${LB_BACKEND_IPV4}' 2>/dev/null || true)
if [ \"\$#\" -ge 3 ] && [ \"\$1\" = '${LB_BACKEND_IPV4}' ] && [ \"\$2\" = 'lladdr' ]; then
    printf '%s\n' \"\$3\"
fi
" 2>/dev/null || true
    )"
    backend_mac="${backend_mac//$'\n'/}"
    backend_mac="${backend_mac//$'\r'/}"
    [[ -n "${backend_mac}" ]] || return 1

    backend_mac="$(lb_normalize_mac "${backend_mac}")"
    lb_is_valid_mac "${backend_mac}" || return 1
    printf '%s\n' "${backend_mac}"
}

lb_try_get_server_mac_from_node_forwarder_ovs() {
    local server_pod
    local node_name
    local interface_dump
    local filtered_lines
    local flow_dump
    local mac_value

    server_pod="$(lb_server_pod_name)"
    [[ -n "${server_pod}" ]] || return 1

    while IFS= read -r node_name; do
        [[ -n "${node_name}" ]] || continue

        interface_dump="$(
            lb_forwarder_exec_on_node "${node_name}" sh -eu -c "
ovs-vsctl --format=table --columns=name,ofport,mac_in_use,external_ids list interface 2>/dev/null || true
" 2>/dev/null || true
        )"

        filtered_lines="$(
            printf '%s\n' "${interface_dump}" | grep -E "${server_pod}|${LB_NAMESPACE}|${LB_STACK_ID}|${LB_BACKEND_IPV4}" || true
        )"
        if mac_value="$(lb_extract_first_mac "${filtered_lines}")"; then
            LB_SERVER_MAC_OVS_NODE="${node_name}"
            printf '%s\n' "${mac_value}"
            return 0
        fi

        flow_dump="$(
            lb_forwarder_exec_on_node "${node_name}" sh -eu -c "
echo '__OVS_SHOW__'
ovs-vsctl show 2>/dev/null || true
echo '__BR_NSM_FLOWS__'
ovs-ofctl dump-flows br-nsm 2>/dev/null || true
" 2>/dev/null || true
        )"
        filtered_lines="$(
            printf '%s\n' "${flow_dump}" | grep -A3 -B3 -F "${LB_BACKEND_IPV4}" || true
        )"
        if mac_value="$(lb_extract_first_mac "${filtered_lines}")"; then
            LB_SERVER_MAC_OVS_NODE="${node_name}"
            printf '%s\n' "${mac_value}"
            return 0
        fi
    done < <(lb_legacy_candidate_nodes)

    return 1
}

lb_log_forwarder_ovs_snapshot_for_node() {
    local node_name=$1
    local forwarder_pod
    local snapshot

    forwarder_pod="$(lb_forwarder_pod_on_node "${node_name}")"
    if [[ -z "${forwarder_pod}" ]]; then
        log_warn "lb legacy steering diagnostics: no forwarder pod found on node ${node_name}"
        return 0
    fi

    log_info "lb legacy steering diagnostics: forwarder snapshot node=${node_name} pod=${forwarder_pod}"
    snapshot="$(
        lb_forwarder_exec_on_node "${node_name}" sh -eu -c "
echo '__OVS_VSCTL_SHOW__'
ovs-vsctl show 2>/dev/null || true
echo '__OVS_INTERFACE_TABLE__'
ovs-vsctl --format=table --columns=name,ofport,mac_in_use,external_ids list interface 2>/dev/null | grep -E '${LB_NAMESPACE}|${LB_STACK_ID}|${LB_BACKEND_IPV4}|${LB_VIP_IPV4}|name|----' || true
echo '__BR_NSM_FLOWS__'
ovs-ofctl dump-flows br-nsm 2>/dev/null | grep -A3 -B3 -F '${LB_BACKEND_IPV4}' || true
" 2>/dev/null || true
    )"
    printf '%s\n' "${snapshot}"
}

lb_log_legacy_diagnostics() {
    local failure_reason=${1:-unknown}
    local server_links
    local server_addrs
    local node_name

    log_warn "lb legacy steering diagnostics triggered: ${failure_reason}"
    lb_log_legacy_context
    lb_log_vip_steering_snapshot "failure-context" "${LB_VIP_IPV4}"

    server_links="$(lb_server_exec sh -eu -c "ip -o link show 2>/dev/null || true" 2>/dev/null || true)"
    server_addrs="$(lb_server_exec sh -eu -c "ip -o -4 addr show 2>/dev/null || true" 2>/dev/null || true)"
    log_info "lb legacy steering diagnostics: server pod links"
    printf '%s\n' "${server_links}"
    log_info "lb legacy steering diagnostics: server pod IPv4 addresses"
    printf '%s\n' "${server_addrs}"

    while IFS= read -r node_name; do
        [[ -n "${node_name}" ]] || continue
        lb_log_forwarder_ovs_snapshot_for_node "${node_name}"
    done < <(lb_legacy_candidate_nodes)
}

lb_resolve_server_mac() {
    local server_mac

    LB_RESOLVED_SERVER_MAC=''
    LB_SERVER_MAC_SOURCE=''
    LB_SERVER_MAC_OVS_NODE=''

    if server_mac="$(lb_try_get_server_mac_from_server_pod)"; then
        LB_RESOLVED_SERVER_MAC="${server_mac}"
        LB_SERVER_MAC_SOURCE='server_pod'
        return 0
    fi

    if server_mac="$(lb_try_get_server_mac_from_client_neigh)"; then
        LB_RESOLVED_SERVER_MAC="${server_mac}"
        LB_SERVER_MAC_SOURCE='client_neigh'
        return 0
    fi

    if server_mac="$(lb_try_get_server_mac_from_node_forwarder_ovs)"; then
        LB_RESOLVED_SERVER_MAC="${server_mac}"
        LB_SERVER_MAC_SOURCE="ovs_fallback:${LB_SERVER_MAC_OVS_NODE:-unknown}"
        return 0
    fi

    return 1
}

lb_log_vip_steering_snapshot() {
    local stage_label=$1
    local vip_ipv4=${2:-${LB_VIP_IPV4}}
    local snapshot

    log_info "lb legacy steering snapshot (${stage_label}) for VIP ${vip_ipv4}"
    snapshot="$(lb_client_exec sh -eu -c "
echo 'ip route get ${vip_ipv4}:'
ip route get '${vip_ipv4}' 2>&1 || true
echo 'ip neigh show dev nsm-1:'
ip neigh show dev nsm-1 2>&1 || true
")"
    printf '%s\n' "${snapshot}"
}

lb_apply_legacy_steering() {
    local server_mac

    lb_log_legacy_context
    lb_log_vip_steering_snapshot "before-inject" "${LB_VIP_IPV4}"
    if ! lb_resolve_server_mac; then
        lb_log_legacy_diagnostics "server-mac-unresolved"
        die "lb legacy steering could not determine server MAC via server_pod, client_neigh, or ovs_fallback"
    fi
    server_mac="${LB_RESOLVED_SERVER_MAC}"
    log_info "lb legacy steering: resolved server MAC source=${LB_SERVER_MAC_SOURCE} mac=${server_mac}"
    log_info "lb legacy steering: injecting VIP ${LB_VIP_IPV4}/32 to nsm-1 with server MAC ${server_mac}"
    lb_client_exec sh -eu -c "
ip route replace '${LB_VIP_IPV4}/32' dev nsm-1
ip neigh replace '${LB_VIP_IPV4}' lladdr '${server_mac}' nud permanent dev nsm-1
"
    lb_log_vip_steering_snapshot "after-inject" "${LB_VIP_IPV4}"
}

lb_refresh_server_then_client() {
    local timeout=${1:-180s}
    local kubectl_bin=${KUBECTL:-kubectl}

    log_info "lb legacy steering mode: refreshing chain in server -> client order"
    "${kubectl_bin}" scale "deployment/${LB_CLIENT_DEPLOYMENT_NAME}" "deployment/${LB_SERVER_DEPLOYMENT_NAME}" -n "${LB_NAMESPACE}" --replicas=0 >/dev/null
    "${kubectl_bin}" wait --for=delete pod -n "${LB_NAMESPACE}" -l "${LB_CLIENT_POD_SELECTOR}" --timeout="${timeout}" >/dev/null 2>&1 || true
    "${kubectl_bin}" wait --for=delete pod -n "${LB_NAMESPACE}" -l "${LB_SERVER_POD_SELECTOR}" --timeout="${timeout}" >/dev/null 2>&1 || true

    "${kubectl_bin}" scale "deployment/${LB_SERVER_DEPLOYMENT_NAME}" -n "${LB_NAMESPACE}" --replicas=1 >/dev/null
    k8s_wait_deployment_available "${LB_NAMESPACE}" "${LB_SERVER_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${LB_NAMESPACE}" "${LB_SERVER_POD_SELECTOR}" "${timeout}"

    "${kubectl_bin}" scale "deployment/${LB_CLIENT_DEPLOYMENT_NAME}" -n "${LB_NAMESPACE}" --replicas=1 >/dev/null
    k8s_wait_deployment_available "${LB_NAMESPACE}" "${LB_CLIENT_DEPLOYMENT_NAME}" "${timeout}"
    k8s_wait_pods_ready "${LB_NAMESPACE}" "${LB_CLIENT_POD_SELECTOR}" "${timeout}"
    log_success "lb legacy steering mode refresh completed"
}

lb_check_client_interface() {
    lb_client_exec ip link show nsm-1 >/dev/null
    lb_client_exec ip addr show nsm-1 >/dev/null
}

lb_try_ping_target() {
    local target_ipv4=$1

    lb_client_exec ping -c 2 "${target_ipv4}"
}

lb_try_ping_server() {
    lb_try_ping_target "${LB_SERVER_IPV4}"
}

lb_try_ping_vip() {
    lb_try_ping_target "${LB_VIP_IPV4}"
}

lb_start_server_iperf_once() {
    local server_pod
    local kubectl_bin=${KUBECTL:-kubectl}

    server_pod="$(lb_server_pod_name)"
    [[ -n "${server_pod}" ]] || die "lb server pod not found in namespace ${LB_NAMESPACE}"

    "${kubectl_bin}" exec -n "${LB_NAMESPACE}" "${server_pod}" -c server -- sh -eu -c '
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

lb_try_iperf_server() {
    lb_start_server_iperf_once
    lb_client_exec sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${LB_SERVER_IPV4}' -p 5201 -t 10"
}

lb_try_iperf_vip() {
    lb_start_server_iperf_once
    lb_client_exec sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${LB_VIP_IPV4}' -p 5201 -t 10"
}

lb_try_verify_script() {
    [[ -x "${LB_VERIFY_SCRIPT}" ]] || return 1
    NS_NAMESPACE="${LB_NAMESPACE}" \
    NSM_SYSTEM_NAMESPACE="${NSM_SYSTEM_NAMESPACE}" \
    CLIENT_POD_PREFIX="${LB_CLIENT_DEPLOYMENT_NAME}-" \
    LB_POD_PREFIX="${LB_DEPLOYMENT_NAME}-" \
    SERVER_POD_PREFIX="${LB_SERVER_DEPLOYMENT_NAME}-" \
    CLIENT_IFACE="nsm-1" \
    CLIENT_CONTAINER="client" \
    CLIENT_CMD_CONTAINER="cmd-nsc" \
    LB_CONTAINER="nse" \
    SERVER_CONTAINER="server" \
    KUBECTL="${KUBECTL:-kubectl}" \
    "${LB_VERIFY_SCRIPT}"
}
