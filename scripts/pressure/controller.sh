#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/cpuset.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/pressure/lib/profile_parser.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/pressure/lib/plugin_loader.sh"

pressure_controller_usage() {
    cat <<'EOF'
Usage:
  scripts/pressure/controller.sh start-profile --state-dir <dir> --duration <seconds> [--target-node <node>] [--ssh-user <user>] [--remote-workdir <dir>] [profile-options]
  scripts/pressure/controller.sh stop-profile --state-dir <dir>

Profile options:
  --pressure '<plugin>:intensity=<n>,cpuset=<csv>[,key=value...]'
  --pressure-dim <name> --intensity <n> [--intensity-cpuset <csv>] [--pressure-param <key=value>]
EOF
}

pressure_controller_default_cpuset() {
    printf '%s\n' "${NSM_OVS_PRESSURE_CPUSET:-0}"
}

pressure_controller_default_target_node() {
    hostname -s 2>/dev/null || hostname
}

pressure_controller_default_ssh_user() {
    printf '%s\n' "${NSM_OVS_PRESSURE_SSH_USER:-${NSM_OVS_HOST_MEASUREMENT_SSH_USER:-root}}"
}

pressure_controller_default_remote_workdir() {
    printf '%s\n' "${NSM_OVS_PRESSURE_REMOTE_WORKDIR:-/var/tmp/nsm-ovs-pressure}"
}

pressure_controller_target_is_local() {
    local target_node=${1:-}
    local short_host='' full_host='' plain_host=''

    [[ -n "${target_node}" ]] || return 0
    case "${target_node}" in
        localhost|127.0.0.1|::1)
            return 0
            ;;
    esac

    short_host="$(hostname -s 2>/dev/null || true)"
    full_host="$(hostname -f 2>/dev/null || true)"
    plain_host="$(hostname 2>/dev/null || true)"

    [[ -n "${short_host}" && "${target_node}" == "${short_host}" ]] && return 0
    [[ -n "${full_host}" && "${target_node}" == "${full_host}" ]] && return 0
    [[ -n "${plain_host}" && "${target_node}" == "${plain_host}" ]] && return 0
    return 1
}

pressure_controller_ssh_target_ref() {
    local target_node=${1:-}
    local ssh_user=${2:-}

    if [[ "${target_node}" == *@* || -z "${ssh_user}" ]]; then
        printf '%s\n' "${target_node}"
    else
        printf '%s@%s\n' "${ssh_user}" "${target_node}"
    fi
}

pressure_controller_remote_run_dir() {
    local remote_workdir=$1
    local state_dir=$2
    local parent_label='' state_label='' timestamp='' suffix=''

    parent_label="$(basename "$(dirname "${state_dir}")")"
    state_label="$(basename "${state_dir}")"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    suffix="${timestamp}-$$"
    printf '%s/runs/%s-%s-%s\n' "${remote_workdir}" "${parent_label}" "${state_label}" "${suffix}"
}

pressure_controller_remote_invoke() {
    local ssh_target_ref=$1
    shift

    ssh "${ssh_target_ref}" 'bash -s' -- "$@" <<'EOF'
set -euo pipefail
"$@"
EOF
}

pressure_controller_remote_fetch_file() {
    local ssh_target_ref=$1
    local remote_path=$2
    local local_path=$3

    mkdir -p "$(dirname "${local_path}")"
    scp -B -q "${ssh_target_ref}:${remote_path}" "${local_path}" >/dev/null 2>&1
}

pressure_controller_verify_remote_exec_ready() {
    [[ "${PRESSURE_STATE_EXEC_MODE}" == "ssh" ]] || return 0
    [[ -n "${PRESSURE_STATE_SSH_TARGET_REF}" ]] || die "remote pressure exec mode requires an SSH target ref"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${PRESSURE_STATE_SSH_TARGET_REF}" \
        "command -v bash >/dev/null 2>&1 && mkdir -p '${PRESSURE_STATE_REMOTE_RUN_DIR}'" >/dev/null 2>&1; then
        die "remote pressure target ${PRESSURE_STATE_SSH_TARGET_REF} is not reachable with passwordless SSH; configure key-based login first"
    fi
}

declare -ga PRESSURE_STATE_ENTRY_SOURCE_PLUGIN_DIRS=()
declare -ga PRESSURE_STATE_ENTRY_START_SCRIPTS=()
declare -ga PRESSURE_STATE_ENTRY_STOP_SCRIPTS=()
declare -ga PRESSURE_STATE_ENTRY_PID_FILES=()
declare -ga PRESSURE_STATE_ENTRY_LOCAL_LOG_FILES=()
declare -ga PRESSURE_STATE_ENTRY_REMOTE_LOG_FILES=()
declare -ga PRESSURE_STATE_ENTRY_REMOTE_PLUGIN_DIRS=()
declare -g PRESSURE_STATE_TARGET_NODE=''
declare -g PRESSURE_STATE_EXEC_MODE='local'
declare -g PRESSURE_STATE_SSH_USER=''
declare -g PRESSURE_STATE_SSH_TARGET_REF=''
declare -g PRESSURE_STATE_REMOTE_WORKDIR=''
declare -g PRESSURE_STATE_REMOTE_RUN_DIR=''

pressure_controller_reset_state_layout() {
    PRESSURE_STATE_ENTRY_SOURCE_PLUGIN_DIRS=()
    PRESSURE_STATE_ENTRY_START_SCRIPTS=()
    PRESSURE_STATE_ENTRY_STOP_SCRIPTS=()
    PRESSURE_STATE_ENTRY_PID_FILES=()
    PRESSURE_STATE_ENTRY_LOCAL_LOG_FILES=()
    PRESSURE_STATE_ENTRY_REMOTE_LOG_FILES=()
    PRESSURE_STATE_ENTRY_REMOTE_PLUGIN_DIRS=()
    PRESSURE_STATE_TARGET_NODE=''
    PRESSURE_STATE_EXEC_MODE='local'
    PRESSURE_STATE_SSH_USER=''
    PRESSURE_STATE_SSH_TARGET_REF=''
    PRESSURE_STATE_REMOTE_WORKDIR=''
    PRESSURE_STATE_REMOTE_RUN_DIR=''
}

pressure_controller_plan_state_layout() {
    local state_dir=$1
    local target_node=$2
    local exec_mode=$3
    local ssh_user=$4
    local ssh_target_ref=$5
    local remote_workdir=$6
    local remote_run_dir=$7
    local index plugin_name plugin_dir local_log_file remote_plugin_dir remote_log_file
    local start_script stop_script pid_file

    pressure_controller_reset_state_layout
    PRESSURE_STATE_TARGET_NODE="${target_node}"
    PRESSURE_STATE_EXEC_MODE="${exec_mode}"
    PRESSURE_STATE_SSH_USER="${ssh_user}"
    PRESSURE_STATE_SSH_TARGET_REF="${ssh_target_ref}"
    PRESSURE_STATE_REMOTE_WORKDIR="${remote_workdir}"
    PRESSURE_STATE_REMOTE_RUN_DIR="${remote_run_dir}"

    for (( index = 0; index < PRESSURE_PROFILE_ENTRY_COUNT; index++ )); do
        plugin_name="${PRESSURE_PROFILE_PLUGINS[${index}]}"
        pressure_plugin_load "${plugin_name}"
        plugin_dir="${PRESSURE_PLUGIN_DIR}"
        local_log_file="${state_dir}/entry-$(printf '%02d' "$((index + 1))").log"

        if [[ "${exec_mode}" == "ssh" ]]; then
            remote_plugin_dir="${remote_run_dir}/plugins/entry-$(printf '%02d' "$((index + 1))")-${plugin_name}"
            remote_log_file="${remote_run_dir}/logs/entry-$(printf '%02d' "$((index + 1))").log"
            start_script="${remote_plugin_dir}/start.sh"
            stop_script="${remote_plugin_dir}/stop.sh"
            pid_file="${remote_run_dir}/state/entry-$(printf '%02d' "$((index + 1))").pid"
        else
            remote_plugin_dir=''
            remote_log_file=''
            start_script="${PRESSURE_PLUGIN_START_SCRIPT}"
            stop_script="${PRESSURE_PLUGIN_STOP_SCRIPT}"
            pid_file="${state_dir}/entry-$(printf '%02d' "$((index + 1))").pid"
        fi

        PRESSURE_STATE_ENTRY_SOURCE_PLUGIN_DIRS+=("${plugin_dir}")
        PRESSURE_STATE_ENTRY_START_SCRIPTS+=("${start_script}")
        PRESSURE_STATE_ENTRY_STOP_SCRIPTS+=("${stop_script}")
        PRESSURE_STATE_ENTRY_PID_FILES+=("${pid_file}")
        PRESSURE_STATE_ENTRY_LOCAL_LOG_FILES+=("${local_log_file}")
        PRESSURE_STATE_ENTRY_REMOTE_LOG_FILES+=("${remote_log_file}")
        PRESSURE_STATE_ENTRY_REMOTE_PLUGIN_DIRS+=("${remote_plugin_dir}")
    done
}

pressure_controller_stage_remote_entries() {
    local index remote_plugin_dir source_plugin_dir

    [[ "${PRESSURE_STATE_EXEC_MODE}" == "ssh" ]] || return 0
    [[ -n "${PRESSURE_STATE_SSH_TARGET_REF}" ]] || die "remote pressure exec mode requires an SSH target ref"
    [[ -n "${PRESSURE_STATE_REMOTE_RUN_DIR}" ]] || die "remote pressure exec mode requires a remote run dir"

    pressure_controller_verify_remote_exec_ready
    ssh "${PRESSURE_STATE_SSH_TARGET_REF}" "mkdir -p '${PRESSURE_STATE_REMOTE_RUN_DIR}/plugins' '${PRESSURE_STATE_REMOTE_RUN_DIR}/state' '${PRESSURE_STATE_REMOTE_RUN_DIR}/logs'"

    for (( index = 0; index < PRESSURE_PROFILE_ENTRY_COUNT; index++ )); do
        remote_plugin_dir="${PRESSURE_STATE_ENTRY_REMOTE_PLUGIN_DIRS[${index}]}"
        source_plugin_dir="${PRESSURE_STATE_ENTRY_SOURCE_PLUGIN_DIRS[${index}]}"
        [[ -n "${remote_plugin_dir}" ]] || die "missing remote plugin dir for entry $((index + 1))"
        ssh "${PRESSURE_STATE_SSH_TARGET_REF}" "mkdir -p '${remote_plugin_dir}'"
        scp -B -rq "${source_plugin_dir}/." "${PRESSURE_STATE_SSH_TARGET_REF}:${remote_plugin_dir}/"
        ssh "${PRESSURE_STATE_SSH_TARGET_REF}" "chmod 0755 '${PRESSURE_STATE_ENTRY_START_SCRIPTS[${index}]}' '${PRESSURE_STATE_ENTRY_STOP_SCRIPTS[${index}]}'"
    done
}

pressure_controller_parse_profile_args() {
    local default_cpuset=''
    local plugin_name=''
    local intensity=''
    local -a specs=()
    local -a params=()
    local params_csv=''

    default_cpuset="$(pressure_controller_default_cpuset)"
    pressure_profile_reset

    while [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -gt 0 ]]; do
        case "${PRESSURE_CONTROLLER_ARGS[0]}" in
            --pressure)
                [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -ge 2 ]] || die "missing value for --pressure"
                specs+=("${PRESSURE_CONTROLLER_ARGS[1]}")
                PRESSURE_CONTROLLER_ARGS=("${PRESSURE_CONTROLLER_ARGS[@]:2}")
                ;;
            --pressure-dim)
                [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -ge 2 ]] || die "missing value for --pressure-dim"
                plugin_name="${PRESSURE_CONTROLLER_ARGS[1]}"
                PRESSURE_CONTROLLER_ARGS=("${PRESSURE_CONTROLLER_ARGS[@]:2}")
                ;;
            --intensity)
                [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -ge 2 ]] || die "missing value for --intensity"
                intensity="${PRESSURE_CONTROLLER_ARGS[1]}"
                PRESSURE_CONTROLLER_ARGS=("${PRESSURE_CONTROLLER_ARGS[@]:2}")
                ;;
            --intensity-cpuset)
                [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -ge 2 ]] || die "missing value for --intensity-cpuset"
                default_cpuset="${PRESSURE_CONTROLLER_ARGS[1]}"
                PRESSURE_CONTROLLER_ARGS=("${PRESSURE_CONTROLLER_ARGS[@]:2}")
                ;;
            --pressure-param)
                [[ ${#PRESSURE_CONTROLLER_ARGS[@]} -ge 2 ]] || die "missing value for --pressure-param"
                params+=("${PRESSURE_CONTROLLER_ARGS[1]}")
                PRESSURE_CONTROLLER_ARGS=("${PRESSURE_CONTROLLER_ARGS[@]:2}")
                ;;
            *)
                die "unknown pressure controller profile argument: ${PRESSURE_CONTROLLER_ARGS[0]}"
                ;;
        esac
    done

    if [[ "${#specs[@]}" -gt 0 ]]; then
        for spec in "${specs[@]}"; do
            pressure_profile_parse_spec "${spec}" "${default_cpuset}"
        done
        return 0
    fi

    [[ -n "${plugin_name}" ]] || die "start-profile requires --pressure or --pressure-dim"
    [[ -n "${intensity}" ]] || die "start-profile requires --intensity when using --pressure-dim"

    if [[ "${#params[@]}" -gt 0 ]]; then
        params_csv="$(IFS=,; printf '%s' "${params[*]}")"
    fi
    pressure_profile_add_entry "${plugin_name}" "${intensity}" "${default_cpuset}" "" "${params_csv}"
}

pressure_controller_write_state() {
    local state_dir=$1
    local duration=$2
    local index plugin_name cpuset intensity physical

    mkdir -p "${state_dir}"

    {
        printf 'PRESSURE_STATE_ENTRY_COUNT=%s\n' "${PRESSURE_PROFILE_ENTRY_COUNT}"
        printf 'PRESSURE_STATE_DURATION_SECONDS=%s\n' "${duration}"
        printf 'PRESSURE_STATE_TARGET_NODE=%s\n' "${PRESSURE_STATE_TARGET_NODE}"
        printf 'PRESSURE_STATE_EXEC_MODE=%s\n' "${PRESSURE_STATE_EXEC_MODE}"
        printf 'PRESSURE_STATE_SSH_USER=%s\n' "${PRESSURE_STATE_SSH_USER}"
        printf 'PRESSURE_STATE_SSH_TARGET_REF=%s\n' "${PRESSURE_STATE_SSH_TARGET_REF}"
        printf 'PRESSURE_STATE_REMOTE_WORKDIR=%s\n' "${PRESSURE_STATE_REMOTE_WORKDIR}"
        printf 'PRESSURE_STATE_REMOTE_RUN_DIR=%s\n' "${PRESSURE_STATE_REMOTE_RUN_DIR}"
        for (( index = 0; index < PRESSURE_PROFILE_ENTRY_COUNT; index++ )); do
            plugin_name="${PRESSURE_PROFILE_PLUGINS[${index}]}"
            pressure_plugin_load "${plugin_name}"
            intensity="${PRESSURE_PROFILE_INTENSITIES[${index}]}"
            cpuset="${PRESSURE_PROFILE_CPUSETS[${index}]}"
            physical="$(pressure_plugin_intensity_physical "${intensity}" || true)"

            printf 'PRESSURE_STATE_ENTRY_%d_PLUGIN=%s\n' "$((index + 1))" "${plugin_name}"
            printf 'PRESSURE_STATE_ENTRY_%d_PLUGIN_DIR=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_SOURCE_PLUGIN_DIRS[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_START_SCRIPT=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_START_SCRIPTS[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_STOP_SCRIPT=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_STOP_SCRIPTS[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_PID_FILE=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_PID_FILES[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_LOG_FILE=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_LOCAL_LOG_FILES[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_REMOTE_LOG_FILE=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_REMOTE_LOG_FILES[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_REMOTE_PLUGIN_DIR=%s\n' "$((index + 1))" "${PRESSURE_STATE_ENTRY_REMOTE_PLUGIN_DIRS[${index}]}"
            printf 'PRESSURE_STATE_ENTRY_%d_INTENSITY=%s\n' "$((index + 1))" "${intensity}"
            printf 'PRESSURE_STATE_ENTRY_%d_CPUSET=%s\n' "$((index + 1))" "${cpuset}"
            printf 'PRESSURE_STATE_ENTRY_%d_PHYSICAL=%s\n' "$((index + 1))" "${physical}"
            printf 'PRESSURE_STATE_ENTRY_%d_PARAMS=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_PARAMS[${index}]}"
        done
    } > "${state_dir}/state.env"

    pressure_profile_write_env "${state_dir}/profile.env"
}

pressure_controller_start_profile() {
    local state_dir='' duration='' target_node='' ssh_user='' remote_workdir=''
    local exec_mode='' ssh_target_ref='' remote_run_dir=''
    local index params_csv pid_file log_file plugin_name cpuset intensity
    local -a start_cmd=()

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --state-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --state-dir"
                state_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --duration)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --duration"
                duration="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --target-node)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --target-node"
                target_node="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --ssh-user)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --ssh-user"
                ssh_user="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --remote-workdir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --remote-workdir"
                remote_workdir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            *)
                break
                ;;
        esac
    done

    [[ -n "${state_dir}" ]] || die "start-profile requires --state-dir"
    [[ -n "${duration}" ]] || die "start-profile requires --duration"
    [[ "${duration}" =~ ^[0-9]+$ ]] || die "pressure duration must be an integer, got: ${duration}"
    target_node="${target_node:-$(pressure_controller_default_target_node)}"
    ssh_user="${ssh_user:-$(pressure_controller_default_ssh_user)}"
    remote_workdir="${remote_workdir:-$(pressure_controller_default_remote_workdir)}"

    PRESSURE_CONTROLLER_ARGS=("${PLATFORM_EXTRA_ARGS[@]}")
    pressure_controller_parse_profile_args

    if pressure_controller_target_is_local "${target_node}"; then
        exec_mode='local'
        ssh_target_ref=''
        remote_run_dir=''
    else
        exec_mode='ssh'
        ssh_target_ref="$(pressure_controller_ssh_target_ref "${target_node}" "${ssh_user}")"
        remote_run_dir="$(pressure_controller_remote_run_dir "${remote_workdir}" "${state_dir}")"
    fi

    pressure_controller_plan_state_layout "${state_dir}" "${target_node}" "${exec_mode}" "${ssh_user}" "${ssh_target_ref}" "${remote_workdir}" "${remote_run_dir}"
    pressure_controller_stage_remote_entries
    pressure_controller_write_state "${state_dir}" "${duration}"

    for (( index = 0; index < PRESSURE_PROFILE_ENTRY_COUNT; index++ )); do
        plugin_name="${PRESSURE_PROFILE_PLUGINS[${index}]}"
        intensity="${PRESSURE_PROFILE_INTENSITIES[${index}]}"
        cpuset="${PRESSURE_PROFILE_CPUSETS[${index}]}"
        params_csv="${PRESSURE_PROFILE_PARAMS[${index}]}"

        pressure_plugin_load "${plugin_name}"
        pressure_plugin_supports_intensity "${intensity}" || die "plugin ${plugin_name} does not support intensity ${intensity}"

        pid_file="${PRESSURE_STATE_ENTRY_PID_FILES[${index}]}"
        log_file="${PRESSURE_STATE_ENTRY_LOCAL_LOG_FILES[${index}]}"
        start_cmd=(
            "${PRESSURE_STATE_ENTRY_START_SCRIPTS[${index}]}"
            --instance-id "entry-$(printf '%02d' "$((index + 1))")"
            --intensity "${intensity}"
            --cpuset "${cpuset}"
            --duration "${duration}"
            --pid-file "${pid_file}"
            --log-file "${PRESSURE_STATE_ENTRY_REMOTE_LOG_FILES[${index}]:-${log_file}}"
        )
        if [[ -n "${params_csv}" ]]; then
            IFS=',' read -r -a pressure_param_tokens <<< "${params_csv}"
            for token in "${pressure_param_tokens[@]}"; do
                [[ -n "${token}" ]] || continue
                start_cmd+=(--param "${token}")
            done
        fi

        log_info "starting pressure entry $(printf '%02d' "$((index + 1))"): plugin=${plugin_name} intensity=${intensity} target_node=${target_node} cpuset=${cpuset}"
        if [[ "${exec_mode}" == "ssh" ]]; then
            pressure_controller_remote_invoke "${ssh_target_ref}" "${start_cmd[@]}"
        else
            "${start_cmd[@]}"
        fi
    done
}

pressure_controller_stop_profile() {
    local state_dir='' entry_count=0 index stop_script pid_file
    local exec_mode='' ssh_target_ref='' remote_log_file='' local_log_file=''

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --state-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --state-dir"
                state_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            -h|--help)
                pressure_controller_usage
                exit 0
                ;;
            *)
                die "unknown stop-profile argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    [[ -n "${state_dir}" ]] || die "stop-profile requires --state-dir"
    [[ -f "${state_dir}/state.env" ]] || return 0

    # shellcheck source=/dev/null
    source "${state_dir}/state.env"
    entry_count="${PRESSURE_STATE_ENTRY_COUNT:-0}"
    exec_mode="${PRESSURE_STATE_EXEC_MODE:-local}"
    ssh_target_ref="${PRESSURE_STATE_SSH_TARGET_REF:-}"
    [[ "${entry_count}" =~ ^[0-9]+$ ]] || die "invalid pressure state entry count in ${state_dir}/state.env"

    for (( index = entry_count; index >= 1; index-- )); do
        stop_script="$(eval "printf '%s' \"\${PRESSURE_STATE_ENTRY_${index}_STOP_SCRIPT:-}\"")"
        pid_file="$(eval "printf '%s' \"\${PRESSURE_STATE_ENTRY_${index}_PID_FILE:-}\"")"
        local_log_file="$(eval "printf '%s' \"\${PRESSURE_STATE_ENTRY_${index}_LOG_FILE:-}\"")"
        remote_log_file="$(eval "printf '%s' \"\${PRESSURE_STATE_ENTRY_${index}_REMOTE_LOG_FILE:-}\"")"
        [[ -n "${stop_script}" ]] || continue
        if [[ "${exec_mode}" == "ssh" ]]; then
            [[ -n "${ssh_target_ref}" ]] || die "pressure state missing SSH target ref for remote stop-profile"
            pressure_controller_remote_invoke "${ssh_target_ref}" "${stop_script}" --pid-file "${pid_file}" || true
            if [[ -n "${remote_log_file}" && -n "${local_log_file}" ]]; then
                pressure_controller_remote_fetch_file "${ssh_target_ref}" "${remote_log_file}" "${local_log_file}" || true
            fi
        else
            if [[ -f "${pid_file}" ]]; then
                "${stop_script}" --pid-file "${pid_file}" || true
            fi
        fi
    done
}

main() {
    local subcommand=''

    if [[ $# -eq 0 ]]; then
        pressure_controller_usage
        exit 1
    fi

    platform_init "$@"
    [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]] || die "pressure controller requires a subcommand"
    subcommand="${PLATFORM_EXTRA_ARGS[0]}"
    PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")

    case "${subcommand}" in
        start-profile)
            pressure_controller_start_profile
            ;;
        stop-profile)
            pressure_controller_stop_profile
            ;;
        -h|--help|help)
            pressure_controller_usage
            ;;
        *)
            die "unknown pressure controller subcommand: ${subcommand}"
            ;;
    esac
}

main "$@"
