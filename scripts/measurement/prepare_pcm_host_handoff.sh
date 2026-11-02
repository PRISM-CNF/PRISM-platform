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

usage() {
    cat <<'EOF'
Usage: prepare_pcm_host_handoff.sh [platform-options] (--artifact-dir <dir> | --cpuset-env <path>) [--output-dir <dir>] [--role <name>] [--ssh-target <host>] [--ssh-user <user>] [--remote-workdir <dir>] [--print]

Prepares the next-step host-transition handoff for SSH-based PCM sampling on node01.
It does not deploy a host-level sampler yet; it extracts a role cpuset from an existing
cpuset-map.env and emits the concrete handoff inputs and suggested SSH/SCP commands.
EOF
}

main() {
    local artifact_dir="" cpuset_env_file="" output_dir=""
    local role_name="vnf" ssh_target="node01" ssh_user="root"
    local remote_workdir="/var/tmp/nsm-ovs-pcm-host"
    local host_pcm_prefix="${PCM_HOST_PCM_PREFIX:-/opt/intel-pcm}"
    local print_output=false
    local role_key role_cpuset role_namespace role_pod role_container run_id_label
    local handoff_env_file handoff_txt_file remote_input_dir remote_run_dir remote_input_file
    local ssh_target_ref
    local scp_cmd ssh_prepare_cmd ssh_run_placeholder_cmd
    local -A cpuset_map=()

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --artifact-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --artifact-dir"
                artifact_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --cpuset-env)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --cpuset-env"
                cpuset_env_file="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --output-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --output-dir"
                output_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --role)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --role"
                role_name="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --ssh-target)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --ssh-target"
                ssh_target="${PLATFORM_EXTRA_ARGS[1]}"
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
            --print)
                print_output=true
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown prepare_pcm_host_handoff argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_require_no_extra_args

    if [[ -n "${artifact_dir}" ]]; then
        [[ -d "${artifact_dir}" ]] || die "artifact dir not found: ${artifact_dir}"
        [[ -n "${cpuset_env_file}" ]] || cpuset_env_file="${artifact_dir}/cpu-pin/cpuset-map.env"
        [[ -n "${output_dir}" ]] || output_dir="${artifact_dir}/pcm-host-transition"
    fi

    [[ -n "${cpuset_env_file}" ]] || die "prepare_pcm_host_handoff requires --artifact-dir or --cpuset-env"
    [[ -f "${cpuset_env_file}" ]] || die "cpuset env file not found: ${cpuset_env_file}"
    [[ -n "${output_dir}" ]] || die "output dir is empty"

    platform_load_env_file "${cpuset_env_file}" cpuset_map
    role_key="$(cpuset_role_key "${role_name}")"
    role_cpuset="${cpuset_map[CPUSET_${role_key}_CPUSET]:-}"
    role_namespace="${cpuset_map[CPUSET_${role_key}_NAMESPACE]:-}"
    role_pod="${cpuset_map[CPUSET_${role_key}_POD]:-}"
    role_container="${cpuset_map[CPUSET_${role_key}_CONTAINER]:-}"
    [[ -n "${role_cpuset}" ]] || die "cpuset for role ${role_name} not found in ${cpuset_env_file}"

    mkdir -p "${output_dir}"
    handoff_env_file="${output_dir}/host-pcm-handoff.env"
    handoff_txt_file="${output_dir}/host-pcm-handoff.txt"
    run_id_label="$(basename "${artifact_dir:-$(dirname "$(dirname "${cpuset_env_file}")")}")"
    if [[ "${ssh_target}" == *@* || -z "${ssh_user}" ]]; then
        ssh_target_ref="${ssh_target}"
    else
        ssh_target_ref="${ssh_user}@${ssh_target}"
    fi
    remote_input_dir="${remote_workdir}/input"
    remote_run_dir="${remote_workdir}/runs/${run_id_label}"
    remote_input_file="${remote_input_dir}/${run_id_label}-${role_name}.env"
    scp_cmd="scp ${handoff_env_file} ${ssh_target_ref}:${remote_input_file}"
    ssh_prepare_cmd="ssh ${ssh_target_ref} 'mkdir -p ${remote_input_dir} ${remote_run_dir} && sudo -n true'"
    ssh_run_placeholder_cmd="ssh ${ssh_target_ref} 'cd ${remote_workdir} && sudo -n ./pcm-host-sampler.sh --cpuset ${role_cpuset} --output-dir ${remote_run_dir}'"

    cat > "${handoff_env_file}" <<EOF
PCM_DEPLOYMENT_MODE=${PCM_DEPLOYMENT_MODE:-host-transition}
PCM_HANDOFF_SOURCE_ARTIFACT_DIR=${artifact_dir:-}
PCM_HANDOFF_SOURCE_CPUSET_ENV=${cpuset_env_file}
PCM_HANDOFF_RUN_LABEL=${run_id_label}
PCM_HANDOFF_ROLE=${role_name}
PCM_HANDOFF_ROLE_KEY=${role_key}
PCM_HANDOFF_ROLE_CPUSET=${role_cpuset}
PCM_HANDOFF_ROLE_NAMESPACE=${role_namespace}
PCM_HANDOFF_ROLE_POD=${role_pod}
PCM_HANDOFF_ROLE_CONTAINER=${role_container}
PCM_HOST_SSH_TARGET=${ssh_target}
PCM_HOST_SSH_USER=${ssh_user}
PCM_HOST_SSH_TARGET_REF=${ssh_target_ref}
PCM_HOST_REMOTE_WORKDIR=${remote_workdir}
PCM_HOST_PCM_PREFIX=${host_pcm_prefix}
PCM_HOST_REMOTE_INPUT_DIR=${remote_input_dir}
PCM_HOST_REMOTE_RUN_DIR=${remote_run_dir}
PCM_HOST_REMOTE_INPUT_FILE=${remote_input_file}
PCM_HOST_PREPARE_CMD=${ssh_prepare_cmd}
PCM_HOST_COPY_CMD=${scp_cmd}
PCM_HOST_RUN_PLACEHOLDER_CMD=${ssh_run_placeholder_cmd}
EOF

    cat > "${handoff_txt_file}" <<EOF
PCM Host Transition Handoff
Mode                    : ${PCM_DEPLOYMENT_MODE:-host-transition}
Source cpuset env       : ${cpuset_env_file}
Artifact dir            : ${artifact_dir:-<not-provided>}
Role                    : ${role_name}
Role cpuset             : ${role_cpuset}
Role namespace/pod      : ${role_namespace}/${role_pod}
Role container          : ${role_container}
SSH target              : ${ssh_target}
SSH user                : ${ssh_user}
Remote workdir          : ${remote_workdir}
Host PCM prefix         : ${host_pcm_prefix}
Remote input file       : ${remote_input_file}
Remote run dir          : ${remote_run_dir}

Suggested next step
1. Prepare host directories and confirm sudo:
   ${ssh_prepare_cmd}
2. Copy the handoff env to node01:
   ${scp_cmd}
3. Replace the placeholder sampler with the Step-2 host-level PCM sampler and run:
   ${ssh_run_placeholder_cmd}

Notes
- This script does not deploy the host-level sampler yet.
- It defines the handoff contract from cpuset-map.env to the future SSH-based node01 sampler.
- Default role is vnf; select the role matching your workload.
EOF

    log_info "prepared PCM host handoff env: ${handoff_env_file}"
    log_info "prepared PCM host handoff note: ${handoff_txt_file}"

    if [[ "${print_output}" == "true" ]]; then
        cat "${handoff_txt_file}"
    fi
}

main "$@"
