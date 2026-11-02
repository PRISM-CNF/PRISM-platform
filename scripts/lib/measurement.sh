#!/usr/bin/env bash

if [[ -n "${NSM_OVS_MEASUREMENT_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_MEASUREMENT_SH_LOADED=1

MEASUREMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${MEASUREMENT_LIB_DIR}/log.sh"
# shellcheck source=/dev/null
source "${MEASUREMENT_LIB_DIR}/time.sh"

measurement_source_host_measurement_libs() {
    # shellcheck source=/dev/null
    source "${MEASUREMENT_LIB_DIR}/../host-measurement/lib/common.sh"
    # shellcheck source=/dev/null
    source "${MEASUREMENT_LIB_DIR}/../host-measurement/lib/contract.sh"
}

measurement_backend() {
    if [[ -n "${MEASUREMENT_BACKEND:-}" ]]; then
        printf '%s\n' "${MEASUREMENT_BACKEND}"
        return 0
    fi

    case "${PCM_DEPLOYMENT_MODE:-in-cluster}" in
        host-transition)
            printf 'node01-host-managed\n'
            ;;
        *)
            printf 'cluster-vm\n'
            ;;
    esac
}

measurement_acceptance_contract() {
    case "$(measurement_backend)" in
        node01-host-managed)
            measurement_source_host_measurement_libs
            hm_measurement_contract_name
            ;;
        *)
            printf 'cluster-vm-v1\n'
            ;;
    esac
}

measurement_required_metric_groups() {
    case "$(measurement_backend)" in
        node01-host-managed)
            measurement_source_host_measurement_libs
            hm_measurement_required_metric_groups
            ;;
        *)
            printf 'cpu,mem,system,net,disk,processes\n'
            ;;
    esac
}

measurement_excluded_metric_groups() {
    case "$(measurement_backend)" in
        node01-host-managed)
            measurement_source_host_measurement_libs
            hm_measurement_excluded_metric_groups
            ;;
        *)
            printf 'n9e-e2e-hosts\n'
            ;;
    esac
}

measurement_preflight_dir() {
    local measurement_root

    if [[ -n "${MEASUREMENT_PREFLIGHT_DIR_PATH:-}" ]]; then
        printf '%s\n' "${MEASUREMENT_PREFLIGHT_DIR_PATH}"
        return 0
    fi

    measurement_root="$(dirname "${MEASUREMENT_SUMMARY_ENV_FILE_PATH}")"
    printf '%s/acceptance/preflight\n' "${measurement_root}"
}

measurement_query_dir() {
    local measurement_root

    if [[ -n "${MEASUREMENT_QUERY_DIR_PATH:-}" ]]; then
        printf '%s\n' "${MEASUREMENT_QUERY_DIR_PATH}"
        return 0
    fi

    measurement_root="$(dirname "${MEASUREMENT_SUMMARY_ENV_FILE_PATH}")"
    printf '%s/acceptance/query\n' "${measurement_root}"
}

measurement_settle_buffer_ms() {
    printf '%s\n' "${NSM_OVS_MEASUREMENT_SETTLE_BUFFER_MS:-5000}"
}

measurement_query_step_seconds() {
    printf '%s\n' "${NSM_OVS_MEASUREMENT_QUERY_STEP_SECONDS:-15}"
}

measurement_vm_namespace() {
    printf '%s\n' "${VM_NAMESPACE:-${NSM_OVS_MEASUREMENT_VM_NAMESPACE:-victoriametrics-system}}"
}

measurement_vm_service_name() {
    printf '%s\n' "${VM_SERVICE_NAME:-${NSM_OVS_MEASUREMENT_VM_SERVICE_NAME:-victoria-metrics}}"
}

measurement_vm_http_port() {
    printf '%s\n' "${VM_HTTP_PORT:-${NSM_OVS_MEASUREMENT_VM_HTTP_PORT:-8428}}"
}

measurement_vm_local_port() {
    printf '%s\n' "${NSM_OVS_MEASUREMENT_VM_LOCAL_PORT:-18429}"
}

measurement_query_metric_regex() {
    printf '%s\n' "${NSM_OVS_MEASUREMENT_QUERY_METRIC_REGEX:-cpu_usage_active|mem_used_percent|system_load1|net_bits_recv|net_bits_sent|disk_used_percent|processes_running}"
}

measurement_excluded_hostname_regex() {
    printf '%s\n' "${NSM_OVS_MEASUREMENT_EXCLUDED_HOSTNAME_REGEX:-n9e-e2e.*}"
}

measurement_query_expression() {
    local metric_regex hostname_regex

    case "$(measurement_backend)" in
        node01-host-managed)
            measurement_source_host_measurement_libs
            hm_measurement_query_expression
            ;;
        *)
            metric_regex="$(measurement_query_metric_regex)"
            hostname_regex="$(measurement_excluded_hostname_regex)"
            printf '{__name__=~"%s",hostname!~"%s"}\n' "${metric_regex}" "${hostname_regex}"
            ;;
    esac
}

measurement_capture_timestamp() {
    local prefix=$1
    local local_value utc_value epoch_ms_value

    local_value="$(platform_now_local_iso8601)"
    utc_value="$(platform_now_utc_iso8601)"
    epoch_ms_value="$(platform_now_epoch_ms)"

    printf -v "${prefix}_LOCAL" '%s' "${local_value}"
    printf -v "${prefix}_UTC" '%s' "${utc_value}"
    printf -v "${prefix}_EPOCH_MS" '%s' "${epoch_ms_value}"
}

measurement_copy_timestamp() {
    local source_prefix=$1
    local target_prefix=$2
    local local_var utc_var epoch_ms_var

    local_var="${source_prefix}_LOCAL"
    utc_var="${source_prefix}_UTC"
    epoch_ms_var="${source_prefix}_EPOCH_MS"

    printf -v "${target_prefix}_LOCAL" '%s' "${!local_var:-}"
    printf -v "${target_prefix}_UTC" '%s' "${!utc_var:-}"
    printf -v "${target_prefix}_EPOCH_MS" '%s' "${!epoch_ms_var:-}"
}

measurement_ensure_boundary_aliases() {
    if [[ -z "${EXPERIMENT_END_TIME_LOCAL:-}" && -n "${MEASURE_END_LOCAL:-}" ]]; then
        EXPERIMENT_END_TIME_LOCAL="${MEASURE_END_LOCAL}"
    fi
    if [[ -z "${EXPERIMENT_END_TIME_UTC:-}" && -n "${MEASURE_END_UTC:-}" ]]; then
        EXPERIMENT_END_TIME_UTC="${MEASURE_END_UTC}"
    fi
    if [[ -z "${EXPERIMENT_END_TIME_EPOCH_MS:-}" && -n "${MEASURE_END_EPOCH_MS:-}" ]]; then
        EXPERIMENT_END_TIME_EPOCH_MS="${MEASURE_END_EPOCH_MS}"
    fi

    if [[ -z "${MEASURE_END_LOCAL:-}" && -n "${EXPERIMENT_END_TIME_LOCAL:-}" ]]; then
        MEASURE_END_LOCAL="${EXPERIMENT_END_TIME_LOCAL}"
    fi
    if [[ -z "${MEASURE_END_UTC:-}" && -n "${EXPERIMENT_END_TIME_UTC:-}" ]]; then
        MEASURE_END_UTC="${EXPERIMENT_END_TIME_UTC}"
    fi
    if [[ -z "${MEASURE_END_EPOCH_MS:-}" && -n "${EXPERIMENT_END_TIME_EPOCH_MS:-}" ]]; then
        MEASURE_END_EPOCH_MS="${EXPERIMENT_END_TIME_EPOCH_MS}"
    fi

    if [[ -z "${RUN_COMPLETE_END_TIME_LOCAL:-}" && -n "${RUN_END_TIME_LOCAL:-}" ]]; then
        RUN_COMPLETE_END_TIME_LOCAL="${RUN_END_TIME_LOCAL}"
    fi
    if [[ -z "${RUN_COMPLETE_END_TIME_UTC:-}" && -n "${RUN_END_TIME_UTC:-}" ]]; then
        RUN_COMPLETE_END_TIME_UTC="${RUN_END_TIME_UTC}"
    fi
    if [[ -z "${RUN_COMPLETE_END_TIME_EPOCH_MS:-}" && -n "${RUN_END_TIME_EPOCH_MS:-}" ]]; then
        RUN_COMPLETE_END_TIME_EPOCH_MS="${RUN_END_TIME_EPOCH_MS}"
    fi

    if [[ -z "${RUN_END_TIME_LOCAL:-}" && -n "${RUN_COMPLETE_END_TIME_LOCAL:-}" ]]; then
        RUN_END_TIME_LOCAL="${RUN_COMPLETE_END_TIME_LOCAL}"
    fi
    if [[ -z "${RUN_END_TIME_UTC:-}" && -n "${RUN_COMPLETE_END_TIME_UTC:-}" ]]; then
        RUN_END_TIME_UTC="${RUN_COMPLETE_END_TIME_UTC}"
    fi
    if [[ -z "${RUN_END_TIME_EPOCH_MS:-}" && -n "${RUN_COMPLETE_END_TIME_EPOCH_MS:-}" ]]; then
        RUN_END_TIME_EPOCH_MS="${RUN_COMPLETE_END_TIME_EPOCH_MS}"
    fi
}

measurement_wait_for_http_ready() {
    local url=$1
    local attempts=${2:-30}

    for _ in $(seq 1 "${attempts}"); do
        if curl -fsS --max-time 3 "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    return 1
}

measurement_query_range_to_file_cluster() {
    local output_file=$1
    local query_expression=$2
    local query_start_epoch_ms=$3
    local query_end_epoch_ms=$4
    local step_seconds=${5:-$(measurement_query_step_seconds)}
    local vm_namespace vm_service vm_http_port vm_local_port
    local port_forward_pid="" port_forward_log="" start_seconds end_seconds
    local return_code=0

    vm_namespace="$(measurement_vm_namespace)"
    vm_service="$(measurement_vm_service_name)"
    vm_http_port="$(measurement_vm_http_port)"
    vm_local_port="$(measurement_vm_local_port)"
    start_seconds="$(platform_epoch_ms_to_vm_unix_s "${query_start_epoch_ms}")"
    end_seconds="$(platform_epoch_ms_to_vm_unix_s "${query_end_epoch_ms}")"

    mkdir -p "$(dirname "${output_file}")"
    port_forward_log="$(mktemp)"

    cleanup() {
        if [[ -n "${port_forward_pid:-}" ]] && kill -0 "${port_forward_pid}" >/dev/null 2>&1; then
            kill "${port_forward_pid}" >/dev/null 2>&1 || true
            wait "${port_forward_pid}" >/dev/null 2>&1 || true
        fi
        [[ -n "${port_forward_log:-}" && -f "${port_forward_log}" ]] && rm -f "${port_forward_log}"
    }

    log_info "port-forwarding victoria-metrics service/${vm_service} to localhost:${vm_local_port} for measurement export"
    "${KUBECTL:-kubectl}" -n "${vm_namespace}" port-forward service/"${vm_service}" \
        "${vm_local_port}:${vm_http_port}" > "${port_forward_log}" 2>&1 &
    port_forward_pid=$!

    if ! measurement_wait_for_http_ready "http://127.0.0.1:${vm_local_port}/health" 30; then
        log_error "victoria-metrics port-forward did not become ready"
        cat "${port_forward_log}" >&2 || true
        return_code=1
    elif ! curl -fsSG "http://127.0.0.1:${vm_local_port}/api/v1/query_range" \
        --data-urlencode "query=${query_expression}" \
        --data-urlencode "start=${start_seconds}" \
        --data-urlencode "end=${end_seconds}" \
        --data-urlencode "step=${step_seconds}s" > "${output_file}"; then
        log_error "failed to query victoria-metrics query_range for measurement export"
        cat "${port_forward_log}" >&2 || true
        return_code=1
    elif ! jq -e '.status == "success"' "${output_file}" >/dev/null 2>&1; then
        log_error "victoria-metrics query_range did not return success"
        cat "${output_file}" >&2 || true
        return_code=1
    fi

    cleanup
    return "${return_code}"
}

measurement_query_range_to_file_host() {
    local output_file=$1
    local query_expression=$2
    local query_start_epoch_ms=$3
    local query_end_epoch_ms=$4
    local step_seconds=${5:-$(measurement_query_step_seconds)}
    local start_seconds end_seconds tunnel_log="" tunnel_pid=""
    local vm_local_port query_url return_code=0

    measurement_source_host_measurement_libs
    hm_load_config "${NSM_OVS_HOST_MEASUREMENT_ENV_FILE:-}"
    hm_require_local_commands

    start_seconds="$(platform_epoch_ms_to_vm_unix_s "${query_start_epoch_ms}")"
    end_seconds="$(platform_epoch_ms_to_vm_unix_s "${query_end_epoch_ms}")"
    vm_local_port="${HM_VM_TUNNEL_LOCAL_PORT}"
    query_url="http://127.0.0.1:${vm_local_port}/prometheus/api/v1/query_range"

    mkdir -p "$(dirname "${output_file}")"
    tunnel_log="$(mktemp)"

    cleanup() {
        if [[ -n "${tunnel_pid:-}" ]] && kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
            kill "${tunnel_pid}" >/dev/null 2>&1 || true
            wait "${tunnel_pid}" >/dev/null 2>&1 || true
        fi
        [[ -n "${tunnel_log:-}" && -f "${tunnel_log}" ]] && rm -f "${tunnel_log}"
    }

    log_info "opening SSH tunnel to ${HM_SSH_TARGET_REF} for host-managed measurement export on localhost:${vm_local_port}"
    ssh -o ExitOnForwardFailure=yes -L "${vm_local_port}:127.0.0.1:${HM_VM_LISTEN_PORT}" -N "${HM_SSH_TARGET_REF}" \
        > "${tunnel_log}" 2>&1 &
    tunnel_pid=$!

    if ! measurement_wait_for_http_ready "http://127.0.0.1:${vm_local_port}/health" 30; then
        log_error "host-managed victoria-metrics SSH tunnel did not become ready"
        cat "${tunnel_log}" >&2 || true
        return_code=1
    elif ! curl -fsSG "${query_url}" \
        --data-urlencode "query=${query_expression}" \
        --data-urlencode "start=${start_seconds}" \
        --data-urlencode "end=${end_seconds}" \
        --data-urlencode "step=${step_seconds}s" > "${output_file}"; then
        log_error "failed to query host-managed victoria-metrics query_range via SSH tunnel"
        cat "${tunnel_log}" >&2 || true
        return_code=1
    elif ! jq -e '.status == "success"' "${output_file}" >/dev/null 2>&1; then
        log_error "host-managed victoria-metrics query_range did not return success"
        cat "${output_file}" >&2 || true
        return_code=1
    fi

    cleanup
    return "${return_code}"
}

measurement_query_range_to_file() {
    case "$(measurement_backend)" in
        node01-host-managed)
            measurement_query_range_to_file_host "$@"
            ;;
        *)
            measurement_query_range_to_file_cluster "$@"
            ;;
    esac
}

measurement_host_write_group_reports() {
    local output_dir=$1
    local present_groups=$2
    local missing_groups=$3
    local hard_missing_groups=$4
    local partial_missing_groups=$5

    mkdir -p "${output_dir}"

    cat > "${output_dir}/metric-groups.env" <<EOF
MEASUREMENT_BACKEND=${MEASUREMENT_BACKEND:-node01-host-managed}
MEASUREMENT_ACCEPTANCE_CONTRACT=${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}
MEASUREMENT_REQUIRED_METRIC_GROUPS=${MEASUREMENT_REQUIRED_METRIC_GROUPS:-}
MEASUREMENT_PRESENT_METRIC_GROUPS=${present_groups}
MEASUREMENT_MISSING_METRIC_GROUPS=${missing_groups}
MEASUREMENT_HARD_MISSING_METRIC_GROUPS=${hard_missing_groups}
MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS=${partial_missing_groups}
MEASUREMENT_ACCEPTANCE_STATUS=${MEASUREMENT_ACCEPTANCE_STATUS:-unknown}
MEASUREMENT_ACCEPTANCE_REASON=${MEASUREMENT_ACCEPTANCE_REASON:-}
EOF

    cat > "${output_dir}/metric-groups.txt" <<EOF
Backend              : ${MEASUREMENT_BACKEND:-node01-host-managed}
Contract             : ${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}
Required groups      : ${MEASUREMENT_REQUIRED_METRIC_GROUPS:-none}
Present groups       : ${present_groups:-none}
Missing groups       : ${missing_groups:-none}
Hard missing groups  : ${hard_missing_groups:-none}
Partial missing grps : ${partial_missing_groups:-none}
Acceptance status    : ${MEASUREMENT_ACCEPTANCE_STATUS:-unknown}
Acceptance reason    : ${MEASUREMENT_ACCEPTANCE_REASON:-}
EOF
}

measurement_host_evaluate_query_range_file() {
    local query_file=$1
    local query_dir

    measurement_source_host_measurement_libs
    query_dir="$(measurement_query_dir)"
    MEASUREMENT_QUERY_DIR_PATH="${query_dir}"
    mkdir -p "${query_dir}"

    MEASUREMENT_REQUIRED_METRIC_GROUPS="$(hm_measurement_required_metric_groups)"
    MEASUREMENT_ACCEPTED_SCOPE="${MEASUREMENT_REQUIRED_METRIC_GROUPS}"
    MEASUREMENT_EXCLUDED_SCOPE="$(hm_measurement_excluded_metric_groups)"
    MEASUREMENT_PRESENT_METRIC_GROUPS="$(hm_metric_groups_present_from_query_file "${query_file}")"
    MEASUREMENT_MISSING_METRIC_GROUPS="$(hm_metric_groups_missing_from_query_file "${query_file}")"
    MEASUREMENT_HARD_MISSING_METRIC_GROUPS="$(hm_metric_groups_hard_missing_from_query_file "${query_file}")"
    MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS="$(hm_metric_groups_partial_missing_from_query_file "${query_file}")"

    if [[ -n "${MEASUREMENT_HARD_MISSING_METRIC_GROUPS}" ]]; then
        MEASUREMENT_ACCEPTANCE_STATUS='fail'
        MEASUREMENT_ACCEPTANCE_REASON="missing-required-groups:${MEASUREMENT_HARD_MISSING_METRIC_GROUPS}"
        if [[ -n "${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS}" ]]; then
            MEASUREMENT_ACCEPTANCE_REASON="${MEASUREMENT_ACCEPTANCE_REASON};partial-groups-missing:${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS}"
        fi
    elif [[ -n "${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS}" ]]; then
        MEASUREMENT_ACCEPTANCE_STATUS='partial'
        MEASUREMENT_ACCEPTANCE_REASON="partial-groups-missing:${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS}"
    else
        MEASUREMENT_ACCEPTANCE_STATUS='pass'
        MEASUREMENT_ACCEPTANCE_REASON='all-required-groups-present'
    fi

    measurement_host_write_group_reports \
        "${query_dir}" \
        "${MEASUREMENT_PRESENT_METRIC_GROUPS}" \
        "${MEASUREMENT_MISSING_METRIC_GROUPS}" \
        "${MEASUREMENT_HARD_MISSING_METRIC_GROUPS}" \
        "${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS}"
}

measurement_preflight_current_run() {
    local backend preflight_dir summary_env_file verify_return_code=0
    local -A preflight=()

    backend="$(measurement_backend)"
    MEASUREMENT_BACKEND="${backend}"
    MEASUREMENT_ACCEPTANCE_CONTRACT="${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}"
    MEASUREMENT_REQUIRED_METRIC_GROUPS="${MEASUREMENT_REQUIRED_METRIC_GROUPS:-$(measurement_required_metric_groups)}"
    MEASUREMENT_EXCLUDED_SCOPE="${MEASUREMENT_EXCLUDED_SCOPE:-$(measurement_excluded_metric_groups)}"

    if [[ "${backend}" != "node01-host-managed" ]]; then
        MEASUREMENT_PREFLIGHT_STATUS='not-applicable'
        MEASUREMENT_PREFLIGHT_REASON='backend:cluster-vm'
        return 0
    fi

    measurement_source_host_measurement_libs
    preflight_dir="$(measurement_preflight_dir)"
    MEASUREMENT_PREFLIGHT_DIR_PATH="${preflight_dir}"
    summary_env_file="${preflight_dir}/summary.env"
    mkdir -p "${preflight_dir}"

    if "${MEASUREMENT_LIB_DIR}/../host-measurement/verify_node01_measurement_stack.sh" --artifact-dir "${preflight_dir}" >/dev/null; then
        MEASUREMENT_PREFLIGHT_STATUS='pass'
        MEASUREMENT_PREFLIGHT_REASON='host-stack-contract-satisfied'
    else
        verify_return_code=$?
        MEASUREMENT_PREFLIGHT_STATUS='fail'
        MEASUREMENT_PREFLIGHT_REASON='host-stack-contract-check-failed'
    fi

    if [[ -f "${summary_env_file}" ]]; then
        preflight=()
        # shellcheck disable=SC2034
        platform_load_env_file "${summary_env_file}" preflight
        MEASUREMENT_PREFLIGHT_STATUS="${preflight[HOST_MEASUREMENT_STATUS]:-${MEASUREMENT_PREFLIGHT_STATUS}}"
        MEASUREMENT_PREFLIGHT_REASON="${preflight[HOST_MEASUREMENT_REASON]:-${MEASUREMENT_PREFLIGHT_REASON}}"
        MEASUREMENT_ACCEPTANCE_CONTRACT="${preflight[HOST_MEASUREMENT_ACCEPTANCE_CONTRACT]:-${MEASUREMENT_ACCEPTANCE_CONTRACT}}"
        MEASUREMENT_ACCEPTED_SCOPE="${preflight[HOST_MEASUREMENT_ACCEPTED_SCOPE]:-${MEASUREMENT_REQUIRED_METRIC_GROUPS}}"
        MEASUREMENT_EXCLUDED_SCOPE="${preflight[HOST_MEASUREMENT_EXCLUDED_SCOPE]:-${MEASUREMENT_EXCLUDED_SCOPE}}"
        MEASUREMENT_REQUIRED_METRIC_GROUPS="${preflight[HOST_MEASUREMENT_ACCEPTED_SCOPE]:-${MEASUREMENT_REQUIRED_METRIC_GROUPS}}"
        MEASUREMENT_PRESENT_METRIC_GROUPS="${preflight[HOST_MEASUREMENT_PRESENT_GROUPS]:-${MEASUREMENT_PRESENT_METRIC_GROUPS:-}}"
        MEASUREMENT_MISSING_METRIC_GROUPS="${preflight[HOST_MEASUREMENT_MISSING_GROUPS]:-${MEASUREMENT_MISSING_METRIC_GROUPS:-}}"
        MEASUREMENT_HARD_MISSING_METRIC_GROUPS="${preflight[HOST_MEASUREMENT_HARD_MISSING_GROUPS]:-${MEASUREMENT_HARD_MISSING_METRIC_GROUPS:-}}"
        MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS="${preflight[HOST_MEASUREMENT_PARTIAL_MISSING_GROUPS]:-${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS:-}}"
    elif [[ "${verify_return_code}" -eq 0 ]]; then
        MEASUREMENT_PREFLIGHT_STATUS='pass'
        MEASUREMENT_PREFLIGHT_REASON='host-stack-contract-satisfied'
    fi

    [[ "${MEASUREMENT_PREFLIGHT_STATUS}" == "pass" || "${MEASUREMENT_PREFLIGHT_STATUS}" == "partial" ]]
}

measurement_summarize_query_range_file() {
    local raw_file=$1
    local summary_env_file=$2
    local summary_file=$3
    local series_count sample_count metric_names hostnames raw_bytes

    series_count="$(jq '(.data.result | length) // 0' "${raw_file}")"
    sample_count="$(jq '[.data.result[]?.values | length] | add // 0' "${raw_file}")"
    metric_names="$(jq -r '([.data.result[]?.metric.__name__ // empty] | unique) | join(",")' "${raw_file}")"
    hostnames="$(jq -r '([.data.result[]?.metric.hostname // empty] | map(select(length > 0)) | unique) | join(",")' "${raw_file}")"
    raw_bytes="$(wc -c < "${raw_file}" | tr -d '[:space:]')"

    cat > "${summary_env_file}" <<EOF
RUN_ID=${RUN_ID}
RUNNER_NAME=${MEASUREMENT_RUNNER_NAME:-unknown}
RUN_STATUS=${RUN_STATUS:-unknown}
CONTEXT_LABEL=${MEASUREMENT_CONTEXT_LABEL:-}
HUMAN_TIMEZONE=${NSM_OVS_HUMAN_TIMEZONE:-$(platform_time_human_timezone)}
START_TIME_LOCAL=${RUN_START_TIME_LOCAL:-}
START_TIME_EPOCH_MS=${RUN_START_TIME_EPOCH_MS:-}
MEASURE_START_LOCAL=${MEASURE_START_LOCAL:-}
MEASURE_START_EPOCH_MS=${MEASURE_START_EPOCH_MS:-}
EXPERIMENT_END_TIME_LOCAL=${EXPERIMENT_END_TIME_LOCAL:-}
EXPERIMENT_END_TIME_EPOCH_MS=${EXPERIMENT_END_TIME_EPOCH_MS:-}
MEASURE_END_LOCAL=${MEASURE_END_LOCAL:-}
MEASURE_END_EPOCH_MS=${MEASURE_END_EPOCH_MS:-}
RUN_COMPLETE_END_TIME_LOCAL=${RUN_COMPLETE_END_TIME_LOCAL:-}
RUN_COMPLETE_END_TIME_EPOCH_MS=${RUN_COMPLETE_END_TIME_EPOCH_MS:-}
END_TIME_LOCAL=${RUN_COMPLETE_END_TIME_LOCAL:-}
END_TIME_EPOCH_MS=${RUN_COMPLETE_END_TIME_EPOCH_MS:-}
QUERY_START_LOCAL=${QUERY_START_LOCAL:-}
QUERY_START_EPOCH_MS=${QUERY_START_EPOCH_MS:-}
QUERY_END_LOCAL=${QUERY_END_LOCAL:-}
QUERY_END_EPOCH_MS=${QUERY_END_EPOCH_MS:-}
SETTLE_BUFFER_MS=${MEASUREMENT_SETTLE_BUFFER_MS:-}
QUERY_STEP_SECONDS=${MEASUREMENT_QUERY_STEP_SECONDS:-}
QUERY_EXPRESSION=${MEASUREMENT_QUERY_EXPRESSION:-}
RAW_EXPORT_FILE=${raw_file}
RAW_EXPORT_STATUS=${MEASUREMENT_STATUS:-unknown}
RAW_EXPORT_BYTES=${raw_bytes}
SERIES_COUNT=${series_count}
SAMPLE_COUNT=${sample_count}
METRIC_NAMES=${metric_names}
HOSTNAMES=${hostnames}
MEASUREMENT_BACKEND=${MEASUREMENT_BACKEND:-$(measurement_backend)}
MEASUREMENT_ACCEPTANCE_CONTRACT=${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}
MEASUREMENT_ACCEPTED_SCOPE=${MEASUREMENT_ACCEPTED_SCOPE:-${MEASUREMENT_REQUIRED_METRIC_GROUPS:-}}
MEASUREMENT_EXCLUDED_SCOPE=${MEASUREMENT_EXCLUDED_SCOPE:-$(measurement_excluded_metric_groups)}
MEASUREMENT_PREFLIGHT_STATUS=${MEASUREMENT_PREFLIGHT_STATUS:-unknown}
MEASUREMENT_PREFLIGHT_REASON=${MEASUREMENT_PREFLIGHT_REASON:-}
MEASUREMENT_PREFLIGHT_DIR=${MEASUREMENT_PREFLIGHT_DIR_PATH:-$(measurement_preflight_dir)}
MEASUREMENT_REQUIRED_METRIC_GROUPS=${MEASUREMENT_REQUIRED_METRIC_GROUPS:-}
MEASUREMENT_PRESENT_METRIC_GROUPS=${MEASUREMENT_PRESENT_METRIC_GROUPS:-}
MEASUREMENT_MISSING_METRIC_GROUPS=${MEASUREMENT_MISSING_METRIC_GROUPS:-}
MEASUREMENT_HARD_MISSING_METRIC_GROUPS=${MEASUREMENT_HARD_MISSING_METRIC_GROUPS:-}
MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS=${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS:-}
MEASUREMENT_ACCEPTANCE_STATUS=${MEASUREMENT_ACCEPTANCE_STATUS:-unknown}
MEASUREMENT_ACCEPTANCE_REASON=${MEASUREMENT_ACCEPTANCE_REASON:-}
MEASUREMENT_QUERY_DIR=${MEASUREMENT_QUERY_DIR_PATH:-$(measurement_query_dir)}
EOF

    cat > "${summary_file}" <<EOF
Measurement Summary
Run ID             : ${RUN_ID:-}
Runner             : ${MEASUREMENT_RUNNER_NAME:-unknown}
Run status         : ${RUN_STATUS:-unknown}
Context            : ${MEASUREMENT_CONTEXT_LABEL:-}
Timezone           : ${NSM_OVS_HUMAN_TIMEZONE:-$(platform_time_human_timezone)}
Start time         : ${RUN_START_TIME_LOCAL:-} (${RUN_START_TIME_EPOCH_MS:-})
Experiment end     : ${EXPERIMENT_END_TIME_LOCAL:-} (${EXPERIMENT_END_TIME_EPOCH_MS:-})
Run complete end   : ${RUN_COMPLETE_END_TIME_LOCAL:-} (${RUN_COMPLETE_END_TIME_EPOCH_MS:-})
Measure start      : ${MEASURE_START_LOCAL:-} (${MEASURE_START_EPOCH_MS:-})
Measure end        : ${MEASURE_END_LOCAL:-} (${MEASURE_END_EPOCH_MS:-})
Query start        : ${QUERY_START_LOCAL:-} (${QUERY_START_EPOCH_MS:-})
Query end          : ${QUERY_END_LOCAL:-} (${QUERY_END_EPOCH_MS:-})
Settle buffer      : ${MEASUREMENT_SETTLE_BUFFER_MS:-} ms
Query step         : ${MEASUREMENT_QUERY_STEP_SECONDS:-} s
Raw export status  : ${MEASUREMENT_STATUS:-unknown}
Raw export file    : ${raw_file}
Raw export bytes   : ${raw_bytes}
Series count       : ${series_count}
Sample count       : ${sample_count}
Metric names       : ${metric_names:-none}
Hostnames          : ${hostnames:-none}
Query expression   : ${MEASUREMENT_QUERY_EXPRESSION:-}
Backend            : ${MEASUREMENT_BACKEND:-$(measurement_backend)}
Contract           : ${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}
Accepted scope     : ${MEASUREMENT_ACCEPTED_SCOPE:-${MEASUREMENT_REQUIRED_METRIC_GROUPS:-none}}
Excluded scope     : ${MEASUREMENT_EXCLUDED_SCOPE:-$(measurement_excluded_metric_groups)}
Preflight status   : ${MEASUREMENT_PREFLIGHT_STATUS:-unknown}
Preflight reason   : ${MEASUREMENT_PREFLIGHT_REASON:-}
Preflight artifact : ${MEASUREMENT_PREFLIGHT_DIR_PATH:-$(measurement_preflight_dir)}
Present groups     : ${MEASUREMENT_PRESENT_METRIC_GROUPS:-none}
Missing groups     : ${MEASUREMENT_MISSING_METRIC_GROUPS:-none}
Hard missing grps  : ${MEASUREMENT_HARD_MISSING_METRIC_GROUPS:-none}
Partial missing gp : ${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS:-none}
Acceptance status  : ${MEASUREMENT_ACCEPTANCE_STATUS:-unknown}
Acceptance reason  : ${MEASUREMENT_ACCEPTANCE_REASON:-}
Query artifact dir : ${MEASUREMENT_QUERY_DIR_PATH:-$(measurement_query_dir)}
EOF
}

measurement_finalize_current_run() {
    local backend query_expression settle_buffer_ms step_seconds return_code=0

    backend="$(measurement_backend)"
    MEASUREMENT_BACKEND="${backend}"
    MEASUREMENT_ACCEPTANCE_CONTRACT="${MEASUREMENT_ACCEPTANCE_CONTRACT:-$(measurement_acceptance_contract)}"
    MEASUREMENT_REQUIRED_METRIC_GROUPS="${MEASUREMENT_REQUIRED_METRIC_GROUPS:-$(measurement_required_metric_groups)}"
    MEASUREMENT_EXCLUDED_SCOPE="${MEASUREMENT_EXCLUDED_SCOPE:-$(measurement_excluded_metric_groups)}"

    [[ -n "${MEASUREMENT_METADATA_FILE_PATH:-}" ]] || {
        log_error "measurement metadata file path is not set"
        return 1
    }
    [[ -n "${MEASUREMENT_RAW_EXPORT_FILE_PATH:-}" ]] || {
        log_error "measurement raw export file path is not set"
        return 1
    }
    [[ -n "${MEASUREMENT_SUMMARY_ENV_FILE_PATH:-}" ]] || {
        log_error "measurement summary env file path is not set"
        return 1
    }
    [[ -n "${MEASUREMENT_SUMMARY_FILE_PATH:-}" ]] || {
        log_error "measurement summary file path is not set"
        return 1
    }
    [[ -n "${RUN_ID:-}" ]] || {
        log_error "RUN_ID is not set for measurement finalization"
        return 1
    }
    measurement_ensure_boundary_aliases

    [[ -n "${RUN_START_TIME_EPOCH_MS:-}" && -n "${MEASURE_START_EPOCH_MS:-}" && -n "${EXPERIMENT_END_TIME_EPOCH_MS:-}" && -n "${MEASURE_END_EPOCH_MS:-}" ]] || {
        log_error "measurement finalization is missing time boundaries"
        return 1
    }
    require_command curl
    require_command jq

    settle_buffer_ms="$(measurement_settle_buffer_ms)"
    step_seconds="$(measurement_query_step_seconds)"
    query_expression="$(measurement_query_expression)"

    QUERY_START_EPOCH_MS="${MEASURE_START_EPOCH_MS}"
    QUERY_END_EPOCH_MS="$((MEASURE_END_EPOCH_MS + settle_buffer_ms))"
    QUERY_START_LOCAL="$(platform_epoch_ms_to_local_iso8601 "${QUERY_START_EPOCH_MS}")"
    QUERY_END_LOCAL="$(platform_epoch_ms_to_local_iso8601 "${QUERY_END_EPOCH_MS}")"
    MEASUREMENT_SETTLE_BUFFER_MS="${settle_buffer_ms}"
    MEASUREMENT_QUERY_EXPRESSION="${query_expression}"
    MEASUREMENT_QUERY_STEP_SECONDS="${step_seconds}"
    MEASUREMENT_STATUS='exporting'

    if [[ "${backend}" == "node01-host-managed" && "${MEASUREMENT_PREFLIGHT_STATUS:-unknown}" == "fail" ]]; then
        log_error "skipping host-managed measurement export because preflight status=${MEASUREMENT_PREFLIGHT_STATUS:-unknown}"
        MEASUREMENT_STATUS='failed'
        MEASUREMENT_ACCEPTANCE_STATUS='fail'
        MEASUREMENT_ACCEPTANCE_REASON="preflight:${MEASUREMENT_PREFLIGHT_REASON:-unknown}"
        mkdir -p "$(dirname "${MEASUREMENT_RAW_EXPORT_FILE_PATH}")"
        cat > "${MEASUREMENT_RAW_EXPORT_FILE_PATH}" <<'EOF'
{"status":"error","data":{"result":[]}}
EOF
        return_code=1
    elif measurement_query_range_to_file "${MEASUREMENT_RAW_EXPORT_FILE_PATH}" "${query_expression}" "${QUERY_START_EPOCH_MS}" "${QUERY_END_EPOCH_MS}" "${step_seconds}"; then
        if [[ "$(jq '(.data.result | length) // 0' "${MEASUREMENT_RAW_EXPORT_FILE_PATH}")" == "0" ]]; then
            log_error "measurement export completed but returned zero series"
            MEASUREMENT_STATUS='failed'
            if [[ "${backend}" == "node01-host-managed" ]]; then
                MEASUREMENT_ACCEPTANCE_STATUS='fail'
                MEASUREMENT_ACCEPTANCE_REASON='query-range-returned-zero-series'
            fi
            return_code=1
        else
            if [[ "${backend}" == "node01-host-managed" ]]; then
                measurement_host_evaluate_query_range_file "${MEASUREMENT_RAW_EXPORT_FILE_PATH}"
                if [[ "${MEASUREMENT_ACCEPTANCE_STATUS:-fail}" == "fail" ]]; then
                    MEASUREMENT_STATUS='failed'
                    return_code=1
                else
                    MEASUREMENT_STATUS='exported'
                fi
            else
                MEASUREMENT_STATUS='exported'
            fi
        fi
    else
        MEASUREMENT_STATUS='failed'
        if [[ "${backend}" == "node01-host-managed" ]]; then
            MEASUREMENT_ACCEPTANCE_STATUS='fail'
            MEASUREMENT_ACCEPTANCE_REASON='host-managed-query-range-failed'
        fi
        mkdir -p "$(dirname "${MEASUREMENT_RAW_EXPORT_FILE_PATH}")"
        cat > "${MEASUREMENT_RAW_EXPORT_FILE_PATH}" <<'EOF'
{"status":"error","data":{"result":[]}}
EOF
        return_code=1
    fi

    if [[ -z "${RUN_COMPLETE_END_TIME_EPOCH_MS:-}" ]]; then
        measurement_capture_timestamp RUN_COMPLETE_END_TIME
        measurement_copy_timestamp RUN_COMPLETE_END_TIME RUN_END_TIME
        log_info "recorded run completion boundary after cleanup and measurement export: run_complete_end=${RUN_COMPLETE_END_TIME_LOCAL}"
    fi

    measurement_ensure_boundary_aliases

    cat > "${MEASUREMENT_METADATA_FILE_PATH}" <<EOF
RUN_ID=${RUN_ID}
RUNNER_NAME=${MEASUREMENT_RUNNER_NAME:-unknown}
RUN_STATUS=${RUN_STATUS:-unknown}
CONTEXT_LABEL=${MEASUREMENT_CONTEXT_LABEL:-}
HUMAN_TIMEZONE=${NSM_OVS_HUMAN_TIMEZONE:-$(platform_time_human_timezone)}
START_TIME_LOCAL=${RUN_START_TIME_LOCAL:-}
START_TIME_EPOCH_MS=${RUN_START_TIME_EPOCH_MS:-}
MEASURE_START_LOCAL=${MEASURE_START_LOCAL:-}
MEASURE_START_EPOCH_MS=${MEASURE_START_EPOCH_MS:-}
EXPERIMENT_END_TIME_LOCAL=${EXPERIMENT_END_TIME_LOCAL:-}
EXPERIMENT_END_TIME_EPOCH_MS=${EXPERIMENT_END_TIME_EPOCH_MS:-}
MEASURE_END_LOCAL=${MEASURE_END_LOCAL:-}
MEASURE_END_EPOCH_MS=${MEASURE_END_EPOCH_MS:-}
RUN_COMPLETE_END_TIME_LOCAL=${RUN_COMPLETE_END_TIME_LOCAL:-}
RUN_COMPLETE_END_TIME_EPOCH_MS=${RUN_COMPLETE_END_TIME_EPOCH_MS:-}
END_TIME_LOCAL=${RUN_COMPLETE_END_TIME_LOCAL:-}
END_TIME_EPOCH_MS=${RUN_COMPLETE_END_TIME_EPOCH_MS:-}
QUERY_START_LOCAL=${QUERY_START_LOCAL:-}
QUERY_START_EPOCH_MS=${QUERY_START_EPOCH_MS:-}
QUERY_END_LOCAL=${QUERY_END_LOCAL:-}
QUERY_END_EPOCH_MS=${QUERY_END_EPOCH_MS:-}
SETTLE_BUFFER_MS=${settle_buffer_ms}
QUERY_STEP_SECONDS=${step_seconds}
QUERY_EXPRESSION=${query_expression}
MEASUREMENT_BACKEND=${MEASUREMENT_BACKEND:-${backend}}
MEASUREMENT_ACCEPTANCE_CONTRACT=${MEASUREMENT_ACCEPTANCE_CONTRACT:-}
MEASUREMENT_ACCEPTED_SCOPE=${MEASUREMENT_ACCEPTED_SCOPE:-${MEASUREMENT_REQUIRED_METRIC_GROUPS:-}}
MEASUREMENT_EXCLUDED_SCOPE=${MEASUREMENT_EXCLUDED_SCOPE:-}
MEASUREMENT_PREFLIGHT_STATUS=${MEASUREMENT_PREFLIGHT_STATUS:-unknown}
MEASUREMENT_PREFLIGHT_REASON=${MEASUREMENT_PREFLIGHT_REASON:-}
MEASUREMENT_PREFLIGHT_DIR=${MEASUREMENT_PREFLIGHT_DIR_PATH:-$(measurement_preflight_dir)}
MEASUREMENT_REQUIRED_METRIC_GROUPS=${MEASUREMENT_REQUIRED_METRIC_GROUPS:-}
MEASUREMENT_PRESENT_METRIC_GROUPS=${MEASUREMENT_PRESENT_METRIC_GROUPS:-}
MEASUREMENT_MISSING_METRIC_GROUPS=${MEASUREMENT_MISSING_METRIC_GROUPS:-}
MEASUREMENT_HARD_MISSING_METRIC_GROUPS=${MEASUREMENT_HARD_MISSING_METRIC_GROUPS:-}
MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS=${MEASUREMENT_PARTIAL_MISSING_METRIC_GROUPS:-}
MEASUREMENT_ACCEPTANCE_STATUS=${MEASUREMENT_ACCEPTANCE_STATUS:-unknown}
MEASUREMENT_ACCEPTANCE_REASON=${MEASUREMENT_ACCEPTANCE_REASON:-}
MEASUREMENT_QUERY_DIR=${MEASUREMENT_QUERY_DIR_PATH:-$(measurement_query_dir)}
RAW_EXPORT_FILE=${MEASUREMENT_RAW_EXPORT_FILE_PATH}
SUMMARY_ENV_FILE=${MEASUREMENT_SUMMARY_ENV_FILE_PATH}
SUMMARY_FILE=${MEASUREMENT_SUMMARY_FILE_PATH}
MEASUREMENT_STATUS=${MEASUREMENT_STATUS}
EOF

    measurement_summarize_query_range_file \
        "${MEASUREMENT_RAW_EXPORT_FILE_PATH}" \
        "${MEASUREMENT_SUMMARY_ENV_FILE_PATH}" \
        "${MEASUREMENT_SUMMARY_FILE_PATH}"

    return "${return_code}"
}
