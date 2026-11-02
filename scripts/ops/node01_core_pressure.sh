#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"

usage() {
    cat <<'EOF'
Usage: node01_core_pressure.sh <start|stop|restart|status> [--ssh-target <host>] [--ssh-user <user>] [--cpu <id>] [--load <pct>] [--unit <name>] [--quota-period <value>]

Manage a host-side background CPU pressure source on node01.

Defaults:
  action        status
  ssh target    ${NSM_OVS_HOST_MEASUREMENT_SSH_TARGET:-node01}
  ssh user      ${NSM_OVS_HOST_MEASUREMENT_SSH_USER:-<none>}
  cpu           4
  load          98
  quota period  100ms
  unit          nsm-core<cpu>-pressure.service

Implementation:
  - pins the pressure source onto one logical CPU with systemd CPUAffinity
  - caps it with systemd CPUQuota to the requested percentage
  - uses a simple busy loop (`yes >/dev/null`) so quota is the controlling factor
EOF
}

node01_pressure_remote_status() {
    local unit=$1
    sudo systemctl show \
        -p Id \
        -p MainPID \
        -p ActiveState \
        -p SubState \
        -p CPUAffinity \
        -p CPUQuotaPerSecUSec \
        -p CPUQuotaPeriodUSec \
        "$unit" || true

    local pid
    pid="$(sudo systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" != "0" ]]; then
        ps -p "${pid}" -o pid,psr,%cpu,cmd
    fi
}

main() {
    local action="status"
    local ssh_target="${NSM_OVS_HOST_MEASUREMENT_SSH_TARGET:-node01}"
    local ssh_user="${NSM_OVS_HOST_MEASUREMENT_SSH_USER:-}"
    local cpu="4"
    local load="98"
    local quota_period="100ms"
    local unit=""
    local ssh_ref

    if [[ $# -gt 0 ]]; then
        case "$1" in
            start|stop|restart|status)
                action="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
        esac
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh-target)
                [[ $# -ge 2 ]] || die "missing value for --ssh-target"
                ssh_target="$2"
                shift 2
                ;;
            --ssh-user)
                [[ $# -ge 2 ]] || die "missing value for --ssh-user"
                ssh_user="$2"
                shift 2
                ;;
            --cpu)
                [[ $# -ge 2 ]] || die "missing value for --cpu"
                cpu="$2"
                shift 2
                ;;
            --load)
                [[ $# -ge 2 ]] || die "missing value for --load"
                load="$2"
                shift 2
                ;;
            --unit)
                [[ $# -ge 2 ]] || die "missing value for --unit"
                unit="$2"
                shift 2
                ;;
            --quota-period)
                [[ $# -ge 2 ]] || die "missing value for --quota-period"
                quota_period="$2"
                shift 2
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

    require_command ssh

    [[ "${cpu}" =~ ^[0-9]+$ ]] || die "cpu must be a non-negative integer: ${cpu}"
    [[ "${load}" =~ ^[0-9]+$ ]] || die "load must be an integer percentage: ${load}"
    (( load >= 1 && load <= 100 )) || die "load must be within 1..100: ${load}"
    [[ -n "${quota_period}" ]] || die "quota period must not be empty"

    if [[ -z "${unit}" ]]; then
        unit="nsm-core${cpu}-pressure.service"
    fi

    ssh_ref="${ssh_target}"
    if [[ "${ssh_ref}" != *@* && -n "${ssh_user}" ]]; then
        ssh_ref="${ssh_user}@${ssh_ref}"
    fi

    case "${action}" in
        start)
            log_info "starting node01 core pressure: target=${ssh_ref} unit=${unit} cpu=${cpu} load=${load}% quota_period=${quota_period}"
            ssh "${ssh_ref}" "sudo systemctl stop '${unit}' >/dev/null 2>&1 || true"
            ssh "${ssh_ref}" "sudo systemd-run \
                --unit '${unit}' \
                --property=CPUAffinity='${cpu}' \
                --property=CPUQuota='${load}%' \
                --property=CPUQuotaPeriodSec='${quota_period}' \
                --property=Restart=always \
                --property=RestartSec=1s \
                /bin/sh -lc 'exec yes >/dev/null'"
            sleep 3
            ssh "${ssh_ref}" "$(declare -f node01_pressure_remote_status); node01_pressure_remote_status '${unit}'"
            ;;
        stop)
            log_info "stopping node01 core pressure: target=${ssh_ref} unit=${unit}"
            ssh "${ssh_ref}" "sudo systemctl stop '${unit}' >/dev/null 2>&1 || true; sudo systemctl show -p Id -p MainPID -p ActiveState -p SubState '${unit}' || true"
            ;;
        restart)
            local stop_args=(
                stop
                --ssh-target "${ssh_target}"
                --unit "${unit}"
            )
            local restart_args=(
                start
                --ssh-target "${ssh_target}"
                --cpu "${cpu}"
                --load "${load}"
                --unit "${unit}"
                --quota-period "${quota_period}"
            )
            if [[ -n "${ssh_user}" ]]; then
                stop_args+=(--ssh-user "${ssh_user}")
                restart_args+=(--ssh-user "${ssh_user}")
            fi
            "${BASH_SOURCE[0]}" "${stop_args[@]}"
            "${BASH_SOURCE[0]}" "${restart_args[@]}"
            ;;
        status)
            log_info "checking node01 core pressure: target=${ssh_ref} unit=${unit}"
            ssh "${ssh_ref}" "$(declare -f node01_pressure_remote_status); node01_pressure_remote_status '${unit}'"
            ;;
        *)
            die "unsupported action: ${action}"
            ;;
    esac
}

main "$@"
