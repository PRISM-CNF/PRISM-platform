#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: refresh_node01_pcm_watchdog.sh [--env-file <path>] [--ssh-target <host>] [--ssh-user <user>] [--state-dir <dir>] [--print-summary]

Refresh only the node01 pcm-sensor-server watchdog assets and restart the watchdog service.
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
    [[ "${HM_ENABLE_PCM}" == "1" ]] || die "pcm is disabled in the current host measurement config"
    [[ "${HM_ENABLE_PCM_WATCHDOG}" == "1" ]] || die "pcm watchdog is disabled in the current host measurement config"

    [[ -n "${state_dir}" ]] || state_dir="$(hm_make_state_dir refresh-pcm-watchdog)"
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

    remote_stage="${HM_STAGE_DIR%/}/refresh-pcm-watchdog-$(hm_now_stamp)"
    remote_env_file="${remote_stage}/remote.env"
    cat > "${rendered_env_file}" <<EOF
$(cat "${resolved_env_file}")
remote_stage=${remote_stage}
EOF

    log_info "staging refreshed pcm watchdog payload on ${HM_SSH_TARGET_REF}:${remote_stage}"
    ssh "${HM_SSH_TARGET_REF}" "rm -rf '${remote_stage}' && mkdir -p '${remote_stage}'"
    scp -r "${payload_dir}/pcm-sensor-watchdog" "${HM_SSH_TARGET_REF}:${remote_stage}/pcm-sensor-watchdog" >/dev/null
    scp "${payload_dir}/systemd/${HM_PCM_WATCHDOG_SERVICE_NAME}.service" "${HM_SSH_TARGET_REF}:${remote_stage}/${HM_PCM_WATCHDOG_SERVICE_NAME}.service" >/dev/null
    scp "${rendered_env_file}" "${HM_SSH_TARGET_REF}:${remote_env_file}" >/dev/null

    log_info "refreshing pcm watchdog service on ${HM_SSH_TARGET_REF}"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${remote_stage}'" > "${remote_log}" 2>&1 <<'EOF'
set -euo pipefail

remote_stage=$1
source "${remote_stage}/remote.env"

install -d -m 0755 -o root -g root "${config_root}/pcm-sensor-watchdog" "${install_prefix}/pcm-sensor-watchdog" "${data_root}/pcm-sensor-watchdog"
install -m 0755 "${remote_stage}/pcm-sensor-watchdog/pcm_sensor_watchdog.sh" "${pcm_watchdog_script_path}"
install -m 0644 "${remote_stage}/pcm-sensor-watchdog/watchdog.env" "${pcm_watchdog_env_file}"
install -m 0644 "${remote_stage}/${pcm_watchdog_service_name}.service" "/etc/systemd/system/${pcm_watchdog_service_name}.service"
systemctl daemon-reload
systemctl enable "${pcm_watchdog_service_name}.service" >/dev/null
systemctl restart "${pcm_watchdog_service_name}.service"
for _ in $(seq 1 30); do
    if systemctl is-active "${pcm_watchdog_service_name}.service" >/dev/null 2>&1 && curl -fsS "${pcm_metrics_url}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
systemctl is-active "${pcm_watchdog_service_name}.service" >/dev/null
curl -fsS "${pcm_metrics_url}" >/dev/null
EOF

    ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl is-active ${HM_PCM_WATCHDOG_SERVICE_NAME}.service" > "${state_dir}/watchdog-service-active.txt"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n systemctl status ${HM_PCM_WATCHDOG_SERVICE_NAME}.service --no-pager || true" > "${state_dir}/watchdog-service-status.txt"
    ssh "${HM_SSH_TARGET_REF}" "curl -fsS ${HM_PCM_METRICS_URL} | sed -n '1,40p'" > "${state_dir}/pcm.metrics.head.txt"

    cat > "${summary_env_file}" <<EOF
PCM_WATCHDOG_REFRESH_STATUS=pass
PCM_WATCHDOG_REFRESH_REASON=service-restarted-with-updated-watchdog
PCM_WATCHDOG_REFRESH_STATE_DIR=${state_dir}
PCM_WATCHDOG_REFRESH_SERVICE=${HM_PCM_WATCHDOG_SERVICE_NAME}
PCM_WATCHDOG_REFRESH_TARGET_SERVICE=${HM_PCM_SENSOR_SERVICE_NAME}
PCM_WATCHDOG_REFRESH_PCM_URL=${HM_PCM_METRICS_URL}
EOF

    cat > "${summary_txt_file}" <<EOF
PCM watchdog refresh status : pass
Reason                      : service-restarted-with-updated-watchdog
State dir                   : ${state_dir}
Watchdog service            : ${HM_PCM_WATCHDOG_SERVICE_NAME}
Target service              : ${HM_PCM_SENSOR_SERVICE_NAME}
PCM URL                     : ${HM_PCM_METRICS_URL}
EOF

    if [[ "${print_summary}" == "true" ]]; then
        cat "${summary_txt_file}"
    fi
}

main "$@"
