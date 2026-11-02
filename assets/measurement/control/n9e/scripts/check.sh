#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

port_forward_pid=""
vm_port_forward_pid=""
port_forward_log=""
vm_port_forward_log=""
root_headers_file=""
metrics_file=""
query_file=""
helper_manifest=""

cleanup_tmp() {
    if [[ -n "${helper_manifest}" ]]; then
        "${KUBECTL}" delete -f "${helper_manifest}" --ignore-not-found=true >/dev/null 2>&1 || true
    fi
    [[ -n "${helper_manifest}" && -f "${helper_manifest}" ]] && rm -f "${helper_manifest}"

    if [[ -n "${port_forward_pid}" ]] && kill -0 "${port_forward_pid}" >/dev/null 2>&1; then
        kill "${port_forward_pid}" >/dev/null 2>&1 || true
        wait "${port_forward_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${vm_port_forward_pid}" ]] && kill -0 "${vm_port_forward_pid}" >/dev/null 2>&1; then
        kill "${vm_port_forward_pid}" >/dev/null 2>&1 || true
        wait "${vm_port_forward_pid}" >/dev/null 2>&1 || true
    fi

    [[ -n "${port_forward_log}" && -f "${port_forward_log}" ]] && rm -f "${port_forward_log}"
    [[ -n "${vm_port_forward_log}" && -f "${vm_port_forward_log}" ]] && rm -f "${vm_port_forward_log}"
    [[ -n "${root_headers_file}" && -f "${root_headers_file}" ]] && rm -f "${root_headers_file}"
    [[ -n "${metrics_file}" && -f "${metrics_file}" ]] && rm -f "${metrics_file}"
    [[ -n "${query_file}" && -f "${query_file}" ]] && rm -f "${query_file}"
}

trap cleanup_tmp EXIT

render_helper_manifest() {
    local probe_id=$1
    helper_manifest="$(mktemp)"

    cat >"${helper_manifest}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: n9e-e2e-categraf-${probe_id}
  namespace: ${NAMESPACE}
data:
  config.toml: |-
    [global]
    print_configs = false
    hostname = "n9e-e2e"
    omit_hostname = false
    precision = "ms"
    interval = 1
    providers = ["local"]
    disable_usage_report = true

    [global.labels]
    source = "n9e-e2e"
    probe_id = "${probe_id}"

    [log]
    file_name = "stdout"
    max_size = 100
    max_age = 1
    max_backups = 1
    local_time = true
    compress = false

    [writer_opt]
    batch = 200
    chan_size = 1000

    [[writers]]
    url = "http://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${HTTP_PORT}/prometheus/v1/write"
    timeout = 5000
    dial_timeout = 2500
    max_idle_conns_per_host = 10

    [http]
    enable = false
    address = ":9100"
    print_access = false
    run_mode = "release"

    [heartbeat]
    enable = false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: n9e-e2e-categraf-system-${probe_id}
  namespace: ${NAMESPACE}
data:
  system.toml: |-
    collect_user_number = false
---
apiVersion: v1
kind: Pod
metadata:
  name: n9e-e2e-categraf-${probe_id}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: n9e-e2e-categraf
    app.kubernetes.io/component: smoke
spec:
  restartPolicy: Never
  containers:
    - name: categraf
      image: ${CATEGRAF_HELPER_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - name: TZ
          value: Asia/Shanghai
      volumeMounts:
        - name: categraf-config
          mountPath: /etc/categraf/conf/config.toml
          subPath: config.toml
        - name: input-system
          mountPath: /etc/categraf/conf/input.system
  volumes:
    - name: categraf-config
      configMap:
        name: n9e-e2e-categraf-${probe_id}
        items:
          - key: config.toml
            path: config.toml
    - name: input-system
      configMap:
        name: n9e-e2e-categraf-system-${probe_id}
EOF
}

wait_for_http_ready() {
    local url=$1
    local output_file=$2
    local attempt

    for attempt in $(seq 1 40); do
        if curl -fsS --max-time 3 "$url" >"${output_file}"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

main() {
    local pvc_phase config_toml probe_id query_expr

    require_command "${KUBECTL}"
    require_command curl
    require_command jq
    require_command mktemp
    require_cluster
    ensure_repo_layout

    namespace_exists || die "namespace not found: ${NAMESPACE}"
    deployment_exists || die "deployment not found: ${DEPLOYMENT_NAME}"
    service_exists || die "service not found: ${SERVICE_NAME}"
    configmap_exists || die "configmap not found: ${CONFIGMAP_NAME}"
    pvc_exists || die "pvc not found: ${PVC_NAME}"
    vm_service_exists || die "vm backend service not found: ${VM_NAMESPACE}/${VM_SERVICE_NAME}"

    pvc_phase="$("${KUBECTL}" get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
    [[ "${pvc_phase}" == "Bound" ]] || die "pvc phase is not Bound: ${PVC_NAME} => ${pvc_phase}"

    log_info "waiting for deployment rollout: ${DEPLOYMENT_NAME}"
    if ! "${KUBECTL}" rollout status deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"; then
        dump_component_state
        die "deployment rollout failed"
    fi

    "${KUBECTL}" wait --for=condition=Ready pod -l "${APP_SELECTOR}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}" >/dev/null

    config_toml="$("${KUBECTL}" get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.config\.toml}')"
    grep -Fq 'DBType = "sqlite"' <<<"${config_toml}" || die "config does not use sqlite"
    grep -Fq 'RedisType = "miniredis"' <<<"${config_toml}" || die "config does not use miniredis"
    grep -Fq 'ForceUseServerTS = false' <<<"${config_toml}" || die "config does not preserve sender sample timestamps"
    grep -Fq "${VM_REMOTE_WRITE_URL}" <<<"${config_toml}" || die "config does not point to expected VM writer"

    log_info "verified pushgw timestamp semantics: ForceUseServerTS=false (preserve sender sample time)"

    port_forward_log="$(mktemp)"
    vm_port_forward_log="$(mktemp)"
    root_headers_file="$(mktemp)"
    metrics_file="$(mktemp)"
    query_file="$(mktemp)"

    log_info "port-forwarding service/${SERVICE_NAME} to localhost:${PORT_FORWARD_LOCAL_PORT}"
    "${KUBECTL}" -n "${NAMESPACE}" port-forward service/"${SERVICE_NAME}" \
        "${PORT_FORWARD_LOCAL_PORT}:${HTTP_PORT}" >"${port_forward_log}" 2>&1 &
    port_forward_pid=$!

    for _ in $(seq 1 30); do
        if curl -fsS -I --max-time 3 "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/" >"${root_headers_file}" \
            && curl -fsS --max-time 3 "http://127.0.0.1:${PORT_FORWARD_LOCAL_PORT}/metrics" >"${metrics_file}"; then
            break
        fi
        sleep 1
    done

    [[ -s "${root_headers_file}" ]] || {
        log_error "unable to fetch n9e root endpoint"
        cat "${port_forward_log}" || true
        dump_component_state
        die "root endpoint check failed"
    }
    [[ -s "${metrics_file}" ]] || {
        log_error "unable to fetch /metrics"
        cat "${port_forward_log}" || true
        dump_component_state
        die "metrics endpoint check failed"
    }

    grep -Eq '^HTTP/[0-9.]+ (200|302)' "${root_headers_file}" || {
        log_error "unexpected root endpoint response"
        cat "${root_headers_file}" || true
        die "unexpected root endpoint response"
    }

    grep -Fq 'go_goroutines' "${metrics_file}" || {
        log_error "unexpected /metrics response"
        head -n 50 "${metrics_file}" || true
        die "metrics endpoint does not expose process metrics"
    }

    log_info "port-forwarding vm service/${VM_SERVICE_NAME} to localhost:${VM_LOCAL_PORT}"
    "${KUBECTL}" -n "${VM_NAMESPACE}" port-forward service/"${VM_SERVICE_NAME}" \
        "${VM_LOCAL_PORT}:${VM_HTTP_PORT}" >"${vm_port_forward_log}" 2>&1 &
    vm_port_forward_pid=$!

    if ! wait_for_http_ready "http://127.0.0.1:${VM_LOCAL_PORT}/health" "${query_file}"; then
        log_error "unable to reach vm backend /health"
        cat "${vm_port_forward_log}" || true
        die "vm backend is not reachable for e2e verification"
    fi

    probe_id="$(date +%s%N)"
    render_helper_manifest "${probe_id}"

    log_info "creating temporary categraf helper for n9e -> vm smoke"
    "${KUBECTL}" apply -f "${helper_manifest}" >/dev/null

    if ! "${KUBECTL}" wait --for=condition=Ready pod/"n9e-e2e-categraf-${probe_id}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}" >/dev/null; then
        "${KUBECTL}" describe pod "n9e-e2e-categraf-${probe_id}" -n "${NAMESPACE}" || true
        "${KUBECTL}" logs "n9e-e2e-categraf-${probe_id}" -n "${NAMESPACE}" --tail=200 || true
        die "temporary categraf helper failed to become ready"
    fi

    query_expr="{probe_id=\"${probe_id}\"}"
    for _ in $(seq 1 45); do
        if curl -fsSG "http://127.0.0.1:${VM_LOCAL_PORT}/api/v1/query" \
            --data-urlencode "query=${query_expr}" >"${query_file}" \
            && jq -e --arg probe_id "${probe_id}" '
                .status == "success" and
                (.data.result | length) >= 1 and
                any(.data.result[]; .metric.probe_id == $probe_id)
            ' "${query_file}" >/dev/null; then
            break
        fi
        sleep 2
    done

    jq -e --arg probe_id "${probe_id}" '
        .status == "success" and
        (.data.result | length) >= 1 and
        any(.data.result[]; .metric.probe_id == $probe_id)
    ' "${query_file}" >/dev/null || {
        log_error "n9e -> vm smoke query verification failed"
        cat "${query_file}" || true
        "${KUBECTL}" logs "n9e-e2e-categraf-${probe_id}" -n "${NAMESPACE}" --tail=200 || true
        die "e2e write-through verification failed"
    }

    log_success "n9e is healthy and passed n9e -> vm write-through smoke verification"
    print_deployment_summary
    print_service_summary
    print_pvc_summary
    print_pod_summary
}

main "$@"
