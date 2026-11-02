#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: cleanup_node01_measurement_stack.sh [--env-file <path>] [--ssh-target <host>] [--ssh-user <user>] [--state-dir <dir>] [--purge-data] [--print-summary]

Stop and remove the Step 4 host-managed measurement stack from node01.
By default, data under /var/lib/nsm-ovs/measurement is preserved.
EOF
}

main() {
    local env_file="" state_dir="" purge_data=false print_summary=false
    local command_file resolved_env_file cleanup_log cleanup_summary
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
            --purge-data)
                purge_data=true
                shift
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

    [[ -n "${state_dir}" ]] || state_dir="$(hm_make_state_dir cleanup-stack)"
    mkdir -p "${state_dir}"
    command_file="${state_dir}/command.txt"
    resolved_env_file="${state_dir}/resolved.env"
    cleanup_log="${state_dir}/cleanup.log"
    cleanup_summary="${state_dir}/cleanup-summary.txt"
    hm_write_command_file "${command_file}" "$0" "${original_args[@]}"
    hm_write_resolved_env "${resolved_env_file}"

    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${HM_INSTALL_PREFIX}' '${HM_CONFIG_ROOT}' '${HM_DATA_ROOT}' '${HM_VMSINGLE_SERVICE_NAME}' '${HM_N9E_SERVICE_NAME}' '${HM_CATEGRAF_SERVICE_NAME}' '${HM_PCM_WATCHDOG_SERVICE_NAME}' '${HM_PCM_L1_SERVICE_NAME}' '${purge_data}'" > "${cleanup_log}" 2>&1 <<'EOF'
set -euo pipefail

install_prefix=$1
config_root=$2
data_root=$3
vm_service_name=$4
n9e_service_name=$5
categraf_service_name=$6
pcm_watchdog_service_name=$7
pcm_l1_service_name=$8
purge_data=$9

for service in "${pcm_watchdog_service_name}" "${pcm_l1_service_name}" "${categraf_service_name}" "${n9e_service_name}" "${vm_service_name}"; do
    systemctl stop "${service}.service" >/dev/null 2>&1 || true
    systemctl disable "${service}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${service}.service"
done

systemctl daemon-reload

rm -rf "${install_prefix}/categraf" "${install_prefix}/n9e" "${install_prefix}/victoriametrics"
rm -rf "${install_prefix}/pcm-sensor-watchdog"
rm -rf "${install_prefix}/pcm-core-l1"
rm -rf "${config_root}/categraf" "${config_root}/n9e" "${config_root}/pcm-sensor-watchdog" "${config_root}/pcm-core-l1"

if [[ "${purge_data}" == "true" ]]; then
    rm -rf "${data_root}/categraf" "${data_root}/n9e" "${data_root}/victoriametrics" "${data_root}/pcm-sensor-watchdog" "${data_root}/pcm-core-l1"
fi

printf 'purge_data=%s\n' "${purge_data}"
printf 'removed_services=%s,%s,%s,%s,%s\n' "${vm_service_name}" "${n9e_service_name}" "${categraf_service_name}" "${pcm_watchdog_service_name}" "${pcm_l1_service_name}"
EOF

    cat > "${cleanup_summary}" <<EOF
Target          : ${HM_SSH_TARGET_REF}
Purge Data      : ${purge_data}
Services Removed: ${HM_VMSINGLE_SERVICE_NAME}, ${HM_N9E_SERVICE_NAME}, ${HM_CATEGRAF_SERVICE_NAME}, ${HM_PCM_WATCHDOG_SERVICE_NAME}, ${HM_PCM_L1_SERVICE_NAME}
State Dir       : ${state_dir}
EOF

    if [[ "${print_summary}" == "true" ]]; then
        cat "${cleanup_summary}"
    fi
}

main "$@"
