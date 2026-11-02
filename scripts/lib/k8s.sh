#!/usr/bin/env bash

if [[ -n "${NSM_OVS_K8S_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_K8S_SH_LOADED=1

k8s_config_exec() {
    local kubectl_bin=${KUBECTL_BIN_REAL:-kubectl}
    local -a kubectl_args=()

    if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
        kubectl_args+=(--kubeconfig "${KUBECONFIG_PATH}")
    fi

    "${kubectl_bin}" "${kubectl_args[@]}" "$@"
}

k8s_cluster_reachable() {
    local kubectl_bin=${KUBECTL:-kubectl}
    "${kubectl_bin}" cluster-info >/dev/null 2>&1
}

k8s_require_cluster() {
    local kubectl_bin=${KUBECTL:-kubectl}

    require_command "${kubectl_bin}"

    if ! k8s_cluster_reachable; then
        die "cannot reach the Kubernetes cluster via ${kubectl_bin} (profile=${CLUSTER_PROFILE:-unknown} context=${KUBECTL_CONTEXT:-ambient})"
    fi
}

k8s_config_current_context() {
    k8s_config_exec config current-context 2>/dev/null || true
}

k8s_context_exists() {
    local context_name=$1
    [[ -n "${context_name}" ]] || return 1

    k8s_config_exec config get-contexts -o name 2>/dev/null | grep -Fxq "${context_name}"
}

k8s_current_context() {
    if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
        printf '%s\n' "${KUBECTL_CONTEXT}"
    else
        k8s_config_current_context
    fi
}

k8s_log_context() {
    local current_context kubeconfig_label context_label

    current_context="$(k8s_current_context)"
    kubeconfig_label="${KUBECONFIG_PATH:-<ambient>}"
    context_label="${KUBECTL_CONTEXT:-${current_context:-<unresolved>}}"

    log_info "cluster profile: ${CLUSTER_PROFILE:-unknown}"
    log_info "kubeconfig: ${kubeconfig_label}"
    log_info "kubectl context: ${context_label}"
    [[ -n "${KUBECTL:-}" ]] && log_info "kubectl command: ${KUBECTL}"
}

k8s_namespace_exists() {
    local kubectl_bin=${KUBECTL:-kubectl}
    local namespace=$1

    "${kubectl_bin}" get namespace "${namespace}" >/dev/null 2>&1
}

k8s_node_exists() {
    local kubectl_bin=${KUBECTL:-kubectl}
    local node_name=$1

    "${kubectl_bin}" get node "${node_name}" >/dev/null 2>&1
}

k8s_node_is_ready() {
    local kubectl_bin=${KUBECTL:-kubectl}
    local node_name=$1
    local ready_status

    ready_status="$("${kubectl_bin}" get node "${node_name}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    [[ "${ready_status}" == "True" ]]
}

k8s_node_is_schedulable() {
    local kubectl_bin=${KUBECTL:-kubectl}
    local node_name=$1
    local unschedulable

    unschedulable="$("${kubectl_bin}" get node "${node_name}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
    [[ "${unschedulable}" != "true" ]]
}

k8s_wait_deployment_available() {
    local namespace=$1
    local deployment_name=$2
    local timeout=${3:-120s}
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" rollout status "deployment/${deployment_name}" -n "${namespace}" --timeout="${timeout}"
}

k8s_wait_pods_ready() {
    local namespace=$1
    local selector=$2
    local timeout=${3:-120s}
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" wait --for=condition=Ready --timeout="${timeout}" pod -l "${selector}" -n "${namespace}"
}

k8s_get_first_pod_name() {
    local namespace=$1
    local selector=$2
    local kubectl_bin=${KUBECTL:-kubectl}

    "${kubectl_bin}" get pods -n "${namespace}" -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

k8s_wait_namespace_deletion() {
    local namespace=$1
    local timeout=${2:-180s}
    local kubectl_bin=${KUBECTL:-kubectl}

    if ! k8s_namespace_exists "${namespace}"; then
        log_info "namespace already absent: ${namespace}"
        return 0
    fi

    if "${kubectl_bin}" wait --for=delete "namespace/${namespace}" --timeout="${timeout}" >/dev/null 2>&1; then
        log_success "namespace deleted: ${namespace}"
    else
        log_warn "namespace may still be terminating: ${namespace}"
    fi
}

k8s_exec() {
    local kubectl_bin=${KUBECTL:-kubectl}
    "${kubectl_bin}" exec "$@"
}
