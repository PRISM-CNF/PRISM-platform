#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: verify_node01_measurement_stack.sh [--env-file <path>] [--ssh-target <host>] [--ssh-user <user>] [--artifact-dir <dir>] [--print-summary]

Verify the node01 host-managed measurement stack against the current Step 5 acceptance contract and write validation artifacts.
EOF
}

service_state_from_file() {
    local file=$1
    tr -d '\r' < "${file}" | tail -n 1
}

json_series_has_entries() {
    local file=$1
    jq -e '.status == "success" and (.data | type) == "array" and (.data | length) > 0' "${file}" >/dev/null 2>&1
}

json_query_has_positive_samples() {
    local file=$1
    jq -e '.status == "success" and (.data.result | type) == "array" and any(.data.result[]?; ((.value[1] // "0") | tonumber) > 0)' "${file}" >/dev/null 2>&1
}

group_env_key() {
    printf '%s\n' "$1" | tr '[:lower:]-' '[:upper:]_'
}

first_csv_item() {
    local csv=$1
    local first=""
    IFS=, read -r first _ <<<"${csv}"
    printf '%s\n' "${first}"
}

remote_vm_label_values() {
    local output_file=$1
    ssh -n "${HM_SSH_TARGET_REF}" "curl -fsS http://${HM_VMSINGLE_LISTEN_ADDR}/prometheus/api/v1/label/__name__/values" > "${output_file}"
}

remote_vm_series() {
    local selector=$1
    local output_file=$2
    ssh -n "${HM_SSH_TARGET_REF}" "curl -fsSG --data-urlencode 'match[]=${selector}' http://${HM_VMSINGLE_LISTEN_ADDR}/prometheus/api/v1/series" > "${output_file}" 2>/dev/null
}

remote_vm_query() {
    local expr=$1
    local output_file=$2
    ssh -n "${HM_SSH_TARGET_REF}" "curl -fsSG --data-urlencode 'query=${expr}' http://${HM_VMSINGLE_LISTEN_ADDR}/prometheus/api/v1/query" > "${output_file}"
}

remote_vm_query_with_retries() {
    local expr=$1
    local output_file=$2
    local attempts=${3:-7}
    local delay_sec=${4:-5}
    local attempt

    for attempt in $(seq 1 "${attempts}"); do
        remote_vm_query "${expr}" "${output_file}" || true
        if json_query_has_positive_samples "${output_file}"; then
            return 0
        fi
        if [[ "${attempt}" -lt "${attempts}" ]]; then
            sleep "${delay_sec}"
        fi
    done
    return 1
}

remote_plain_http_head() {
    local url=$1
    local output_file=$2
    ssh -n "${HM_SSH_TARGET_REF}" "curl -fsS '${url}' | sed -n '1,40p'" > "${output_file}" 2>&1 || true
}

remote_plain_http_status() {
    local url=$1
    local output_file=$2
    ssh -n "${HM_SSH_TARGET_REF}" "curl -fsS -o /dev/null -w '%{http_code}\n' '${url}'" > "${output_file}" 2>&1 || true
}

remote_bearer_http_head() {
    local url=$1
    local output_file=$2
    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${url}' '${HM_CATEGRAF_BEARER_TOKEN_FILE}'" > "${output_file}" 2>&1 <<'EOF'
set -euo pipefail
url=$1
token_file=$2
token="$(cat "${token_file}")"
curl -kfsS -H "Authorization: Bearer ${token}" "${url}" | sed -n '1,40p'
EOF
}

remote_bearer_http_status() {
    local url=$1
    local output_file=$2
    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${url}' '${HM_CATEGRAF_BEARER_TOKEN_FILE}'" > "${output_file}" 2>&1 <<'EOF'
set -euo pipefail
url=$1
token_file=$2
token="$(cat "${token_file}")"
curl -kfsS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${token}" "${url}" || true
EOF
}

write_endpoint_status_list() {
    local output_file=$1
    local url_csv=$2
    local auth_mode=$3
    local url

    : > "${output_file}"
    if [[ -z "${url_csv}" ]]; then
        printf 'unavailable\n' > "${output_file}"
        return 0
    fi

    IFS=, read -ra urls <<<"${url_csv}"
    for url in "${urls[@]}"; do
        [[ -n "${url}" ]] || continue
        if [[ "${auth_mode}" == "bearer" ]]; then
            {
                printf '%s -> ' "${url}"
                ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${url}' '${HM_CATEGRAF_BEARER_TOKEN_FILE}'" 2>&1 <<'EOF'
set -euo pipefail
url=$1
token_file=$2
token="$(cat "${token_file}")"
curl -kfsS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${token}" "${url}" || true
EOF
            } >> "${output_file}" || true
        else
            {
                printf '%s -> ' "${url}"
                ssh -n "${HM_SSH_TARGET_REF}" "curl -fsS -o /dev/null -w '%{http_code}\n' '${url}'" 2>&1 || true
            } >> "${output_file}"
        fi
    done
}

group_series_selector() {
    local group=$1

    case "${group}" in
        pcm)
            printf 'Measurement_Interval_in_us{job="pcm-sensor-server"}\n'
            ;;
        cpu)
            printf 'cpu_usage_idle\n'
            ;;
        disk)
            printf 'disk_used_percent\n'
            ;;
        diskio)
            printf 'diskio_read_bytes\n'
            ;;
        kube-proxy)
            printf '{job="kube-proxy"}\n'
            ;;
        kubelet)
            printf '{job="kubelet"}\n'
            ;;
        cadvisor)
            printf '{job="cadvisor"}\n'
            ;;
        kube-state-metrics)
            printf '{job="kube-state-metrics"}\n'
            ;;
        kube-state-metrics-self)
            printf '{job="kube-state-metrics-self"}\n'
            ;;
        system)
            printf 'system_load1\n'
            ;;
        mem)
            printf 'mem_used_percent\n'
            ;;
        net)
            printf 'net_bits_recv\n'
            ;;
        netstat)
            printf 'netstat_tcp_established\n'
            ;;
        processes)
            printf 'processes_total\n'
            ;;
        kernel)
            printf 'kernel_context_switches\n'
            ;;
        kernel-vmstat)
            printf 'kernel_vmstat_oom_kill\n'
            ;;
        linux-sysctl-fs)
            printf 'linux_sysctl_fs_file_nr\n'
            ;;
        *)
            return 1
            ;;
    esac
}

group_query_expr() {
    local group=$1

    case "${group}" in
        pcm)
            printf 'count(Measurement_Interval_in_us{job="pcm-sensor-server"})\n'
            ;;
        cpu)
            printf 'count({__name__=~"cpu_.*"})\n'
            ;;
        disk)
            printf 'count({__name__=~"disk_.*"})\n'
            ;;
        diskio)
            printf 'count({__name__=~"diskio_.*"})\n'
            ;;
        kube-proxy)
            printf 'count({job="kube-proxy"})\n'
            ;;
        kubelet)
            printf 'count({job="kubelet"})\n'
            ;;
        cadvisor)
            printf 'count({job="cadvisor"})\n'
            ;;
        kube-state-metrics)
            printf 'count({job="kube-state-metrics"})\n'
            ;;
        kube-state-metrics-self)
            printf 'count({job="kube-state-metrics-self"})\n'
            ;;
        system)
            printf 'count(system_load1)\n'
            ;;
        mem)
            printf 'count(mem_used_percent)\n'
            ;;
        net)
            printf 'count(net_bits_recv)\n'
            ;;
        netstat)
            printf 'count(netstat_tcp_established)\n'
            ;;
        processes)
            printf 'count(processes_total)\n'
            ;;
        kernel)
            printf 'count(kernel_context_switches)\n'
            ;;
        kernel-vmstat)
            printf 'count(kernel_vmstat_oom_kill)\n'
            ;;
        linux-sysctl-fs)
            printf 'count(linux_sysctl_fs_file_nr)\n'
            ;;
        *)
            return 1
            ;;
    esac
}

group_discovery_blocker() {
    local group=$1

    case "${group}" in
        kubelet)
            printf '%s\n' "${HM_KUBELET_DISCOVERY_BLOCKER}"
            ;;
        cadvisor)
            printf '%s\n' "${HM_CADVISOR_DISCOVERY_BLOCKER}"
            ;;
        kube-state-metrics)
            printf '%s\n' "${HM_KSM_DISCOVERY_BLOCKER}"
            ;;
        kube-state-metrics-self)
            printf '%s\n' "${HM_KSM_SELF_DISCOVERY_BLOCKER}"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

append_csv_value() {
    local current=$1
    local value=$2

    if [[ -n "${current}" ]]; then
        printf '%s,%s\n' "${current}" "${value}"
    else
        printf '%s\n' "${value}"
    fi
}

main() {
    local env_file="" artifact_dir="" print_summary=false
    local command_file resolved_env_file summary_env_file summary_txt_file
    local service_dir endpoint_dir query_dir config_dir logs_dir
    local metrics_names_file metric_queries_file
    local overall_status="pass" overall_reason="all-required-checks-passed"
    local contract_name backend_name required_groups excluded_groups partial_groups
    local pcm_watchdog_status="disabled" pcm_watchdog_reason="pcm-watchdog-disabled"
    local optional_l1_status="disabled" optional_l1_reason="pcm-core-l1-disabled"
    local optional_l1_hit_status="disabled" optional_l1_hit_reason="pcm-core-l1-hit-disabled"
    local present_groups="" missing_groups="" hard_missing_groups="" partial_missing_groups=""
    local cpu_distinct_label_count="0" cpu_per_core_present="false" cpu_total_present="false"
    local node01_non_pcm_coverage_status="missing"
    local first_ksm_url="" first_ksm_self_url="" group selector query_expr
    local service state_file status_file group_series_file group_query_file group_reason group_key
    local -a original_args=("$@")
    declare -A group_status_map=()
    declare -A group_reason_map=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                [[ $# -ge 2 ]] || die "missing value for --env-file"
                env_file=$2
                shift 2
                ;;
            --ssh-target)
                [[ $# -ge 2 ]] || die "missing value for --ssh-target"
                export NSM_OVS_HOST_MEASUREMENT_SSH_TARGET=$2
                shift 2
                ;;
            --ssh-user)
                [[ $# -ge 2 ]] || die "missing value for --ssh-user"
                export NSM_OVS_HOST_MEASUREMENT_SSH_USER=$2
                shift 2
                ;;
            --artifact-dir)
                [[ $# -ge 2 ]] || die "missing value for --artifact-dir"
                artifact_dir=$2
                shift 2
                ;;
            --print-summary)
                print_summary=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    hm_load_config "${env_file}"
    hm_require_local_commands
    contract_name="$(hm_measurement_contract_name)"
    backend_name="$(hm_measurement_backend)"
    required_groups="$(hm_measurement_required_metric_groups)"
    excluded_groups="$(hm_measurement_excluded_metric_groups)"
    partial_groups="$(hm_measurement_partial_metric_groups)"

    [[ -n "${artifact_dir}" ]] || artifact_dir="$(hm_make_artifact_dir node01-host-measurement-v2)"
    mkdir -p "${artifact_dir}"
    command_file="${artifact_dir}/command.txt"
    resolved_env_file="${artifact_dir}/resolved.env"
    summary_env_file="${artifact_dir}/summary.env"
    summary_txt_file="${artifact_dir}/summary.txt"
    service_dir="${artifact_dir}/services"
    endpoint_dir="${artifact_dir}/endpoints"
    query_dir="${artifact_dir}/queries"
    config_dir="${artifact_dir}/config"
    logs_dir="${artifact_dir}/logs"
    metrics_names_file="${query_dir}/metric-names.json"
    metric_queries_file="${query_dir}/metric-checks.txt"
    mkdir -p "${service_dir}" "${endpoint_dir}" "${query_dir}" "${config_dir}" "${logs_dir}"

    hm_write_command_file "${command_file}" "$0" "${original_args[@]}"
    hm_write_resolved_env "${resolved_env_file}"

    for service in "${HM_VMSINGLE_SERVICE_NAME}" "${HM_N9E_SERVICE_NAME}" "${HM_CATEGRAF_SERVICE_NAME}" "pcm-sensor-server"; do
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl is-active ${service}.service || true" > "${service_dir}/${service}.is-active.txt"
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl status ${service}.service --no-pager || true" > "${service_dir}/${service}.status.txt"
    done
    if [[ "${HM_ENABLE_PCM}" == "1" && "${HM_ENABLE_PCM_WATCHDOG}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl is-active ${HM_PCM_WATCHDOG_SERVICE_NAME}.service || true" > "${service_dir}/${HM_PCM_WATCHDOG_SERVICE_NAME}.is-active.txt"
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl status ${HM_PCM_WATCHDOG_SERVICE_NAME}.service --no-pager || true" > "${service_dir}/${HM_PCM_WATCHDOG_SERVICE_NAME}.status.txt"
    fi
    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl is-active ${HM_PCM_L1_SERVICE_NAME}.service || true" > "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.is-active.txt"
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl status ${HM_PCM_L1_SERVICE_NAME}.service --no-pager || true" > "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.status.txt"
    fi

    if [[ "${HM_ENABLE_PCM}" == "1" && "${HM_ENABLE_PCM_WATCHDOG}" == "1" && "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl cat ${HM_VMSINGLE_SERVICE_NAME}.service ${HM_N9E_SERVICE_NAME}.service ${HM_CATEGRAF_SERVICE_NAME}.service ${HM_PCM_WATCHDOG_SERVICE_NAME}.service ${HM_PCM_L1_SERVICE_NAME}.service" > "${config_dir}/systemd-units.txt"
    elif [[ "${HM_ENABLE_PCM}" == "1" && "${HM_ENABLE_PCM_WATCHDOG}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl cat ${HM_VMSINGLE_SERVICE_NAME}.service ${HM_N9E_SERVICE_NAME}.service ${HM_CATEGRAF_SERVICE_NAME}.service ${HM_PCM_WATCHDOG_SERVICE_NAME}.service" > "${config_dir}/systemd-units.txt"
    elif [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl cat ${HM_VMSINGLE_SERVICE_NAME}.service ${HM_N9E_SERVICE_NAME}.service ${HM_CATEGRAF_SERVICE_NAME}.service ${HM_PCM_L1_SERVICE_NAME}.service" > "${config_dir}/systemd-units.txt"
    else
        ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl cat ${HM_VMSINGLE_SERVICE_NAME}.service ${HM_N9E_SERVICE_NAME}.service ${HM_CATEGRAF_SERVICE_NAME}.service" > "${config_dir}/systemd-units.txt"
    fi
    ssh "${HM_SSH_TARGET_REF}" "sudo -n cat ${HM_CONFIG_ROOT}/categraf/conf/config.toml" > "${config_dir}/categraf-config.toml"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n find ${HM_CONFIG_ROOT}/categraf/conf -maxdepth 2 -type f | sort | while read -r f; do echo '###'\"\$f\"; sudo -n cat \"\$f\"; echo; done" > "${config_dir}/categraf-inputs.txt"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n find ${HM_CATEGRAF_CREDENTIALS_DIR} -maxdepth 1 -type f -printf '%m %u %g %p\n' 2>/dev/null | sort || true" > "${config_dir}/categraf-credentials.txt"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n cat ${HM_CONFIG_ROOT}/n9e/config.toml" > "${config_dir}/n9e-config.toml"
    if [[ "${HM_ENABLE_PCM}" == "1" && "${HM_ENABLE_PCM_WATCHDOG}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n cat ${HM_PCM_WATCHDOG_ENV_FILE}" > "${config_dir}/pcm-sensor-watchdog.env"
    fi
    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "sudo -n cat ${HM_PCM_L1_ENV_FILE}" > "${config_dir}/pcm-core-l1.env"
    fi

    remote_plain_http_head "${HM_PCM_METRICS_URL}" "${endpoint_dir}/pcm.metrics.head.txt"
    remote_plain_http_head "${HM_KUBE_PROXY_METRICS_URL}" "${endpoint_dir}/kube-proxy.metrics.head.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -i -s http://${HM_CATEGRAF_HTTP_ADDR}/ | sed -n '1,20p'" > "${endpoint_dir}/categraf.http-root.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -fsS http://${HM_N9E_LOCAL_ADDR}/metrics | sed -n '1,80p'" > "${endpoint_dir}/n9e.metrics.head.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -fsS http://${HM_VMSINGLE_LISTEN_ADDR}/health" > "${endpoint_dir}/vmsingle.health.txt"
    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        ssh "${HM_SSH_TARGET_REF}" "curl -fsS ${HM_PCM_L1_METRICS_URL} | grep -E '^(pcm_core_l1_exporter_|${HM_PCM_L1_METRIC_NAME}|${HM_PCM_L1_HIT_METRIC_NAME})' | sed -n '1,200p' || true" > "${endpoint_dir}/pcm-core-l1.metrics.head.txt"
        ssh "${HM_SSH_TARGET_REF}" "curl -fsS ${HM_PCM_L1_HEALTH_URL} || true" > "${endpoint_dir}/pcm-core-l1.health.txt"
    fi

    if [[ -n "${HM_KUBELET_PROXY_METRICS_URL}" ]]; then
        remote_bearer_http_head "${HM_KUBELET_PROXY_METRICS_URL}" "${endpoint_dir}/kubelet.metrics.head.txt" || true
        remote_bearer_http_status "${HM_KUBELET_PROXY_METRICS_URL}" "${endpoint_dir}/kubelet.http-status.txt" || true
    else
        printf 'kubelet omitted: %s\n' "${HM_KUBELET_DISCOVERY_BLOCKER}" > "${endpoint_dir}/kubelet.metrics.head.txt"
        printf 'kubelet omitted: %s\n' "${HM_KUBELET_DISCOVERY_BLOCKER}" > "${endpoint_dir}/kubelet.http-status.txt"
    fi

    if [[ -n "${HM_CADVISOR_PROXY_METRICS_URL}" ]]; then
        remote_bearer_http_head "${HM_CADVISOR_PROXY_METRICS_URL}" "${endpoint_dir}/cadvisor.metrics.head.txt" || true
        remote_bearer_http_status "${HM_CADVISOR_PROXY_METRICS_URL}" "${endpoint_dir}/cadvisor.http-status.txt" || true
    else
        printf 'cadvisor omitted: %s\n' "${HM_CADVISOR_DISCOVERY_BLOCKER}" > "${endpoint_dir}/cadvisor.metrics.head.txt"
        printf 'cadvisor omitted: %s\n' "${HM_CADVISOR_DISCOVERY_BLOCKER}" > "${endpoint_dir}/cadvisor.http-status.txt"
    fi

    write_endpoint_status_list "${endpoint_dir}/kube-state-metrics.endpoints.txt" "${HM_KSM_METRICS_URLS_CSV}" "plain"
    write_endpoint_status_list "${endpoint_dir}/kube-state-metrics-self.endpoints.txt" "${HM_KSM_SELF_METRICS_URLS_CSV}" "plain"
    first_ksm_url="$(first_csv_item "${HM_KSM_METRICS_URLS_CSV}")"
    first_ksm_self_url="$(first_csv_item "${HM_KSM_SELF_METRICS_URLS_CSV}")"
    if [[ -n "${first_ksm_url}" ]]; then
        remote_plain_http_head "${first_ksm_url}" "${endpoint_dir}/kube-state-metrics.metrics.head.txt"
    else
        printf 'kube-state-metrics omitted: %s\n' "${HM_KSM_DISCOVERY_BLOCKER}" > "${endpoint_dir}/kube-state-metrics.metrics.head.txt"
    fi
    if [[ -n "${first_ksm_self_url}" ]]; then
        remote_plain_http_head "${first_ksm_self_url}" "${endpoint_dir}/kube-state-metrics-self.metrics.head.txt"
    else
        printf 'kube-state-metrics-self omitted: %s\n' "${HM_KSM_SELF_DISCOVERY_BLOCKER}" > "${endpoint_dir}/kube-state-metrics-self.metrics.head.txt"
    fi
    ssh "${HM_SSH_TARGET_REF}" "sudo -n ss -ltnp | grep -E ':9738|:9748|:10249|:17000|:18428|:19100|:8428' || true" > "${endpoint_dir}/ports.txt"

    remote_vm_label_values "${metrics_names_file}"

    {
        printf 'vm_service_active=%s\n' "$(service_state_from_file "${service_dir}/${HM_VMSINGLE_SERVICE_NAME}.is-active.txt")"
        printf 'n9e_service_active=%s\n' "$(service_state_from_file "${service_dir}/${HM_N9E_SERVICE_NAME}.is-active.txt")"
        printf 'categraf_service_active=%s\n' "$(service_state_from_file "${service_dir}/${HM_CATEGRAF_SERVICE_NAME}.is-active.txt")"
        printf 'pcm_service_active=%s\n' "$(service_state_from_file "${service_dir}/pcm-sensor-server.is-active.txt")"
        printf '\n[group-checks]\n'
    } > "${metric_queries_file}"

    for service in "${HM_VMSINGLE_SERVICE_NAME}" "${HM_N9E_SERVICE_NAME}" "${HM_CATEGRAF_SERVICE_NAME}" "pcm-sensor-server"; do
        state_file="${service_dir}/${service}.is-active.txt"
        if [[ "$(service_state_from_file "${state_file}")" != "active" ]]; then
            overall_status="fail"
            overall_reason="${service}-service-inactive"
        fi
    done

    jq -e '.status == "success"' "${metrics_names_file}" >/dev/null || {
        overall_status="fail"
        overall_reason="vm-metric-name-query-failed"
    }

    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        selector="$(group_series_selector "${group}")"
        query_expr="$(group_query_expr "${group}")"
        group_series_file="${query_dir}/${group}-series.json"
        group_query_file="${query_dir}/${group}-query.json"

        remote_vm_query_with_retries "${query_expr}" "${group_query_file}" 7 5 || true
        remote_vm_series "${selector}" "${group_series_file}" || true

        if json_query_has_positive_samples "${group_query_file}"; then
            group_status_map["${group}"]="pass"
            if json_series_has_entries "${group_series_file}"; then
                group_reason_map["${group}"]="live-series-present"
            else
                group_reason_map["${group}"]="live-query-present-series-evidence-empty"
            fi
            present_groups="$(append_csv_value "${present_groups}" "${group}")"
        else
            group_reason="$(group_discovery_blocker "${group}")"
            if [[ -z "${group_reason}" ]]; then
                if ! jq -e '.status == "success"' "${group_query_file}" >/dev/null 2>&1; then
                    group_reason="${group}-query-failed"
                elif ! json_query_has_positive_samples "${group_query_file}"; then
                    group_reason="${group}-query-empty"
                elif ! json_series_has_entries "${group_series_file}"; then
                    group_reason="${group}-series-empty"
                else
                    group_reason="${group}-unknown-miss"
                fi
            fi
            group_status_map["${group}"]="missing"
            group_reason_map["${group}"]="${group_reason}"
            missing_groups="$(append_csv_value "${missing_groups}" "${group}")"
            if hm_metric_group_is_partial_allowed "${group}"; then
                partial_missing_groups="$(append_csv_value "${partial_missing_groups}" "${group}")"
            else
                hard_missing_groups="$(append_csv_value "${hard_missing_groups}" "${group}")"
            fi
        fi

        {
            printf '%s:\n' "${group}"
            printf '  selector=%s\n' "${selector}"
            printf '  query=%s\n' "${query_expr}"
            printf '  status=%s\n' "${group_status_map[${group}]}"
            printf '  reason=%s\n' "${group_reason_map[${group}]}"
            printf '  series_file=%s\n' "${group_series_file}"
            printf '  query_file=%s\n' "${group_query_file}"
        } >> "${metric_queries_file}"
    done < <(hm_metric_groups_list)

    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        remote_vm_series "${HM_PCM_L1_METRIC_NAME}{job=\"${HM_PCM_L1_JOB_NAME}\"}" "${query_dir}/pcm-core-l1-series.json" || true
        remote_vm_query_with_retries "count(${HM_PCM_L1_METRIC_NAME}{job=\"${HM_PCM_L1_JOB_NAME}\"})" "${query_dir}/pcm-core-l1-query.json" 4 3 || true
        remote_vm_series "${HM_PCM_L1_HIT_METRIC_NAME}{job=\"${HM_PCM_L1_JOB_NAME}\"}" "${query_dir}/pcm-core-l1-hit-series.json" || true
        remote_vm_query_with_retries "count(${HM_PCM_L1_HIT_METRIC_NAME}{job=\"${HM_PCM_L1_JOB_NAME}\"})" "${query_dir}/pcm-core-l1-hit-query.json" 4 3 || true
    fi

    remote_vm_series 'cpu_usage_idle{cpu="cpu-total"}' "${query_dir}/cpu-total-series.json" || true
    remote_vm_series 'cpu_usage_idle{cpu!="cpu-total"}' "${query_dir}/cpu-per-core-series.json" || true
    remote_vm_query_with_retries 'count(cpu_usage_idle{cpu="cpu-total"})' "${query_dir}/cpu-total-query.json" 7 5 || true
    remote_vm_query_with_retries 'count(cpu_usage_idle{cpu!="cpu-total"})' "${query_dir}/cpu-per-core-query.json" 7 5 || true
    jq -r '.data[]?.cpu // empty' "${query_dir}/cpu-per-core-series.json" | sort -u > "${query_dir}/cpu-labels.txt" || true
    cpu_distinct_label_count="$(grep -c . "${query_dir}/cpu-labels.txt" 2>/dev/null || true)"
    if json_series_has_entries "${query_dir}/cpu-total-series.json" && json_query_has_positive_samples "${query_dir}/cpu-total-query.json"; then
        cpu_total_present="true"
    fi
    if json_series_has_entries "${query_dir}/cpu-per-core-series.json" \
        && json_query_has_positive_samples "${query_dir}/cpu-per-core-query.json" \
        && [[ "${cpu_distinct_label_count}" -gt 1 ]]; then
        cpu_per_core_present="true"
    fi

    if [[ "${cpu_total_present}" != "true" ]]; then
        overall_status="fail"
        overall_reason="cpu-total-series-missing"
    fi
    if [[ "${cpu_per_core_present}" != "true" ]]; then
        overall_status="fail"
        overall_reason="cpu-per-core-series-missing"
    fi

    if [[ "${HM_ENABLE_PCM}" == "1" && "${HM_ENABLE_PCM_WATCHDOG}" == "1" ]]; then
        pcm_watchdog_status="fail"
        pcm_watchdog_reason="pcm-watchdog-service-inactive"
        if [[ "$(service_state_from_file "${service_dir}/${HM_PCM_WATCHDOG_SERVICE_NAME}.is-active.txt")" == "active" ]]; then
            pcm_watchdog_status="pass"
            pcm_watchdog_reason="pcm-watchdog-active"
        fi
    fi

    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        optional_l1_status="fail"
        optional_l1_reason="pcm-core-l1-not-ready"
        optional_l1_hit_status="fail"
        optional_l1_hit_reason="pcm-core-l1-hit-not-ready"
        if [[ "$(service_state_from_file "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.is-active.txt")" == "active" ]] \
            && grep -q "${HM_PCM_L1_METRIC_NAME}" "${endpoint_dir}/pcm-core-l1.metrics.head.txt" \
            && json_series_has_entries "${query_dir}/pcm-core-l1-series.json" \
            && json_query_has_positive_samples "${query_dir}/pcm-core-l1-query.json"; then
            optional_l1_status="pass"
            optional_l1_reason="pcm-core-l1-queryable"
        elif [[ "$(service_state_from_file "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.is-active.txt")" != "active" ]]; then
            optional_l1_reason="pcm-core-l1-service-inactive"
        elif ! grep -q "${HM_PCM_L1_METRIC_NAME}" "${endpoint_dir}/pcm-core-l1.metrics.head.txt"; then
            optional_l1_reason="pcm-core-l1-endpoint-missing-metric"
        elif ! json_series_has_entries "${query_dir}/pcm-core-l1-series.json"; then
            optional_l1_reason="pcm-core-l1-series-missing"
        else
            optional_l1_reason="pcm-core-l1-query-missing"
        fi

        if [[ "$(service_state_from_file "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.is-active.txt")" == "active" ]] \
            && grep -q "${HM_PCM_L1_HIT_METRIC_NAME}" "${endpoint_dir}/pcm-core-l1.metrics.head.txt" \
            && json_series_has_entries "${query_dir}/pcm-core-l1-hit-series.json" \
            && json_query_has_positive_samples "${query_dir}/pcm-core-l1-hit-query.json"; then
            optional_l1_hit_status="pass"
            optional_l1_hit_reason="pcm-core-l1-hit-queryable"
        elif [[ "$(service_state_from_file "${service_dir}/${HM_PCM_L1_SERVICE_NAME}.is-active.txt")" != "active" ]]; then
            optional_l1_hit_reason="pcm-core-l1-service-inactive"
        elif ! grep -q "${HM_PCM_L1_HIT_METRIC_NAME}" "${endpoint_dir}/pcm-core-l1.metrics.head.txt"; then
            optional_l1_hit_reason="pcm-core-l1-endpoint-missing-hit-metric"
        elif ! json_series_has_entries "${query_dir}/pcm-core-l1-hit-series.json"; then
            optional_l1_hit_reason="pcm-core-l1-hit-series-missing"
        else
            optional_l1_hit_reason="pcm-core-l1-hit-query-missing"
        fi
    fi

    if [[ -n "${hard_missing_groups}" ]]; then
        overall_status="fail"
        if [[ "${overall_reason}" == "all-required-checks-passed" || "${overall_reason}" == "external-groups-missing" ]]; then
            overall_reason="hard-required-groups-missing"
        fi
    elif [[ -n "${partial_missing_groups}" && "${overall_status}" == "pass" ]]; then
        overall_status="partial"
        overall_reason="external-groups-missing"
    fi

    if [[ "${group_status_map[cpu]:-missing}" == "pass" \
        && "${group_status_map[disk]:-missing}" == "pass" \
        && "${group_status_map[diskio]:-missing}" == "pass" ]]; then
        if [[ -z "${partial_missing_groups}" ]]; then
            node01_non_pcm_coverage_status="covered"
        else
            node01_non_pcm_coverage_status="partial"
        fi
    fi

    {
        printf 'HOST_MEASUREMENT_BACKEND=%s\n' "${backend_name}"
        printf 'HOST_MEASUREMENT_ACCEPTANCE_CONTRACT=%s\n' "${contract_name}"
        printf 'HOST_MEASUREMENT_ACCEPTED_SCOPE=%s\n' "${required_groups}"
        printf 'HOST_MEASUREMENT_EXCLUDED_SCOPE=%s\n' "${excluded_groups}"
        printf 'HOST_MEASUREMENT_PARTIAL_SCOPE=%s\n' "${partial_groups}"
        printf 'HOST_MEASUREMENT_STATUS=%s\n' "${overall_status}"
        printf 'HOST_MEASUREMENT_REASON=%s\n' "${overall_reason}"
        printf 'HOST_MEASUREMENT_ARTIFACT_DIR=%s\n' "${artifact_dir}"
        printf 'HOST_MEASUREMENT_PRESENT_GROUPS=%s\n' "${present_groups}"
        printf 'HOST_MEASUREMENT_MISSING_GROUPS=%s\n' "${missing_groups}"
        printf 'HOST_MEASUREMENT_HARD_MISSING_GROUPS=%s\n' "${hard_missing_groups}"
        printf 'HOST_MEASUREMENT_PARTIAL_MISSING_GROUPS=%s\n' "${partial_missing_groups}"
        printf 'HOST_MEASUREMENT_CPU_TOTAL_PRESENT=%s\n' "${cpu_total_present}"
        printf 'HOST_MEASUREMENT_CPU_PER_CORE_PRESENT=%s\n' "${cpu_per_core_present}"
        printf 'HOST_MEASUREMENT_CPU_DISTINCT_LABEL_COUNT=%s\n' "${cpu_distinct_label_count}"
        printf 'HOST_MEASUREMENT_NON_PCM_COVERAGE_STATUS=%s\n' "${node01_non_pcm_coverage_status}"
        printf 'HOST_MEASUREMENT_PCM_METRICS_URL=%s\n' "${HM_PCM_METRICS_URL}"
        printf 'HOST_MEASUREMENT_KUBE_PROXY_METRICS_URL=%s\n' "${HM_KUBE_PROXY_METRICS_URL}"
        printf 'HOST_MEASUREMENT_KUBELET_PROXY_METRICS_URL=%s\n' "${HM_KUBELET_PROXY_METRICS_URL}"
        printf 'HOST_MEASUREMENT_CADVISOR_PROXY_METRICS_URL=%s\n' "${HM_CADVISOR_PROXY_METRICS_URL}"
        printf 'HOST_MEASUREMENT_KUBE_STATE_METRICS_URLS=%s\n' "${HM_KSM_METRICS_URLS_CSV}"
        printf 'HOST_MEASUREMENT_KUBE_STATE_METRICS_SELF_URLS=%s\n' "${HM_KSM_SELF_METRICS_URLS_CSV}"
        printf 'HOST_MEASUREMENT_N9E_REMOTE_WRITE_URL=%s\n' "${HM_N9E_REMOTE_WRITE_URL}"
        printf 'HOST_MEASUREMENT_VM_REMOTE_WRITE_URL=%s\n' "${HM_VM_REMOTE_WRITE_URL}"
        printf 'HOST_MEASUREMENT_VMSINGLE_SERVICE=%s\n' "${HM_VMSINGLE_SERVICE_NAME}"
        printf 'HOST_MEASUREMENT_N9E_SERVICE=%s\n' "${HM_N9E_SERVICE_NAME}"
        printf 'HOST_MEASUREMENT_CATEGRAF_SERVICE=%s\n' "${HM_CATEGRAF_SERVICE_NAME}"
        printf 'HOST_MEASUREMENT_PCM_WATCHDOG_ENABLED=%s\n' "${HM_ENABLE_PCM_WATCHDOG}"
        printf 'HOST_MEASUREMENT_PCM_WATCHDOG_STATUS=%s\n' "${pcm_watchdog_status}"
        printf 'HOST_MEASUREMENT_PCM_WATCHDOG_REASON=%s\n' "${pcm_watchdog_reason}"
        printf 'HOST_MEASUREMENT_PCM_WATCHDOG_SERVICE=%s\n' "${HM_PCM_WATCHDOG_SERVICE_NAME}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_ENABLED=%s\n' "${HM_ENABLE_PCM_L1}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_STATUS=%s\n' "${optional_l1_status}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_REASON=%s\n' "${optional_l1_reason}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_SERVICE=%s\n' "${HM_PCM_L1_SERVICE_NAME}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_METRICS_URL=%s\n' "${HM_PCM_L1_METRICS_URL}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_METRIC_NAME=%s\n' "${HM_PCM_L1_METRIC_NAME}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_JOB_NAME=%s\n' "${HM_PCM_L1_JOB_NAME}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_HIT_METRIC_NAME=%s\n' "${HM_PCM_L1_HIT_METRIC_NAME}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_HIT_STATUS=%s\n' "${optional_l1_hit_status}"
        printf 'HOST_MEASUREMENT_OPTIONAL_PCM_L1_HIT_REASON=%s\n' "${optional_l1_hit_reason}"
        while IFS= read -r group; do
            [[ -n "${group}" ]] || continue
            group_key="$(group_env_key "${group}")"
            printf 'HOST_MEASUREMENT_GROUP_STATUS_%s=%s\n' "${group_key}" "${group_status_map[$group]:-unknown}"
            printf 'HOST_MEASUREMENT_GROUP_REASON_%s=%s\n' "${group_key}" "${group_reason_map[$group]:-unset}"
        done < <(hm_metric_groups_list)
    } > "${summary_env_file}"

    cat > "${summary_txt_file}" <<EOF
Backend                : ${backend_name}
Contract               : ${contract_name}
Status                 : ${overall_status}
Reason                 : ${overall_reason}
Artifact Dir           : ${artifact_dir}
Accepted scope         : ${required_groups}
Excluded scope         : ${excluded_groups:-none}
Partial scope          : ${partial_groups}
Present groups         : ${present_groups:-none}
Missing groups         : ${missing_groups:-none}
Hard missing groups    : ${hard_missing_groups:-none}
Partial missing groups : ${partial_missing_groups:-none}
Non-PCM coverage       : ${node01_non_pcm_coverage_status}
CPU total present      : ${cpu_total_present}
CPU per-core present   : ${cpu_per_core_present}
CPU label count        : ${cpu_distinct_label_count}
PCM URL                : ${HM_PCM_METRICS_URL}
Kube-Proxy URL         : ${HM_KUBE_PROXY_METRICS_URL}
Kubelet proxy URL      : ${HM_KUBELET_PROXY_METRICS_URL:-none}
Cadvisor proxy URL     : ${HM_CADVISOR_PROXY_METRICS_URL:-none}
KSM metrics URLs       : ${HM_KSM_METRICS_URLS_CSV:-none}
KSM self URLs          : ${HM_KSM_SELF_METRICS_URLS_CSV:-none}
Categraf -> N9E        : ${HM_N9E_REMOTE_WRITE_URL}
N9E -> VM              : ${HM_VM_REMOTE_WRITE_URL}
Services               : ${HM_VMSINGLE_SERVICE_NAME}, ${HM_N9E_SERVICE_NAME}, ${HM_CATEGRAF_SERVICE_NAME}
PCM Watchdog           : ${pcm_watchdog_status}
PCM Watchdog Reason    : ${pcm_watchdog_reason}
Optional PCM L1        : ${optional_l1_status}
Optional PCM L1 Reason : ${optional_l1_reason}
Optional PCM L1 URL    : ${HM_PCM_L1_METRICS_URL}
Optional PCM L1 Metric : ${HM_PCM_L1_METRIC_NAME}{job="${HM_PCM_L1_JOB_NAME}"}
Optional PCM L1 Hit    : ${HM_PCM_L1_HIT_METRIC_NAME}{job="${HM_PCM_L1_JOB_NAME}"}
Optional PCM L1 Hit St : ${optional_l1_hit_status}
Optional PCM L1 Hit Re : ${optional_l1_hit_reason}
CPU labels artifact    : ${query_dir}/cpu-labels.txt
Evidence               : ${metrics_names_file}
EOF

    if [[ "${print_summary}" == "true" ]]; then
        cat "${summary_txt_file}"
    fi

    if [[ "${overall_status}" == "fail" ]]; then
        die "host measurement verification ${overall_status}: ${overall_reason}"
    fi
    return 0
}

main "$@"
