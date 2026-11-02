#!/usr/bin/env bash

if [[ -n "${NSM_OVS_BASIC_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_BASIC_SH_LOADED=1

basic_spire_namespace() {
    printf '%s\n' "${SPIRE_NAMESPACE:-spire}"
}

basic_nsm_system_namespace() {
    printf '%s\n' "${NSM_SYSTEM_NAMESPACE:-nsm-system}"
}

basic_forwarder_namespace() {
    printf '%s\n' "${BASIC_FORWARDER_NAMESPACE:-$(basic_nsm_system_namespace)}"
}

basic_forwarder_daemonset_name() {
    printf '%s\n' "${BASIC_FORWARDER_DAEMONSET_NAME:-forwarder-ovs}"
}

basic_registry_service_name() {
    printf '%s\n' "${BASIC_REGISTRY_SERVICE_NAME:-registry}"
}

basic_registry_service_port() {
    printf '%s\n' "${BASIC_REGISTRY_SERVICE_PORT:-5002}"
}

basic_legacy_spire_postgres_deployment_name() {
    printf '%s\n' "spire-postgres"
}

basic_legacy_spire_postgres_service_name() {
    printf '%s\n' "spire-postgres"
}

basic_spire_server_statefulset_name() {
    printf '%s\n' "spire-server"
}

basic_spire_server_service_name() {
    printf '%s\n' "spire-server"
}

basic_exp_wpool_label_key() {
    printf '%s\n' "${BASIC_EXP_WPOOL_LABEL_KEY:-exp.wpool}"
}

basic_exp_wpool_label_value() {
    printf '%s\n' "${BASIC_EXP_WPOOL_LABEL_VALUE:-true}"
}

basic_expected_wpool_nodes() {
    printf '%s\n' "${BASIC_EXP_WPOOL_NODES:-nsm-lab-w01 nsm-lab-w02}"
}

basic_expected_local_nodes() {
    printf '%s\n' "${BASIC_EXP_LOCAL_NODES:-node01 node02}"
}

basic_expected_runtime_nodes() {
    printf '%s\n' "${BASIC_EXP_RUNTIME_NODES:-node01 node02 nsm-lab-w01 nsm-lab-w02}"
}

basic_expected_agent_nodes() {
    printf '%s\n' "${BASIC_EXP_AGENT_NODES:-node01 node02 nsm-lab-w01 nsm-lab-w02}"
}

basic_allowed_wpool_namespaces() {
    printf '%s\n' "${BASIC_EXP_WPOOL_ALLOWED_NAMESPACES:-spire nsm-system kube-system kubevirt}"
}

basic_pcm_deployment_mode() {
    printf '%s\n' "${PCM_DEPLOYMENT_MODE:-in-cluster}"
}

basic_pcm_incluster_gate_enabled() {
    [[ "$(basic_pcm_deployment_mode)" == "in-cluster" ]]
}

basic_array_contains() {
    local needle=$1
    shift
    local item

    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done

    return 1
}

basic_list_expected_wpool_nodes() {
    local node

    for node in $(basic_expected_wpool_nodes); do
        printf '%s\n' "${node}" 2>/dev/null || return 0
    done
}

basic_list_expected_local_nodes() {
    local node

    for node in $(basic_expected_local_nodes); do
        printf '%s\n' "${node}" 2>/dev/null || return 0
    done
}

basic_list_expected_runtime_nodes() {
    local node

    for node in $(basic_expected_runtime_nodes); do
        printf '%s\n' "${node}" 2>/dev/null || return 0
    done
}

basic_list_expected_agent_nodes() {
    local node

    for node in $(basic_expected_agent_nodes); do
        printf '%s\n' "${node}" 2>/dev/null || return 0
    done
}

basic_list_allowed_wpool_namespaces() {
    local namespace

    for namespace in $(basic_allowed_wpool_namespaces); do
        printf '%s\n' "${namespace}" 2>/dev/null || return 0
    done
}

basic_node_is_expected_wpool() {
    local node=$1
    local expected_node

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        [[ "${node}" == "${expected_node}" ]] && return 0
    done < <(basic_list_expected_wpool_nodes)

    return 1
}

basic_node_is_expected_local() {
    local node=$1
    local expected_node

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        [[ "${node}" == "${expected_node}" ]] && return 0
    done < <(basic_list_expected_local_nodes)

    return 1
}

basic_node_is_expected_runtime() {
    local node=$1
    local expected_node

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        [[ "${node}" == "${expected_node}" ]] && return 0
    done < <(basic_list_expected_runtime_nodes)

    return 1
}

basic_node_is_expected_agent() {
    local node=$1
    local expected_node

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        [[ "${node}" == "${expected_node}" ]] && return 0
    done < <(basic_list_expected_agent_nodes)

    return 1
}

basic_namespace_allowed_on_wpool() {
    local namespace=$1
    local allowed_namespace

    while IFS= read -r allowed_namespace; do
        [[ -n "${allowed_namespace}" ]] || continue
        [[ "${namespace}" == "${allowed_namespace}" ]] && return 0
    done < <(basic_list_allowed_wpool_namespaces)

    return 1
}

basic_require_dir() {
    local dir_path=$1
    [[ -d "${dir_path}" ]] || die "required directory not found: ${dir_path}"
}

basic_require_file() {
    local file_path=$1
    [[ -f "${file_path}" ]] || die "required file not found: ${file_path}"
}

basic_validate_kustomization() {
    local dir_path=$1
    log_info "render check: ${dir_path}"
    "${KUBECTL}" kustomize "${dir_path}" >/dev/null
}

basic_wait_for_pods() {
    local namespace=$1
    local selector=$2
    local timeout=$3

    log_info "waiting for pods in namespace=${namespace} selector=${selector} timeout=${timeout}"
    if "${KUBECTL}" wait --for=condition=Ready --timeout="${timeout}" pod -l "${selector}" -n "${namespace}"; then
        log_success "pods are ready for selector=${selector}"
    else
        log_error "pods did not become ready for selector=${selector}"
        "${KUBECTL}" get pods -n "${namespace}" -o wide || true
        exit 1
    fi
}

basic_namespace_exists() {
    local namespace=$1
    k8s_namespace_exists "${namespace}"
}

basic_registry_endpoint_ip() {
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" get endpoints "$(basic_registry_service_name)" \
        -n "$(basic_nsm_system_namespace)" \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}

basic_current_nsmgr_registry_endpoint() {
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" get daemonset nsmgr \
        -n "$(basic_nsm_system_namespace)" \
        -o jsonpath='{range .spec.template.spec.containers[?(@.name=="nsmgr")].env[?(@.name=="NSM_REGISTRY_URL")]}{.value}{end}' 2>/dev/null || true
}

basic_configure_nsmgr_registry_endpoint() {
    local kubectl_bin=${KUBECTL:-kubectl}
    local registry_ip current_target desired_target

    registry_ip="$(basic_registry_endpoint_ip)"
    [[ -n "${registry_ip}" ]] || die "failed to resolve endpoint IP for service/$(basic_registry_service_name) in namespace $(basic_nsm_system_namespace)"

    desired_target="tcp://${registry_ip}:$(basic_registry_service_port)"
    current_target="$(basic_current_nsmgr_registry_endpoint)"

    if [[ "${current_target}" == "${desired_target}" ]]; then
        log_info "nsmgr registry endpoint already set to ${desired_target}"
        return 0
    fi

    log_info "configuring nsmgr registry endpoint: ${desired_target}"
    "${kubectl_bin}" set env daemonset/nsmgr \
        -n "$(basic_nsm_system_namespace)" \
        "NSM_REGISTRY_URL=${desired_target}" >/dev/null
}

basic_check_selector_ready() {
    local namespace=$1
    local selector=$2
    local label=$3
    local pod_names

    pod_names=$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o name 2>/dev/null || true)
    if [[ -z "${pod_names}" ]]; then
        log_warn "missing pods for ${label} in namespace=${namespace} selector=${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    if "${KUBECTL}" wait --for=condition=Ready --timeout="${CHECK_TIMEOUT}" pod -l "${selector}" -n "${namespace}" >/dev/null 2>&1; then
        log_success "ready: ${label}"
    else
        log_warn "not ready within ${CHECK_TIMEOUT}: ${label}"
        BASIC_OVERALL_STATUS=1
    fi
}

basic_check_rollout_ready() {
    local namespace=$1
    local resource=$2
    local label=$3

    if "${KUBECTL}" rollout status "${resource}" -n "${namespace}" --timeout="${CHECK_TIMEOUT}" >/dev/null 2>&1; then
        log_success "ready: ${label}"
    else
        log_warn "rollout not complete within ${CHECK_TIMEOUT}: ${label}"
        BASIC_OVERALL_STATUS=1
    fi
}

basic_check_expected_wpool_nodes() {
    local selector expected_node actual_node
    local -a expected_nodes=() actual_nodes=() missing_nodes=() extra_nodes=()

    selector="$(basic_exp_wpool_label_key)=$(basic_exp_wpool_label_value)"
    mapfile -t expected_nodes < <(basic_list_expected_wpool_nodes)
    mapfile -t actual_nodes < <("${KUBECTL}" get nodes -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [[ "${#actual_nodes[@]}" -eq 0 ]]; then
        log_warn "no nodes matched ${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    for expected_node in "${expected_nodes[@]}"; do
        [[ -n "${expected_node}" ]] || continue
        if ! basic_array_contains "${expected_node}" "${actual_nodes[@]}"; then
            missing_nodes+=("${expected_node}")
        fi
    done

    for actual_node in "${actual_nodes[@]}"; do
        [[ -n "${actual_node}" ]] || continue
        if ! basic_array_contains "${actual_node}" "${expected_nodes[@]}"; then
            extra_nodes+=("${actual_node}")
        fi
    done

    if [[ "${#missing_nodes[@]}" -gt 0 || "${#extra_nodes[@]}" -gt 0 ]]; then
        log_warn "unexpected exp.wpool nodes: expected=$(basic_expected_wpool_nodes) actual=${actual_nodes[*]}"
        if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
            log_warn "missing exp.wpool nodes: ${missing_nodes[*]}"
        fi
        if [[ "${#extra_nodes[@]}" -gt 0 ]]; then
            log_warn "extra exp.wpool nodes: ${extra_nodes[*]}"
        fi
        BASIC_OVERALL_STATUS=1
    else
        log_success "exp.wpool nodes match expected set: ${actual_nodes[*]}"
    fi
}

basic_check_expected_local_nodes() {
    local expected_node
    local -a missing_nodes=()

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        if ! "${KUBECTL}" get node "${expected_node}" >/dev/null 2>&1; then
            missing_nodes+=("${expected_node}")
        fi
    done < <(basic_list_expected_local_nodes)

    if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
        log_warn "expected collection nodes are missing: ${missing_nodes[*]}"
        BASIC_OVERALL_STATUS=1
    else
        log_success "collection nodes are present: $(basic_expected_local_nodes)"
    fi
}

basic_check_expected_runtime_nodes() {
    local expected_node
    local -a missing_nodes=()

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        if ! "${KUBECTL}" get node "${expected_node}" >/dev/null 2>&1; then
            missing_nodes+=("${expected_node}")
        fi
    done < <(basic_list_expected_runtime_nodes)

    if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
        log_warn "expected experiment runtime nodes are missing: ${missing_nodes[*]}"
        BASIC_OVERALL_STATUS=1
    else
        log_success "experiment runtime nodes are present: $(basic_expected_runtime_nodes)"
    fi
}

basic_check_expected_agent_nodes() {
    local expected_node
    local -a missing_nodes=()

    while IFS= read -r expected_node; do
        [[ -n "${expected_node}" ]] || continue
        if ! "${KUBECTL}" get node "${expected_node}" >/dev/null 2>&1; then
            missing_nodes+=("${expected_node}")
        fi
    done < <(basic_list_expected_agent_nodes)

    if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
        log_warn "expected SPIRE agent nodes are missing: ${missing_nodes[*]}"
        BASIC_OVERALL_STATUS=1
    else
        log_success "SPIRE agent nodes are present: $(basic_expected_agent_nodes)"
    fi
}

basic_check_selector_on_expected_wpool() {
    local namespace=$1
    local selector=$2
    local label=$3
    local require_all_expected=${4:-false}
    local placement_output pod_name node_name expected_node
    local -a invalid_placements=() pending_pods=() seen_nodes=() missing_nodes=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "missing pod placements for ${label} in namespace=${namespace} selector=${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue

        if [[ -z "${node_name}" ]]; then
            pending_pods+=("${pod_name}")
            continue
        fi

        seen_nodes+=("${node_name}")
        if ! basic_node_is_expected_wpool "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#pending_pods[@]}" -gt 0 ]]; then
        log_warn "pods are not yet scheduled for ${label}: ${pending_pods[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods are outside expected exp.wpool nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${require_all_expected}" == "true" ]]; then
        while IFS= read -r expected_node; do
            [[ -n "${expected_node}" ]] || continue
            if ! basic_array_contains "${expected_node}" "${seen_nodes[@]}"; then
                missing_nodes+=("${expected_node}")
            fi
        done < <(basic_list_expected_wpool_nodes)

        if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
            log_warn "expected exp.wpool nodes are missing ${label}: ${missing_nodes[*]}"
            BASIC_OVERALL_STATUS=1
        fi
    fi

    if [[ "${#pending_pods[@]}" -eq 0 && "${#invalid_placements[@]}" -eq 0 && "${#missing_nodes[@]}" -eq 0 ]]; then
        log_success "placement ok: ${label}"
    fi
}

basic_check_selector_on_expected_local_nodes() {
    local namespace=$1
    local selector=$2
    local label=$3
    local require_all_expected=${4:-false}
    local placement_output pod_name node_name expected_node
    local -a invalid_placements=() pending_pods=() seen_nodes=() missing_nodes=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "missing pod placements for ${label} in namespace=${namespace} selector=${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue

        if [[ -z "${node_name}" ]]; then
            pending_pods+=("${pod_name}")
            continue
        fi

        seen_nodes+=("${node_name}")
        if ! basic_node_is_expected_local "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#pending_pods[@]}" -gt 0 ]]; then
        log_warn "pods are not yet scheduled for ${label}: ${pending_pods[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods are outside expected collection nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${require_all_expected}" == "true" ]]; then
        while IFS= read -r expected_node; do
            [[ -n "${expected_node}" ]] || continue
            if ! basic_array_contains "${expected_node}" "${seen_nodes[@]}"; then
                missing_nodes+=("${expected_node}")
            fi
        done < <(basic_list_expected_local_nodes)

        if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
            log_warn "expected collection nodes are missing ${label}: ${missing_nodes[*]}"
            BASIC_OVERALL_STATUS=1
        fi
    fi

    if [[ "${#pending_pods[@]}" -eq 0 && "${#invalid_placements[@]}" -eq 0 && "${#missing_nodes[@]}" -eq 0 ]]; then
        log_success "placement ok: ${label}"
    fi
}

basic_check_selector_on_expected_runtime_nodes() {
    local namespace=$1
    local selector=$2
    local label=$3
    local require_all_expected=${4:-false}
    local placement_output pod_name node_name expected_node
    local -a invalid_placements=() pending_pods=() seen_nodes=() missing_nodes=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "missing pod placements for ${label} in namespace=${namespace} selector=${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue

        if [[ -z "${node_name}" ]]; then
            pending_pods+=("${pod_name}")
            continue
        fi

        seen_nodes+=("${node_name}")
        if ! basic_node_is_expected_runtime "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#pending_pods[@]}" -gt 0 ]]; then
        log_warn "pods are not yet scheduled for ${label}: ${pending_pods[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods are outside expected experiment runtime nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${require_all_expected}" == "true" ]]; then
        while IFS= read -r expected_node; do
            [[ -n "${expected_node}" ]] || continue
            if ! basic_array_contains "${expected_node}" "${seen_nodes[@]}"; then
                missing_nodes+=("${expected_node}")
            fi
        done < <(basic_list_expected_runtime_nodes)

        if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
            log_warn "expected experiment runtime nodes are missing ${label}: ${missing_nodes[*]}"
            BASIC_OVERALL_STATUS=1
        fi
    fi

    if [[ "${#pending_pods[@]}" -eq 0 && "${#invalid_placements[@]}" -eq 0 && "${#missing_nodes[@]}" -eq 0 ]]; then
        log_success "placement ok: ${label}"
    fi
}

basic_check_selector_on_expected_agent_nodes() {
    local namespace=$1
    local selector=$2
    local label=$3
    local require_all_expected=${4:-false}
    local placement_output pod_name node_name expected_node
    local -a invalid_placements=() pending_pods=() seen_nodes=() missing_nodes=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "missing pod placements for ${label} in namespace=${namespace} selector=${selector}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue

        if [[ -z "${node_name}" ]]; then
            pending_pods+=("${pod_name}")
            continue
        fi

        seen_nodes+=("${node_name}")
        if ! basic_node_is_expected_agent "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#pending_pods[@]}" -gt 0 ]]; then
        log_warn "pods are not yet scheduled for ${label}: ${pending_pods[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods are outside expected SPIRE agent nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${require_all_expected}" == "true" ]]; then
        while IFS= read -r expected_node; do
            [[ -n "${expected_node}" ]] || continue
            if ! basic_array_contains "${expected_node}" "${seen_nodes[@]}"; then
                missing_nodes+=("${expected_node}")
            fi
        done < <(basic_list_expected_agent_nodes)

        if [[ "${#missing_nodes[@]}" -gt 0 ]]; then
            log_warn "expected SPIRE agent nodes are missing ${label}: ${missing_nodes[*]}"
            BASIC_OVERALL_STATUS=1
        fi
    fi

    if [[ "${#pending_pods[@]}" -eq 0 && "${#invalid_placements[@]}" -eq 0 && "${#missing_nodes[@]}" -eq 0 ]]; then
        log_success "placement ok: ${label}"
    fi
}

basic_check_namespace_stays_off_expected_wpool() {
    local namespace=$1
    local label=$2
    local placement_output pod_name node_name
    local -a invalid_placements=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "namespace has no pods to validate: ${label}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue
        if [[ -n "${node_name}" ]] && basic_node_is_expected_wpool "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods unexpectedly landed on exp.wpool nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    else
        log_success "placement ok: ${label} stayed off exp.wpool nodes"
    fi
}

basic_check_namespace_on_expected_local_nodes() {
    local namespace=$1
    local label=$2
    local placement_output pod_name node_name
    local -a invalid_placements=() pending_pods=()

    placement_output=$("${KUBECTL}" get pods -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${placement_output}" ]]; then
        log_warn "namespace has no pods to validate: ${label}"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    while IFS=$'\t' read -r pod_name node_name; do
        [[ -n "${pod_name}" ]] || continue

        if [[ -z "${node_name}" ]]; then
            pending_pods+=("${pod_name}")
            continue
        fi

        if ! basic_node_is_expected_local "${node_name}"; then
            invalid_placements+=("${pod_name}@${node_name}")
        fi
    done <<< "${placement_output}"

    if [[ "${#pending_pods[@]}" -gt 0 ]]; then
        log_warn "pods are not yet scheduled for ${label}: ${pending_pods[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#invalid_placements[@]}" -gt 0 ]]; then
        log_warn "pods are outside expected collection nodes for ${label}: ${invalid_placements[*]}"
        BASIC_OVERALL_STATUS=1
    fi

    if [[ "${#pending_pods[@]}" -eq 0 && "${#invalid_placements[@]}" -eq 0 ]]; then
        log_success "placement ok: ${label}"
    fi
}

basic_check_no_unexpected_wpool_pods() {
    local pod_inventory namespace pod_name node_name phase
    local -a unexpected_pods=()

    pod_inventory=$("${KUBECTL}" get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase --no-headers 2>/dev/null || true)
    while read -r namespace pod_name node_name phase; do
        [[ -n "${namespace}" ]] || continue
        if basic_node_is_expected_wpool "${node_name}" && ! basic_namespace_allowed_on_wpool "${namespace}"; then
            unexpected_pods+=("${namespace}/${pod_name}@${node_name}:${phase}")
        fi
    done <<< "${pod_inventory}"

    if [[ "${#unexpected_pods[@]}" -gt 0 ]]; then
        log_warn "unexpected namespaces on exp.wpool nodes: ${unexpected_pods[*]}"
        BASIC_OVERALL_STATUS=1
    else
        log_success "no unexpected namespaces are running on exp.wpool nodes"
    fi
}

basic_check_protected_system_workloads() {
    if basic_namespace_exists "node-feature-discovery"; then
        basic_check_rollout_ready "node-feature-discovery" "daemonset/nfd-worker" "node-feature-discovery nfd-worker"
        basic_check_rollout_ready "node-feature-discovery" "deployment/nfd-master" "node-feature-discovery nfd-master"
        basic_check_rollout_ready "node-feature-discovery" "deployment/nfd-gc" "node-feature-discovery nfd-gc"
        basic_check_namespace_on_expected_local_nodes "node-feature-discovery" "node-feature-discovery"
    else
        log_warn "namespace not found: node-feature-discovery"
        BASIC_OVERALL_STATUS=1
    fi

    if basic_namespace_exists "intel-pcm"; then
        if basic_pcm_incluster_gate_enabled; then
            basic_check_rollout_ready "intel-pcm" "daemonset/intel-pcm" "intel-pcm daemonset"
            basic_check_namespace_on_expected_local_nodes "intel-pcm" "intel-pcm"
        else
            log_info "skipping intel-pcm protected workload gate because PCM_DEPLOYMENT_MODE=$(basic_pcm_deployment_mode)"
        fi
    else
        if basic_pcm_incluster_gate_enabled; then
            log_warn "namespace not found: intel-pcm"
            BASIC_OVERALL_STATUS=1
        else
            log_info "intel-pcm namespace absent while PCM_DEPLOYMENT_MODE=$(basic_pcm_deployment_mode); not treated as blocker"
        fi
    fi
}

basic_check_forwarder_rollout() {
    local forwarder_namespace forwarder_daemonset

    forwarder_namespace="$(basic_forwarder_namespace)"
    forwarder_daemonset="$(basic_forwarder_daemonset_name)"

    if "${KUBECTL}" rollout status "daemonset/${forwarder_daemonset}" -n "${forwarder_namespace}" --timeout="${CHECK_TIMEOUT}" >/dev/null 2>&1; then
        log_success "ready: daemonset/${forwarder_daemonset}"
    else
        log_warn "${forwarder_daemonset} rollout not complete within ${CHECK_TIMEOUT}"
        BASIC_OVERALL_STATUS=1
    fi
}

basic_check_workload_ids() {
    if "${KUBECTL}" get clusterspiffeid nsm-workloads nsm-workloads-webhook >/dev/null 2>&1; then
        log_success "present: ClusterSPIFFEIDs for NSM workloads"
    else
        log_warn "ClusterSPIFFEIDs for NSM workloads are missing or not readable"
        BASIC_OVERALL_STATUS=1
    fi
}

basic_delete_legacy_spire_postgres_resources() {
    local namespace
    namespace="$(basic_spire_namespace)"

    if ! basic_namespace_exists "${namespace}"; then
        return 0
    fi

    "${KUBECTL}" delete deployment "$(basic_legacy_spire_postgres_deployment_name)" -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
    "${KUBECTL}" delete service "$(basic_legacy_spire_postgres_service_name)" -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
}

basic_check_legacy_spire_postgres_absent() {
    local namespace
    namespace="$(basic_spire_namespace)"

    if ! basic_namespace_exists "${namespace}"; then
        return 0
    fi

    if "${KUBECTL}" get deployment "$(basic_legacy_spire_postgres_deployment_name)" -n "${namespace}" >/dev/null 2>&1; then
        log_warn "unexpected legacy spire-postgres deployment is still present"
        BASIC_OVERALL_STATUS=1
    else
        log_success "absent: legacy spire-postgres deployment"
    fi

    if "${KUBECTL}" get service "$(basic_legacy_spire_postgres_service_name)" -n "${namespace}" >/dev/null 2>&1; then
        log_warn "unexpected legacy spire-postgres service is still present"
        BASIC_OVERALL_STATUS=1
    else
        log_success "absent: legacy spire-postgres service"
    fi
}

basic_reconcile_spire_server_rollout() {
    local namespace statefulset_name pod_name update_revision pod_revision
    namespace="$(basic_spire_namespace)"
    statefulset_name="$(basic_spire_server_statefulset_name)"
    pod_name="${statefulset_name}-0"

    if ! basic_namespace_exists "${namespace}"; then
        return 0
    fi

    if ! "${KUBECTL}" get statefulset "${statefulset_name}" -n "${namespace}" >/dev/null 2>&1; then
        return 0
    fi

    update_revision="$("${KUBECTL}" get statefulset "${statefulset_name}" -n "${namespace}" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)"
    pod_revision="$("${KUBECTL}" get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)"

    if [[ -n "${update_revision}" && -n "${pod_revision}" && "${pod_revision}" != "${update_revision}" ]]; then
        log_warn "spire-server pod is still on old revision (${pod_revision}); deleting ${pod_name} to pick up ${update_revision}"
        "${KUBECTL}" delete pod "${pod_name}" -n "${namespace}" --wait=false >/dev/null
    fi
}

basic_recreate_spire_server_for_storage_contract() {
    local namespace statefulset_name live_claim_templates
    namespace="$(basic_spire_namespace)"
    statefulset_name="$(basic_spire_server_statefulset_name)"

    if ! basic_namespace_exists "${namespace}"; then
        return 0
    fi

    if ! "${KUBECTL}" get statefulset "${statefulset_name}" -n "${namespace}" >/dev/null 2>&1; then
        return 0
    fi

    live_claim_templates=$("${KUBECTL}" get statefulset "${statefulset_name}" -n "${namespace}" -o jsonpath='{range .spec.volumeClaimTemplates[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [[ -n "${live_claim_templates}" ]]; then
        log_warn "recreating statefulset/${statefulset_name} to switch sqlite data from PVC to emptyDir"
        "${KUBECTL}" delete statefulset "${statefulset_name}" -n "${namespace}" --wait=true >/dev/null
    fi
}

basic_recreate_spire_server_service_for_network_contract() {
    local namespace service_name cluster_ip
    namespace="$(basic_spire_namespace)"
    service_name="$(basic_spire_server_service_name)"

    if ! basic_namespace_exists "${namespace}"; then
        return 0
    fi

    if ! "${KUBECTL}" get service "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
        return 0
    fi

    cluster_ip=$("${KUBECTL}" get service "${service_name}" -n "${namespace}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [[ "${cluster_ip}" == "None" ]]; then
        log_warn "recreating service/${service_name} to restore ClusterIP service discovery for split basic placement"
        "${KUBECTL}" delete service "${service_name}" -n "${namespace}" --wait=true >/dev/null
    fi
}

basic_print_namespace_pods() {
    local namespace=$1

    if basic_namespace_exists "${namespace}"; then
        log_info "pods in namespace=${namespace}"
        "${KUBECTL}" get pods -n "${namespace}" -o wide || true
    else
        log_warn "namespace not found: ${namespace}"
        BASIC_OVERALL_STATUS=1
    fi
}

basic_show_ovs_state() {
    local forwarder_pod forwarder_namespace

    forwarder_namespace="$(basic_forwarder_namespace)"

    forwarder_pod=$("${KUBECTL}" get pods -n "${forwarder_namespace}" -l "app=$(basic_forwarder_daemonset_name)" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${forwarder_pod}" ]]; then
        log_warn "cannot show OVS state because no $(basic_forwarder_daemonset_name) pod was found"
        BASIC_OVERALL_STATUS=1
        return 0
    fi

    log_info "ovs-vsctl show from pod=${forwarder_pod}"
    "${KUBECTL}" exec -n "${forwarder_namespace}" "${forwarder_pod}" -- ovs-vsctl show
}

basic_print_banner() {
    printf '%s\n' '╔═══════════════════════════════════════════════════════╗'
    printf '%s\n' '║                                                       ║'
    printf '%s\n' '║     NSM OVS Basic Kernel-Only Bring-up               ║'
    printf '%s\n' '║                                                       ║'
    printf '%s\n' '║     SPIRE + nsmgr + registry + webhook + OVS         ║'
    printf '%s\n' '║                                                       ║'
    printf '%s\n' '╚═══════════════════════════════════════════════════════╝'
}

basic_warn_ignored_legacy_env() {
    local env_name=$1

    if [[ -n "${!env_name:-}" ]]; then
        log_warn "${env_name} is ignored in kernel-only mode; deploy flow no longer gates on smartnic.config"
    fi
}

basic_init_context() {
    local asset_root=$1

    [[ -n "${asset_root}" ]] || die "basic asset root is required"

    BASIC_ASSET_ROOT="${asset_root}"
    BASIC_MANIFESTS_DIR="${BASIC_ASSET_ROOT}/manifests"
    BASIC_WRAPPERS_DIR="${BASIC_ASSET_ROOT}/wrappers"
    BASIC_VENDOR_ROOT="${BASIC_ASSET_ROOT}/vendor/deployment-k8s"
    BASIC_SPIRE_CORE_DIR="${BASIC_MANIFESTS_DIR}/spire/core"
    BASIC_SPIRE_WORKLOAD_IDS_DIR="${BASIC_MANIFESTS_DIR}/spire/workload-ids"
    BASIC_OVS_BASIC_DIR="${BASIC_MANIFESTS_DIR}/ovs-basic"
}

basic_require_runtime_assets() {
    basic_require_dir "${BASIC_ASSET_ROOT}"
    basic_require_dir "${BASIC_MANIFESTS_DIR}"
    basic_require_dir "${BASIC_VENDOR_ROOT}"
    basic_require_dir "${BASIC_SPIRE_CORE_DIR}"
    basic_require_dir "${BASIC_SPIRE_WORKLOAD_IDS_DIR}"
    basic_require_dir "${BASIC_OVS_BASIC_DIR}"
    basic_require_file "${BASIC_SPIRE_CORE_DIR}/kustomization.yaml"
    basic_require_file "${BASIC_SPIRE_WORKLOAD_IDS_DIR}/kustomization.yaml"
    basic_require_file "${BASIC_OVS_BASIC_DIR}/kustomization.yaml"
}

basic_deploy_usage() {
    cat <<'EOF'
Usage: deploy.sh
EOF
}

basic_status_usage() {
    cat <<'EOF'
Usage: status.sh [options]

Options:
  --check-kernel2kernel   also check the ns-kernel2kernel namespace
  --show-ovs              run ovs-vsctl show in a forwarder pod
  -h, --help              show this help
EOF
}

basic_cleanup_usage() {
    cat <<'EOF'
Usage: cleanup.sh [options]

Options:
  -f, --force        skip confirmation
  --delete-crds      delete NSM and SPIRE CRDs
  -h, --help         show this help
EOF
}

basic_confirm_cleanup() {
    if [[ "${FORCE}" == "true" ]]; then
        return 0
    fi

    printf '\n'
    log_warn "this will remove SPIRE and NSM OVS basic resources"
    printf '  - namespace %s\n' "$(basic_spire_namespace)"
    printf '  - namespace %s\n' "$(basic_nsm_system_namespace)"
    printf '%s\n' '  - ClusterSPIFFEIDs for NSM workloads'
    printf '%s\n' '  - NSM and SPIRE webhooks'
    if [[ "${DELETE_CRDS}" == "true" ]]; then
        printf '%s\n' '  - NSM and SPIRE CRDs'
    fi
    printf '\n'

    read -r -p "continue? [y/N]: " reply
    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
        log_info "cleanup cancelled"
        exit 0
    fi
}

basic_delete_kustomization_if_possible() {
    local dir_path=$1

    if [[ -d "${dir_path}" ]]; then
        if "${KUBECTL}" kustomize "${dir_path}" >/dev/null 2>&1; then
            "${KUBECTL}" delete -k "${dir_path}" --ignore-not-found=true || true
        else
            log_warn "skipping kustomize delete because render failed: ${dir_path}"
        fi
    fi
}

basic_delete_known_resources() {
    "${KUBECTL}" delete clusterspiffeid nsm-workloads nsm-workloads-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete mutatingwebhookconfiguration nsm-mutating-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete validatingwebhookconfiguration spire-controller-manager-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete namespace "$(basic_nsm_system_namespace)" --ignore-not-found=true || true
    "${KUBECTL}" delete namespace "$(basic_spire_namespace)" --ignore-not-found=true || true
}

basic_delete_crds_if_requested() {
    if [[ "${DELETE_CRDS}" != "true" ]]; then
        log_info "skipping CRD deletion"
        return 0
    fi

    log_info "deleting NSM and SPIRE CRDs"
    "${KUBECTL}" delete crd networkservices.networkservicemesh.io --ignore-not-found=true || true
    "${KUBECTL}" delete crd networkserviceendpoints.networkservicemesh.io --ignore-not-found=true || true
    "${KUBECTL}" delete crd clusterspiffeids.spire.spiffe.io --ignore-not-found=true || true
    "${KUBECTL}" delete crd clusterfederatedtrustdomains.spire.spiffe.io --ignore-not-found=true || true
    "${KUBECTL}" delete crd clusterstaticentries.spire.spiffe.io --ignore-not-found=true || true
    "${KUBECTL}" delete crd controllermanagerconfigs.spire.spiffe.io --ignore-not-found=true || true
}

basic_deploy_from_assets() {
    local asset_root=$1
    shift

    [[ $# -eq 0 ]] || {
        basic_deploy_usage >&2
        die "deploy.sh does not accept arguments"
    }

    basic_init_context "${asset_root}"
    basic_require_runtime_assets

    KUBECTL="${KUBECTL:-kubectl}"
    WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
    SKIP_WAIT="${SKIP_WAIT:-false}"

    basic_warn_ignored_legacy_env "SMARTNIC_CONFIG_PATH"
    basic_warn_ignored_legacy_env "ALLOW_MISSING_SMARTNIC_CONFIG"

    basic_print_banner

    log_info "step 1/6: preflight"
    require_command "${KUBECTL}"
    k8s_require_cluster

    basic_validate_kustomization "${BASIC_SPIRE_CORE_DIR}"
    basic_validate_kustomization "${BASIC_SPIRE_WORKLOAD_IDS_DIR}"
    basic_validate_kustomization "${BASIC_OVS_BASIC_DIR}"

    log_success "preflight checks passed"
    log_info "runtime assets root: ${BASIC_ASSET_ROOT}"
    log_info "vendored deployment-k8s source: ${BASIC_VENDOR_ROOT}"
    log_info "kernel-only default: smartnic.config is not required by this script"
    log_info "advanced SR-IOV / SmartVF remains outside this deploy flow"

    log_info "step 2/6: apply SPIRE core"
    log_info "postgres-free SPIRE mode: deleting legacy spire-postgres resources if they exist"
    basic_delete_legacy_spire_postgres_resources
    basic_recreate_spire_server_service_for_network_contract
    basic_recreate_spire_server_for_storage_contract
    "${KUBECTL}" apply -k "${BASIC_SPIRE_CORE_DIR}"
    basic_reconcile_spire_server_rollout

    if [[ "${SKIP_WAIT}" != "true" ]]; then
        log_info "step 3/6: wait for SPIRE"
        sleep 5
        basic_wait_for_pods "$(basic_spire_namespace)" "app=spire-server" "${WAIT_TIMEOUT}"
        basic_wait_for_pods "$(basic_spire_namespace)" "app=spire-agent" "${WAIT_TIMEOUT}"
        "${KUBECTL}" get pods -n "$(basic_spire_namespace)" -o wide
    else
        log_warn "SKIP_WAIT=true, skipping SPIRE readiness waits"
    fi

    log_info "step 4/6: apply SPIRE workload IDs"
    "${KUBECTL}" apply -k "${BASIC_SPIRE_WORKLOAD_IDS_DIR}"
    "${KUBECTL}" get clusterspiffeid nsm-workloads nsm-workloads-webhook || true

    log_info "step 5/6: apply OVS basic stack"
    "${KUBECTL}" apply -k "${BASIC_OVS_BASIC_DIR}"

    if [[ "${SKIP_WAIT}" != "true" ]]; then
        log_info "step 6/6: wait for NSM OVS stack"
        sleep 5
        basic_wait_for_pods "$(basic_nsm_system_namespace)" "app=registry" "${WAIT_TIMEOUT}"
        basic_configure_nsmgr_registry_endpoint
        basic_wait_for_pods "$(basic_nsm_system_namespace)" "app=admission-webhook-k8s" "${WAIT_TIMEOUT}"
        basic_wait_for_pods "$(basic_nsm_system_namespace)" "app=nsmgr" "${WAIT_TIMEOUT}"
        basic_wait_for_pods "$(basic_forwarder_namespace)" "app=$(basic_forwarder_daemonset_name)" "${WAIT_TIMEOUT}"
        "${KUBECTL}" get pods -n "$(basic_nsm_system_namespace)" -o wide
    else
        log_warn "SKIP_WAIT=true, skipping NSM readiness waits"
    fi

    printf '\n'
    log_success "kernel-only OVS basic manifests have been applied from platform assets"
    log_info "next suggested check: kubectl get pods -n $(basic_nsm_system_namespace) -o wide"
}

basic_status_from_assets() {
    local asset_root=$1
    shift

    basic_init_context "${asset_root}"
    basic_require_runtime_assets

    KUBECTL="${KUBECTL:-kubectl}"
    CHECK_TIMEOUT="${CHECK_TIMEOUT:-5s}"
    SHOW_OVS="${SHOW_OVS:-false}"
    CHECK_KERNEL2KERNEL="${CHECK_KERNEL2KERNEL:-false}"
    BASIC_OVERALL_STATUS=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check-kernel2kernel)
                CHECK_KERNEL2KERNEL=true
                shift
                ;;
            --show-ovs)
                SHOW_OVS=true
                shift
                ;;
            -h|--help)
                basic_status_usage
                exit 0
                ;;
            *)
                basic_status_usage >&2
                die "unknown argument: $1"
                ;;
        esac
    done

    log_info "step 1/6: local preflight"
    require_command "${KUBECTL}"
    k8s_require_cluster

    basic_validate_kustomization "${BASIC_SPIRE_CORE_DIR}"
    basic_validate_kustomization "${BASIC_SPIRE_WORKLOAD_IDS_DIR}"
    basic_validate_kustomization "${BASIC_OVS_BASIC_DIR}"
    log_success "local runtime assets render successfully"

    log_info "step 2/6: SPIRE status"
    basic_print_namespace_pods "$(basic_spire_namespace)"
    if basic_namespace_exists "$(basic_spire_namespace)"; then
        basic_check_selector_ready "$(basic_spire_namespace)" "app=spire-server" "spire-server"
        basic_check_selector_ready "$(basic_spire_namespace)" "app=spire-agent" "spire-agent"
        basic_check_legacy_spire_postgres_absent
    fi

    log_info "step 3/6: NSM OVS status"
    basic_print_namespace_pods "$(basic_nsm_system_namespace)"
    if basic_namespace_exists "$(basic_nsm_system_namespace)"; then
        basic_check_selector_ready "$(basic_nsm_system_namespace)" "app=registry" "registry-k8s"
        basic_check_selector_ready "$(basic_nsm_system_namespace)" "app=admission-webhook-k8s" "admission-webhook-k8s"
        basic_check_selector_ready "$(basic_nsm_system_namespace)" "app=nsmgr" "nsmgr"
        basic_check_selector_ready "$(basic_forwarder_namespace)" "app=$(basic_forwarder_daemonset_name)" "$(basic_forwarder_daemonset_name)"
        basic_check_forwarder_rollout
        "${KUBECTL}" get daemonset -n "$(basic_forwarder_namespace)" "$(basic_forwarder_daemonset_name)" -o wide || true
    fi
    basic_check_workload_ids

    log_info "step 4/6: node placement"
    basic_check_expected_local_nodes
    basic_check_expected_runtime_nodes
    basic_check_expected_agent_nodes
    basic_check_expected_wpool_nodes
    if basic_namespace_exists "$(basic_spire_namespace)"; then
        basic_check_selector_on_expected_wpool "$(basic_spire_namespace)" "app=spire-server" "spire-server"
        basic_check_selector_on_expected_agent_nodes "$(basic_spire_namespace)" "app=spire-agent" "spire-agent" "true"
    fi
    if basic_namespace_exists "$(basic_nsm_system_namespace)"; then
        basic_check_selector_on_expected_wpool "$(basic_nsm_system_namespace)" "app=registry" "registry-k8s"
        basic_check_selector_on_expected_wpool "$(basic_nsm_system_namespace)" "app=admission-webhook-k8s" "admission-webhook-k8s"
        basic_check_selector_on_expected_runtime_nodes "$(basic_nsm_system_namespace)" "app=nsmgr" "nsmgr" "true"
        basic_check_selector_on_expected_runtime_nodes "$(basic_forwarder_namespace)" "app=$(basic_forwarder_daemonset_name)" "$(basic_forwarder_daemonset_name)" "true"
    fi
    basic_check_no_unexpected_wpool_pods

    log_info "step 5/6: protected system workloads"
    basic_check_protected_system_workloads

    log_info "step 6/6: optional use-case status"
    if basic_namespace_exists "ns-kernel2kernel"; then
        basic_print_namespace_pods "ns-kernel2kernel"
        basic_check_selector_ready "ns-kernel2kernel" "app=alpine" "Kernel2Kernel alpine"
        basic_check_selector_ready "ns-kernel2kernel" "app=nse-kernel" "Kernel2Kernel nse-kernel"
    elif [[ "${CHECK_KERNEL2KERNEL}" == "true" ]]; then
        log_warn "namespace not found: ns-kernel2kernel"
        BASIC_OVERALL_STATUS=1
    else
        log_info "Kernel2Kernel namespace not present, skipping use-case checks"
    fi

    if [[ "${SHOW_OVS}" == "true" ]]; then
        basic_show_ovs_state
    fi

    printf '\n'
    if [[ "${BASIC_OVERALL_STATUS}" -eq 0 ]]; then
        log_success "OVS basic baseline looks healthy"
    else
        log_warn "OVS basic baseline has one or more gaps"
    fi

    exit "${BASIC_OVERALL_STATUS}"
}

basic_cleanup_from_assets() {
    local asset_root=$1
    shift

    basic_init_context "${asset_root}"
    basic_require_runtime_assets

    FORCE=false
    DELETE_CRDS=false
    KUBECTL="${KUBECTL:-kubectl}"
    WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE=true
                shift
                ;;
            --delete-crds)
                DELETE_CRDS=true
                shift
                ;;
            -h|--help)
                basic_cleanup_usage
                exit 0
                ;;
            *)
                basic_cleanup_usage >&2
                die "unknown argument: $1"
                ;;
        esac
    done

    log_info "step 1/4: preflight"
    require_command "${KUBECTL}"
    k8s_require_cluster

    basic_confirm_cleanup

    log_info "step 2/4: delete OVS basic stack"
    basic_delete_kustomization_if_possible "${BASIC_OVS_BASIC_DIR}"
    "${KUBECTL}" delete mutatingwebhookconfiguration nsm-mutating-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete namespace "$(basic_nsm_system_namespace)" --ignore-not-found=true || true
    k8s_wait_namespace_deletion "$(basic_nsm_system_namespace)" "${WAIT_TIMEOUT}"

    log_info "step 3/4: delete SPIRE stack"
    basic_delete_kustomization_if_possible "${BASIC_SPIRE_WORKLOAD_IDS_DIR}"
    basic_delete_kustomization_if_possible "${BASIC_SPIRE_CORE_DIR}"
    basic_delete_legacy_spire_postgres_resources
    "${KUBECTL}" delete clusterspiffeid nsm-workloads nsm-workloads-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete validatingwebhookconfiguration spire-controller-manager-webhook --ignore-not-found=true || true
    "${KUBECTL}" delete namespace "$(basic_spire_namespace)" --ignore-not-found=true || true
    k8s_wait_namespace_deletion "$(basic_spire_namespace)" "${WAIT_TIMEOUT}"

    log_info "step 4/4: final cleanup"
    basic_delete_known_resources
    basic_delete_crds_if_requested

    printf '\n'
    log_success "cleanup flow finished"
}
