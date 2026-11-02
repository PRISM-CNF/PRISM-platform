#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

port_forward_pid=""
health_file=""
ready_file=""
query_file=""
port_forward_log=""

cleanup_tmp() {
    if [[ -n "${port_forward_pid}" ]] && kill -0 "${port_forward_pid}" >/dev/null 2>&1; then
        kill "${port_forward_pid}" >/dev/null 2>&1 || true
        wait "${port_forward_pid}" >/dev/null 2>&1 || true
    fi
    [[ -n "${health_file}" && -f "${health_file}" ]] && rm -f "${health_file}"
    [[ -n "${ready_file}" && -f "${ready_file}" ]] && rm -f "${ready_file}"
    [[ -n "${query_file}" && -f "${query_file}" ]] && rm -f "${query_file}"
    [[ -n "${port_forward_log}" && -f "${port_forward_log}" ]] && rm -f "${port_forward_log}"
}

trap cleanup_tmp EXIT

main() {
    local pvc_phase probe_id write_payload query_expr

    require_command "${KUBECTL}"
    require_command curl
    require_command jq
    require_command mktemp
    require_cluster
    ensure_repo_layout

    namespace_exists || die "namespace not found: ${NAMESPACE}"
    statefulset_exists || die "statefulset not found: ${STATEFULSET_NAME}"
    service_exists || die "service not found: ${SERVICE_NAME}"
    headless_service_exists || die "headless service not found: ${HEADLESS_SERVICE_NAME}"
    pvc_exists || die "pvc not found: ${PVC_NAME}"

    pvc_phase="$("${KUBECTL}" get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
    [[ "${pvc_phase}" == "Bound" ]] || die "pvc phase is not Bound: ${PVC_NAME} => ${pvc_phase}"

    log_info "waiting for statefulset rollout: ${STATEFULSET_NAME}"
    if ! "${KUBECTL}" rollout status statefulset/"${STATEFULSET_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"; then
        dump_component_state
        die "statefulset rollout failed"
    fi

    "${KUBECTL}" wait --for=condition=Ready pod -l "${APP_SELECTOR}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}" >/dev/null

    port_forward_log="$(mktemp)"
    health_file="$(mktemp)"
    ready_file="$(mktemp)"
    query_file="$(mktemp)"

    log_info "port-forwarding service/${SERVICE_NAME} to localhost:${PORT_FORWARD_LOCAL_PORT}"
    "${KUBECTL}" -n "${NAMESPACE}" port-forward service/"${SERVICE_NAME}" \
        "${PORT_FORWARD_LOCAL_PORT}:${HTTP_PORT}" >"${port_forward_log}" 2>&1 &
    port_forward_pid=$!

    for _ in $(seq 1 30); do
        if curl -fsS --max-time 3 "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/health" >"${health_file}" \
            && curl -fsS --max-time 3 "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/-/ready" >"${ready_file}"; then
            break
        fi
        sleep 1
    done

    [[ -s "${health_file}" ]] || {
        log_error "unable to fetch /health"
        cat "${port_forward_log}" || true
        dump_component_state
        die "health endpoint check failed"
    }
    [[ -s "${ready_file}" ]] || {
        log_error "unable to fetch /-/ready"
        cat "${port_forward_log}" || true
        dump_component_state
        die "ready endpoint check failed"
    }

    grep -Fxq 'OK' "${health_file}" || {
        log_error "unexpected /health response"
        cat "${health_file}" || true
        die "unexpected health response"
    }

    grep -Fq 'VictoriaMetrics is Ready.' "${ready_file}" || {
        log_error "unexpected /-/ready response"
        cat "${ready_file}" || true
        die "unexpected ready response"
    }

    probe_id="$(date +%s)"
    write_payload="nsm_ovs_vm_smoke{component=\"victoriametrics-k8s\",probe_id=\"${probe_id}\"} 123"

    log_info "writing smoke sample via /api/v1/import/prometheus"
    curl -fsS -X POST --data-binary "${write_payload}" \
        "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/api/v1/import/prometheus" >/dev/null

    query_expr="nsm_ovs_vm_smoke{component=\"victoriametrics-k8s\",probe_id=\"${probe_id}\"}"
    for _ in $(seq 1 30); do
        if curl -fsSG "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/api/v1/query" \
            --data-urlencode "query=${query_expr}" >"${query_file}" \
            && jq -e --arg probe_id "${probe_id}" '
                .status == "success" and
                (.data.result | length) >= 1 and
                any(.data.result[]; .metric.probe_id == $probe_id and .value[1] == "123")
            ' "${query_file}" >/dev/null; then
            break
        fi
        sleep 1
    done

    jq -e --arg probe_id "${probe_id}" '
        .status == "success" and
        (.data.result | length) >= 1 and
        any(.data.result[]; .metric.probe_id == $probe_id and .value[1] == "123")
    ' "${query_file}" >/dev/null || {
        log_error "query verification failed"
        cat "${query_file}" || true
        dump_component_state
        die "write/query smoke verification failed"
    }

    log_success "victoria metrics is healthy and passed write/query smoke verification"
    print_statefulset_summary
    print_service_summary
    print_pvc_summary
    print_pod_summary
}

main "$@"

