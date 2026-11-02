#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: refresh_node01_l1_exporter.sh [--env-file <path>] [--ssh-target <host>] [--ssh-user <user>] [--state-dir <dir>] [--print-summary]

Refresh only the optional pcm-core L1 exporter assets on node01 and restart the host-managed exporter service.
EOF
}

main() {
    local env_file="" state_dir="" print_summary=false
    local payload_dir command_file resolved_env_file rendered_env_file
    local remote_stage remote_env_file remote_log summary_env_file summary_txt_file
    local -a original_args=("$@")

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
            --state-dir)
                [[ $# -ge 2 ]] || die "missing value for --state-dir"
                state_dir=$2
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
    [[ "${HM_ENABLE_PCM_L1}" == "1" ]] || die "pcm-core-l1 is disabled in the current host measurement config"

    [[ -n "${state_dir}" ]] || state_dir="$(hm_make_state_dir refresh-l1-exporter)"
    mkdir -p "${state_dir}"
    payload_dir="${state_dir}/payload"
    command_file="${state_dir}/command.txt"
    resolved_env_file="${state_dir}/resolved.env"
    rendered_env_file="${state_dir}/remote.env"
    remote_log="${state_dir}/remote-refresh.log"
    summary_env_file="${state_dir}/summary.env"
    summary_txt_file="${state_dir}/summary.txt"

    hm_write_command_file "${command_file}" "$0" "${original_args[@]}"
    hm_write_resolved_env "${resolved_env_file}"
    hm_render_payload "${payload_dir}"

    remote_stage="${HM_STAGE_DIR%/}/refresh-l1-$(hm_now_stamp)"
    remote_env_file="${remote_stage}/remote.env"
    cat > "${rendered_env_file}" <<EOF
$(cat "${resolved_env_file}")
remote_stage=${remote_stage}
EOF

    log_info "staging refreshed pcm-core L1 exporter payload on ${HM_SSH_TARGET_REF}:${remote_stage}"
    ssh "${HM_SSH_TARGET_REF}" "rm -rf '${remote_stage}' && mkdir -p '${remote_stage}'"
    scp -r "${payload_dir}/pcm-core-l1" "${HM_SSH_TARGET_REF}:${remote_stage}/pcm-core-l1" >/dev/null
    scp "${payload_dir}/systemd/${HM_PCM_L1_SERVICE_NAME}.service" "${HM_SSH_TARGET_REF}:${remote_stage}/${HM_PCM_L1_SERVICE_NAME}.service" >/dev/null
    scp "${rendered_env_file}" "${HM_SSH_TARGET_REF}:${remote_env_file}" >/dev/null

    log_info "refreshing pcm-core L1 exporter service on ${HM_SSH_TARGET_REF}"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${remote_stage}'" > "${remote_log}" 2>&1 <<'EOF'
set -euo pipefail

remote_stage=$1
source "${remote_stage}/remote.env"

install -d -m 0755 -o root -g root "${config_root}/pcm-core-l1" "${install_prefix}/pcm-core-l1" "${data_root}/pcm-core-l1"
install -m 0755 "${remote_stage}/pcm-core-l1/pcm_core_l1_exporter.py" "${pcm_l1_script_path}"
install -m 0644 "${remote_stage}/pcm-core-l1/exporter.env" "${pcm_l1_env_file}"
install -m 0644 "${remote_stage}/${pcm_l1_service_name}.service" "/etc/systemd/system/${pcm_l1_service_name}.service"
systemctl daemon-reload
systemctl enable "${pcm_l1_service_name}.service" >/dev/null
systemctl restart "${pcm_l1_service_name}.service"
for _ in $(seq 1 30); do
    if curl -fsS "${pcm_l1_health_url}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS "${pcm_l1_health_url}" >/dev/null
curl -fsS "${pcm_l1_metrics_url}" | grep -q "${pcm_l1_miss_metric_name}"
if [[ -n "${pcm_l1_hit_metric_name:-}" ]]; then
    curl -fsS "${pcm_l1_metrics_url}" | grep -q "${pcm_l1_hit_metric_name}"
fi
EOF

    ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl is-active ${HM_PCM_L1_SERVICE_NAME}.service" > "${state_dir}/service-active.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -fsS ${HM_PCM_L1_HEALTH_URL}" > "${state_dir}/health.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -fsS ${HM_PCM_L1_METRICS_URL} | sed -n '1,120p'" > "${state_dir}/metrics.head.txt"

    cat > "${summary_env_file}" <<EOF
PCM_L1_REFRESH_STATUS=pass
PCM_L1_REFRESH_REASON=service-restarted-with-updated-exporter
PCM_L1_REFRESH_STATE_DIR=${state_dir}
PCM_L1_REFRESH_SERVICE=${HM_PCM_L1_SERVICE_NAME}
PCM_L1_REFRESH_METRICS_URL=${HM_PCM_L1_METRICS_URL}
PCM_L1_REFRESH_HEALTH_URL=${HM_PCM_L1_HEALTH_URL}
PCM_L1_REFRESH_MISS_METRIC=${HM_PCM_L1_METRIC_NAME}
PCM_L1_REFRESH_HIT_METRIC=${HM_PCM_L1_HIT_METRIC_NAME}
EOF

    cat > "${summary_txt_file}" <<EOF
PCM L1 refresh status : pass
Reason                : service-restarted-with-updated-exporter
State dir             : ${state_dir}
Service               : ${HM_PCM_L1_SERVICE_NAME}
Metrics URL           : ${HM_PCM_L1_METRICS_URL}
Health URL            : ${HM_PCM_L1_HEALTH_URL}
Miss metric           : ${HM_PCM_L1_METRIC_NAME}
Hit metric            : ${HM_PCM_L1_HIT_METRIC_NAME}
EOF

    if [[ "${print_summary}" == "true" ]]; then
        cat "${summary_txt_file}"
    fi
}

main "$@"
