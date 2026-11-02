#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/k8s.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/pcm_cpuset.sh"

usage() {
    cat <<'EOF'
Usage: run_pcm_host_sample_via_ssh.sh [platform-options] (--artifact-dir <dir> | --cpuset-env <path>) [--output-dir <dir>] [--role <name>] [--ssh-target <host>] [--ssh-user <user>] [--remote-workdir <dir>] [--host-pcm-prefix <dir>] [--allow-pod-staging-fallback] [--duration-sec <n>] [--sample-mode <label>] [--print-summary]

Drive a host-level PCM sample on node01 via SSH and bring the result back into the local artifact tree.
EOF
}

parse_ldd_paths() {
    local input_file=$1

    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
        }
        /=> \// {
            split(line, parts, /[[:space:]]+/)
            for (i = 1; i <= length(parts); i++) {
                if (parts[i] ~ /^\//) {
                    print parts[i]
                    break
                }
            }
            next
        }
        line ~ /^\// {
            split(line, parts, /[[:space:]]+/)
            print parts[1]
        }
    ' "${input_file}" | sort -u
}

write_command_file() {
    local output_file=$1
    shift

    {
        printf 'cwd=%s\n' "$(pwd)"
        printf 'command='
        printf '%q ' "$@"
        printf '\n'
    } > "${output_file}"
}

main() {
    local artifact_dir="" cpuset_env="" output_dir="" role_name="vnf"
    local ssh_target="node01" ssh_user="root" remote_workdir="/var/tmp/nsm-ovs-pcm-host"
    local host_pcm_prefix="${PCM_HOST_PCM_PREFIX:-/opt/intel-pcm}" allow_pod_staging_fallback=false
    local duration_sec="1" sample_mode="pcm-core" print_summary=false
    local handoff_dir handoff_env_file handoff_txt_file
    local ssh_target_ref remote_input_dir remote_run_dir remote_input_file run_label role_cpuset
    local remote_sampler_path remote_bin_dir remote_pcm_bin
    local host_audit_file stage_info_file orchestration_env_file orchestration_txt_file local_command_file remote_stdout_file
    local local_staging_dir local_pcm_bin=""
    local local_lib_dir="" remote_lib_dir="" runtime_loader_local="" runtime_loader_remote="" runtime_library_path_remote=""
    local host_existing_bin="" pod_name="" pod_bin_path="" pod_bin_source=""
    local remote_status="fail" remote_reason="" remote_summary_env_local="" remote_summary_txt_local=""
    local remote_summary_status="" remote_summary_reason=""
    local pod_ldd_file="" lib_path lib_base
    local -A handoff_map=() remote_summary_map=()
    local -a original_args=("$@")

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
                cpuset_env="${PLATFORM_EXTRA_ARGS[1]}"
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
            --host-pcm-prefix)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --host-pcm-prefix"
                host_pcm_prefix="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --allow-pod-staging-fallback)
                allow_pod_staging_fallback=true
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            --duration-sec)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --duration-sec"
                duration_sec="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --sample-mode)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --sample-mode"
                sample_mode="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --print-summary)
                print_summary=true
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown run_pcm_host_sample_via_ssh argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_require_no_extra_args
    [[ "${duration_sec}" =~ ^[0-9]+$ ]] || die "invalid --duration-sec: ${duration_sec}"

    if [[ -n "${artifact_dir}" ]]; then
        [[ -d "${artifact_dir}" ]] || die "artifact dir not found: ${artifact_dir}"
        [[ -n "${cpuset_env}" ]] || cpuset_env="${artifact_dir}/cpu-pin/cpuset-map.env"
        [[ -n "${output_dir}" ]] || output_dir="${artifact_dir}/pcm-host-transition/host-sample-${role_name}"
    fi

    [[ -n "${cpuset_env}" ]] || die "run_pcm_host_sample_via_ssh requires --artifact-dir or --cpuset-env"
    [[ -f "${cpuset_env}" ]] || die "cpuset env file not found: ${cpuset_env}"
    [[ -n "${output_dir}" ]] || die "output dir is empty"

    mkdir -p "${output_dir}"
    handoff_dir="${output_dir}/handoff"
    local_staging_dir="${output_dir}/staging"
    host_audit_file="${output_dir}/host-audit.txt"
    stage_info_file="${output_dir}/stage-info.txt"
    orchestration_env_file="${output_dir}/orchestration.env"
    orchestration_txt_file="${output_dir}/orchestration.txt"
    local_command_file="${output_dir}/command.txt"
    remote_stdout_file="${output_dir}/remote-exec.log"
    write_command_file "${local_command_file}" "$0" "${original_args[@]}"

    if [[ -n "${artifact_dir}" ]]; then
        "${PLATFORM_REPO_ROOT}/scripts/measurement/prepare_pcm_host_handoff.sh" \
            --artifact-dir "${artifact_dir}" \
            --role "${role_name}" \
            --ssh-target "${ssh_target}" \
            --ssh-user "${ssh_user}" \
            --remote-workdir "${remote_workdir}" \
            --output-dir "${handoff_dir}"
    else
        "${PLATFORM_REPO_ROOT}/scripts/measurement/prepare_pcm_host_handoff.sh" \
            --cpuset-env "${cpuset_env}" \
            --role "${role_name}" \
            --ssh-target "${ssh_target}" \
            --ssh-user "${ssh_user}" \
            --remote-workdir "${remote_workdir}" \
            --output-dir "${handoff_dir}"
    fi

    handoff_env_file="${handoff_dir}/host-pcm-handoff.env"
    handoff_txt_file="${handoff_dir}/host-pcm-handoff.txt"
    platform_load_env_file "${handoff_env_file}" handoff_map

    role_cpuset="${handoff_map[PCM_HANDOFF_ROLE_CPUSET]:-}"
    run_label="${handoff_map[PCM_HANDOFF_RUN_LABEL]:-$(basename "${output_dir}")}"
    remote_input_dir="${handoff_map[PCM_HOST_REMOTE_INPUT_DIR]:-}"
    remote_run_dir="${handoff_map[PCM_HOST_REMOTE_RUN_DIR]:-}"
    remote_input_file="${handoff_map[PCM_HOST_REMOTE_INPUT_FILE]:-}"
    ssh_target_ref="${handoff_map[PCM_HOST_SSH_TARGET_REF]:-}"
    [[ -n "${ssh_target_ref}" ]] || {
        if [[ "${ssh_target}" == *@* || -z "${ssh_user}" ]]; then
            ssh_target_ref="${ssh_target}"
        else
            ssh_target_ref="${ssh_user}@${ssh_target}"
        fi
    }
    remote_sampler_path="${remote_workdir}/pcm-host-sampler.sh"
    remote_bin_dir="${remote_workdir}/bin"
    remote_pcm_bin="${remote_bin_dir}/pcm-core"
    remote_lib_dir="${remote_workdir}/lib"

    {
        printf 'ssh_target=%s\n' "${ssh_target}"
        printf 'ssh_target_ref=%s\n' "${ssh_target_ref}"
        printf 'remote_workdir=%s\n' "${remote_workdir}"
        printf 'remote_input_dir=%s\n' "${remote_input_dir}"
        printf 'remote_run_dir=%s\n' "${remote_run_dir}"
        printf 'role=%s\n' "${role_name}"
        printf 'cpuset=%s\n' "${role_cpuset}"
        printf 'sample_mode=%s\n' "${sample_mode}"
        printf 'duration_sec=%s\n' "${duration_sec}"
        printf 'host_pcm_prefix=%s\n' "${host_pcm_prefix}"
        printf 'allow_pod_staging_fallback=%s\n' "${allow_pod_staging_fallback}"
        printf '\n[host-audit-pre]\n'
    } > "${host_audit_file}"

    ssh "${ssh_target_ref}" "command -v pcm-core || true; command -v taskset || true; command -v timeout || true; command -v lscpu || true; ls -ld ${host_pcm_prefix} ${host_pcm_prefix}/bin ${remote_workdir} ${remote_bin_dir} ${remote_input_dir} ${remote_run_dir} 2>/dev/null || true" >> "${host_audit_file}" 2>&1

    host_existing_bin="$(ssh "${ssh_target_ref}" "if [ -x '${host_pcm_prefix}/bin/pcm-core' ]; then printf '%s' '${host_pcm_prefix}/bin/pcm-core'; else command -v pcm-core 2>/dev/null || true; fi")"
    if [[ -n "${host_existing_bin}" ]]; then
        remote_pcm_bin="${host_existing_bin}"
        if [[ "${host_existing_bin}" == "${host_pcm_prefix}/bin/pcm-core" ]]; then
            pod_bin_source="host-installed:${host_existing_bin}"
        else
            pod_bin_source="host-existing:${host_existing_bin}"
        fi
        {
            printf 'binary_source=%s\n' "${pod_bin_source}"
            printf 'binary_path=%s\n' "${remote_pcm_bin}"
            printf 'host_pcm_prefix=%s\n' "${host_pcm_prefix}"
        } > "${stage_info_file}"
    else
        [[ "${allow_pod_staging_fallback}" == "true" ]] || die "no host-installed pcm-core found at ${host_pcm_prefix}/bin/pcm-core and pod staging fallback is disabled"
        k8s_require_cluster
        pod_name="$(pcm_cpuset_discover_pod_on_node "intel-pcm" "node01")"
        [[ -n "${pod_name}" ]] || die "failed to discover intel-pcm pod on node01 for staging"
        pod_bin_path="$(kubectl exec -n intel-pcm "${pod_name}" -- sh -c 'command -v pcm-core || true' | tr -d '\r' | sed -n '1p')"
        [[ -n "${pod_bin_path}" ]] || die "failed to discover pcm-core path inside intel-pcm/${pod_name}"
        pod_bin_source="legacy-staged-from-incluster:intel-pcm/${pod_name}:${pod_bin_path}"

        mkdir -p "${local_staging_dir}"
        local_lib_dir="${local_staging_dir}/lib"
        mkdir -p "${local_lib_dir}"
        local_pcm_bin="${local_staging_dir}/pcm-core"
        pod_ldd_file="${local_staging_dir}/pcm-core.ldd.txt"
        kubectl exec -n intel-pcm "${pod_name}" -- sh -c "cat ${pod_bin_path}" > "${local_pcm_bin}"
        chmod 0755 "${local_pcm_bin}"
        kubectl exec -n intel-pcm "${pod_name}" -- sh -c "ldd ${pod_bin_path}" > "${pod_ldd_file}"
        while IFS= read -r lib_path; do
            [[ -n "${lib_path}" ]] || continue
            lib_base="$(basename "${lib_path}")"
            kubectl exec -n intel-pcm "${pod_name}" -- sh -c "cat ${lib_path}" > "${local_lib_dir}/${lib_base}"
            chmod 0644 "${local_lib_dir}/${lib_base}"
            if [[ "${lib_base}" == "ld-linux-x86-64.so.2" ]]; then
                chmod 0755 "${local_lib_dir}/${lib_base}"
                runtime_loader_local="${local_lib_dir}/${lib_base}"
            fi
        done < <(parse_ldd_paths "${pod_ldd_file}")
        [[ -n "${runtime_loader_local}" ]] || die "failed to stage runtime loader for ${pod_bin_path}"

        {
            printf 'binary_source=%s\n' "${pod_bin_source}"
            printf 'binary_path=%s\n' "${remote_pcm_bin}"
            printf 'pod_name=%s\n' "${pod_name}"
            printf 'pod_bin_path=%s\n' "${pod_bin_path}"
            printf 'pod_ldd_file=%s\n' "${pod_ldd_file}"
            printf 'runtime_loader_local=%s\n' "${runtime_loader_local}"
            if command -v file >/dev/null 2>&1; then
                file "${local_pcm_bin}"
            fi
            sha256sum "${local_pcm_bin}"
            printf '\n[staged-libs]\n'
            find "${local_lib_dir}" -maxdepth 1 -type f | sort | while read -r staged_lib; do
                ls -l "${staged_lib}"
                sha256sum "${staged_lib}"
            done
        } > "${stage_info_file}"

        ssh "${ssh_target_ref}" "mkdir -p ${remote_bin_dir} ${remote_lib_dir} ${remote_input_dir} ${remote_run_dir} && sudo -n true" >> "${host_audit_file}" 2>&1
        scp "${local_pcm_bin}" "${ssh_target_ref}:${remote_pcm_bin}" >/dev/null
        scp "${local_lib_dir}/"* "${ssh_target_ref}:${remote_lib_dir}/" >/dev/null
        runtime_loader_remote="${remote_lib_dir}/$(basename "${runtime_loader_local}")"
        runtime_library_path_remote="${remote_lib_dir}"
        ssh "${ssh_target_ref}" "chmod 0755 ${remote_pcm_bin}; ls -l ${remote_pcm_bin}; if command -v file >/dev/null 2>&1; then file ${remote_pcm_bin}; fi; if command -v ldd >/dev/null 2>&1; then ldd ${remote_pcm_bin} || true; fi" >> "${host_audit_file}" 2>&1
    fi

    scp "${handoff_env_file}" "${ssh_target_ref}:${remote_input_file}" >/dev/null
    scp "${PLATFORM_REPO_ROOT}/scripts/measurement/pcm-host-sampler.sh" "${ssh_target_ref}:${remote_sampler_path}" >/dev/null
    ssh "${ssh_target_ref}" "chmod 0755 ${remote_sampler_path}; mkdir -p ${remote_run_dir}" >> "${host_audit_file}" 2>&1

    set +e
    ssh "${ssh_target_ref}" "sudo -n env PCM_HOST_PCM_PREFIX='${host_pcm_prefix}' PCM_HOST_ALLOW_STAGED_DEFAULT=$(if [[ \"${allow_pod_staging_fallback}\" == \"true\" ]]; then printf '1'; else printf '0'; fi) ${remote_sampler_path} --handoff-env ${remote_input_file} --output-dir ${remote_run_dir} --pcm-bin ${remote_pcm_bin} --pcm-bin-source ${pod_bin_source} ${runtime_loader_remote:+--runtime-loader ${runtime_loader_remote}} ${runtime_library_path_remote:+--library-path ${runtime_library_path_remote}} --duration-sec ${duration_sec} --sample-mode ${sample_mode}" > "${remote_stdout_file}" 2>&1
    remote_status=$?
    set -e

    if ! scp -r "${ssh_target_ref}:${remote_run_dir}/." "${output_dir}/" >/dev/null; then
        log_warn "failed to fetch remote output dir from ${ssh_target_ref}:${remote_run_dir}"
    fi

    remote_summary_env_local="${output_dir}/summary.env"
    remote_summary_txt_local="${output_dir}/summary.txt"
    if [[ -f "${remote_summary_env_local}" ]]; then
        platform_load_env_file "${remote_summary_env_local}" remote_summary_map
        remote_summary_status="${remote_summary_map[PCM_HOST_SAMPLE_STATUS]:-unknown}"
        remote_summary_reason="${remote_summary_map[PCM_HOST_SAMPLE_REASON]:-}"
    else
        remote_summary_status='missing-summary'
        remote_summary_reason='remote-summary-env-not-fetched'
    fi

    {
        printf 'PCM_HOST_ORCH_STATUS=%s\n' "$(if [[ "${remote_status}" -eq 0 && "${remote_summary_status}" == "pass" ]]; then printf 'pass'; else printf 'fail'; fi)"
        printf 'PCM_HOST_ORCH_REASON=%s\n' "${remote_summary_reason:-ssh-rc:${remote_status}}"
        printf 'PCM_HOST_ORCH_SSH_TARGET=%s\n' "${ssh_target}"
        printf 'PCM_HOST_ORCH_SSH_TARGET_REF=%s\n' "${ssh_target_ref}"
        printf 'PCM_HOST_ORCH_REMOTE_WORKDIR=%s\n' "${remote_workdir}"
        printf 'PCM_HOST_ORCH_REMOTE_RUN_DIR=%s\n' "${remote_run_dir}"
        printf 'PCM_HOST_ORCH_REMOTE_INPUT_FILE=%s\n' "${remote_input_file}"
        printf 'PCM_HOST_ORCH_ROLE=%s\n' "${role_name}"
        printf 'PCM_HOST_ORCH_CPUSET=%s\n' "${role_cpuset}"
        printf 'PCM_HOST_ORCH_PCM_BIN=%s\n' "${remote_pcm_bin}"
        printf 'PCM_HOST_ORCH_PCM_BIN_SOURCE=%s\n' "${pod_bin_source}"
        printf 'PCM_HOST_ORCH_PCM_PREFIX=%s\n' "${host_pcm_prefix}"
        printf 'PCM_HOST_ORCH_ALLOW_POD_STAGING_FALLBACK=%s\n' "${allow_pod_staging_fallback}"
        printf 'PCM_HOST_ORCH_RUNTIME_LOADER=%s\n' "${runtime_loader_remote}"
        printf 'PCM_HOST_ORCH_RUNTIME_LIBRARY_PATH=%s\n' "${runtime_library_path_remote}"
        printf 'PCM_HOST_ORCH_HANDOFF_ENV_LOCAL=%s\n' "${handoff_env_file}"
        printf 'PCM_HOST_ORCH_HANDOFF_ENV_REMOTE=%s\n' "${remote_input_file}"
        printf 'PCM_HOST_ORCH_HANDOFF_TXT_LOCAL=%s\n' "${handoff_txt_file}"
        printf 'PCM_HOST_ORCH_REMOTE_SAMPLER=%s\n' "${remote_sampler_path}"
        printf 'PCM_HOST_ORCH_STAGE_INFO=%s\n' "${stage_info_file}"
        printf 'PCM_HOST_ORCH_HOST_AUDIT=%s\n' "${host_audit_file}"
        printf 'PCM_HOST_ORCH_REMOTE_EXEC_LOG=%s\n' "${remote_stdout_file}"
        printf 'PCM_HOST_ORCH_REMOTE_SUMMARY_ENV=%s\n' "${remote_summary_env_local}"
        printf 'PCM_HOST_ORCH_REMOTE_SUMMARY_TXT=%s\n' "${remote_summary_txt_local}"
        printf 'PCM_HOST_ORCH_SSH_RC=%s\n' "${remote_status}"
    } > "${orchestration_env_file}"

    cat > "${orchestration_txt_file}" <<EOF
PCM Host Sample Orchestration
Status              : $(if [[ "${remote_status}" -eq 0 && "${remote_summary_status}" == "pass" ]]; then printf 'pass'; else printf 'fail'; fi)
Reason              : ${remote_summary_reason:-ssh-rc:${remote_status}}
Role                : ${role_name}
CPUSet              : ${role_cpuset}
SSH target          : ${ssh_target_ref}
Remote workdir      : ${remote_workdir}
Remote run dir      : ${remote_run_dir}
PCM binary          : ${remote_pcm_bin}
PCM binary source   : ${pod_bin_source}
PCM prefix          : ${host_pcm_prefix}
Legacy fallback     : ${allow_pod_staging_fallback}
Runtime loader      : ${runtime_loader_remote:-<none>}
Runtime lib path    : ${runtime_library_path_remote:-<none>}
Handoff env         : ${handoff_env_file}
Remote handoff env  : ${remote_input_file}
Stage info          : ${stage_info_file}
Host audit          : ${host_audit_file}
Remote exec log     : ${remote_stdout_file}
Remote summary env  : ${remote_summary_env_local}
Remote summary txt  : ${remote_summary_txt_local}
EOF

    if [[ "${print_summary}" == "true" && -f "${remote_summary_txt_local}" ]]; then
        cat "${remote_summary_txt_local}"
    fi

    [[ "${remote_status}" -eq 0 && "${remote_summary_status}" == "pass" ]] || exit 1
}

main "$@"
