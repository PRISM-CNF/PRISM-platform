#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: pcm-host-sampler.sh [--handoff-env <path>] [--cpuset <spec>] [--role <name>] [--output-dir <dir>] [--pcm-bin <path>] [--pcm-bin-source <label>] [--duration-sec <n>] [--sample-mode <label>]

Run a one-shot host-level PCM sample on node01 and write structured artifacts.
EOF
}

trim() {
    local value=${1-}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

load_env_file() {
    local file_path=$1
    local map_name=$2
    local raw_line line key value
    local -n map_ref="${map_name}"

    map_ref=()
    [[ -f "${file_path}" ]] || return 0

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="$(trim "${raw_line}")"
        [[ -z "${line}" ]] && continue
        [[ ${line:0:1} == "#" ]] && continue
        [[ "${line}" == *=* ]] || continue

        key="$(trim "${line%%=*}")"
        value="${line#*=}"
        map_ref["${key}"]="${value}"
    done < "${file_path}"
}

expand_cpuset() {
    local raw=${1:-}
    local part start end cpu
    local -a parts=()

    raw="${raw//[[:space:]]/}"
    [[ -n "${raw}" ]] || return 1

    IFS=',' read -r -a parts <<< "${raw}"
    for part in "${parts[@]}"; do
        [[ -n "${part}" ]] || continue
        if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            (( start <= end )) || return 1
            for (( cpu = start; cpu <= end; cpu++ )); do
                printf '%s\n' "${cpu}"
            done
        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "${part}"
        else
            return 1
        fi
    done
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

extract_csv_from_raw() {
    local raw_file=$1
    local csv_file=$2

    awk 'BEGIN { capture = 0 } /^Core,/ { capture = 1 } capture { print }' "${raw_file}" > "${csv_file}"
    [[ -s "${csv_file}" ]]
}

filter_core_rows() {
    local csv_file=$1
    local core_rows_csv=$2
    local output_file=$3

    awk -F',' -v wanted="${core_rows_csv}" '
        BEGIN {
            split(wanted, rows, ",")
            for (idx in rows) {
                if (rows[idx] != "") {
                    keep[rows[idx]] = 1
                }
            }
        }
        NR == 1 {
            print
            next
        }
        ($1 in keep) {
            print
        }
    ' "${csv_file}" > "${output_file}"

    [[ "$(wc -l < "${output_file}")" -gt 1 ]]
}

build_topology_map() {
    local cpuset_spec=$1
    local topology_file=$2
    local cpu cpu_dir socket core_id siblings global_core_row
    local pairs
    local -a cpus=()

    mapfile -t cpus < <(expand_cpuset "${cpuset_spec}")
    pairs="$(
        for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
            [[ -d "${cpu_dir}" ]] || continue
            socket="$(cat "${cpu_dir}/topology/physical_package_id")"
            core_id="$(cat "${cpu_dir}/topology/core_id")"
            printf '%s:%s\n' "${socket}" "${core_id}"
        done | sort -u -t: -k1,1n -k2,2n
    )"

    : > "${topology_file}"
    for cpu in "${cpus[@]}"; do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu}"
        [[ -d "${cpu_dir}" ]] || {
            printf 'CPU_MAP_ERROR cpu=%s reason=missing-cpu-dir\n' "${cpu}" >> "${topology_file}"
            return 1
        }
        socket="$(cat "${cpu_dir}/topology/physical_package_id")"
        core_id="$(cat "${cpu_dir}/topology/core_id")"
        siblings="$(cat "${cpu_dir}/topology/thread_siblings_list")"
        global_core_row="$(
            printf '%s\n' "${pairs}" | awk -F: -v want="${socket}:${core_id}" '
                BEGIN { idx = 0 }
                $0 == want { print idx; found = 1; exit }
                { idx++ }
                END { if (!found) exit 1 }
            '
        )"
        printf 'CPU_MAP cpu=%s socket=%s core_id=%s siblings=%s global_core_row=%s\n' \
            "${cpu}" "${socket}" "${core_id}" "${siblings}" "${global_core_row}" >> "${topology_file}"
    done
}

parse_topology_file() {
    local topology_file=$1
    local rows_var=$2
    local summary_var=$3
    local rows_list summary_text

    rows_list="$(
        awk '
            /^CPU_MAP / {
                row = ""
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^global_core_row=/) {
                        split($i, kv, "=")
                        row = kv[2]
                    }
                }
                if (row != "" && !seen[row]++) {
                    print row
                }
            }
        ' "${topology_file}" | sort -n | paste -sd, -
    )"

    summary_text="$(
        awk '
            BEGIN { first = 1 }
            /^CPU_MAP / {
                cpu = socket = core = siblings = row = ""
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^cpu=/) {
                        split($i, kv, "=")
                        cpu = kv[2]
                    } else if ($i ~ /^socket=/) {
                        split($i, kv, "=")
                        socket = kv[2]
                    } else if ($i ~ /^core_id=/) {
                        split($i, kv, "=")
                        core = kv[2]
                    } else if ($i ~ /^siblings=/) {
                        split($i, kv, "=")
                        siblings = kv[2]
                    } else if ($i ~ /^global_core_row=/) {
                        split($i, kv, "=")
                        row = kv[2]
                    }
                }
                item = "cpu" cpu "->socket" socket "/core" core "[siblings=" siblings "]=>row" row
                if (first) {
                    printf "%s", item
                    first = 0
                } else {
                    printf "; %s", item
                }
            }
        ' "${topology_file}"
    )"

    printf -v "${rows_var}" '%s' "${rows_list}"
    printf -v "${summary_var}" '%s' "${summary_text}"
}

main() {
    local handoff_env="" cpuset_spec="" role_name="" output_dir="" pcm_bin=""
    local pcm_bin_source="auto" duration_sec="1" sample_mode="pcm-core"
    local runtime_loader="" runtime_library_path=""
    local host_pcm_prefix="${PCM_HOST_PCM_PREFIX:-/opt/intel-pcm}"
    local allow_staged_default="${PCM_HOST_ALLOW_STAGED_DEFAULT:-0}"
    local command_file topology_file raw_file csv_file target_csv_file summary_env_file summary_txt_file audit_file
    local host_name current_user allowed_before="" allowed_after="" timeout_sec
    local target_rows="" target_summary="" target_row_count=0 sample_rc=0 sample_status="fail" sample_reason=""
    local cpu_list_csv="" run_label="" role_namespace="" role_pod="" role_container=""
    local remote_workdir="" ssh_target="" ssh_target_ref="" source_artifact_dir="" source_cpuset_env=""
    local -A handoff_map=()
    local -a cpus=()
    local -a original_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --handoff-env)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                handoff_env="$2"
                shift 2
                ;;
            --cpuset)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                cpuset_spec="$2"
                shift 2
                ;;
            --role)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                role_name="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                output_dir="$2"
                shift 2
                ;;
            --pcm-bin)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                pcm_bin="$2"
                shift 2
                ;;
            --pcm-bin-source)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                pcm_bin_source="$2"
                shift 2
                ;;
            --runtime-loader)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                runtime_loader="$2"
                shift 2
                ;;
            --library-path)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                runtime_library_path="$2"
                shift 2
                ;;
            --duration-sec)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                duration_sec="$2"
                shift 2
                ;;
            --sample-mode)
                [[ $# -ge 2 ]] || { usage; exit 1; }
                sample_mode="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    [[ "${duration_sec}" =~ ^[0-9]+$ ]] || {
        printf 'invalid duration: %s\n' "${duration_sec}" >&2
        exit 1
    }

    if [[ -n "${handoff_env}" ]]; then
        [[ -f "${handoff_env}" ]] || {
            printf 'handoff env not found: %s\n' "${handoff_env}" >&2
            exit 1
        }
        load_env_file "${handoff_env}" handoff_map
        [[ -n "${cpuset_spec}" ]] || cpuset_spec="${handoff_map[PCM_HANDOFF_ROLE_CPUSET]:-}"
        [[ -n "${role_name}" ]] || role_name="${handoff_map[PCM_HANDOFF_ROLE]:-}"
        [[ -n "${output_dir}" ]] || output_dir="${handoff_map[PCM_HOST_REMOTE_RUN_DIR]:-}"
        [[ -n "${pcm_bin}" ]] || pcm_bin="${handoff_map[PCM_HOST_PCM_BIN]:-}"
        run_label="${handoff_map[PCM_HANDOFF_RUN_LABEL]:-}"
        role_namespace="${handoff_map[PCM_HANDOFF_ROLE_NAMESPACE]:-}"
        role_pod="${handoff_map[PCM_HANDOFF_ROLE_POD]:-}"
        role_container="${handoff_map[PCM_HANDOFF_ROLE_CONTAINER]:-}"
        remote_workdir="${handoff_map[PCM_HOST_REMOTE_WORKDIR]:-}"
        host_pcm_prefix="${handoff_map[PCM_HOST_PCM_PREFIX]:-${host_pcm_prefix}}"
        ssh_target="${handoff_map[PCM_HOST_SSH_TARGET]:-}"
        ssh_target_ref="${handoff_map[PCM_HOST_SSH_TARGET_REF]:-}"
        source_artifact_dir="${handoff_map[PCM_HANDOFF_SOURCE_ARTIFACT_DIR]:-}"
        source_cpuset_env="${handoff_map[PCM_HANDOFF_SOURCE_CPUSET_ENV]:-}"
    fi

    [[ -n "${cpuset_spec}" ]] || {
        printf 'missing cpuset input\n' >&2
        exit 1
    }
    [[ -n "${role_name}" ]] || role_name="vnf"
    [[ -n "${output_dir}" ]] || {
        printf 'missing output dir\n' >&2
        exit 1
    }

    if [[ -z "${pcm_bin}" ]]; then
        if [[ -x "${host_pcm_prefix}/bin/pcm-core" ]]; then
            pcm_bin="${host_pcm_prefix}/bin/pcm-core"
            pcm_bin_source="host-installed:${pcm_bin}"
        elif command -v pcm-core >/dev/null 2>&1; then
            pcm_bin="$(command -v pcm-core)"
            pcm_bin_source='host-existing:command-v'
        elif [[ "${allow_staged_default}" == "1" && -x "/var/tmp/nsm-ovs-pcm-host/bin/pcm-core" ]]; then
            pcm_bin="/var/tmp/nsm-ovs-pcm-host/bin/pcm-core"
            pcm_bin_source='legacy-staged-default:/var/tmp/nsm-ovs-pcm-host/bin/pcm-core'
        else
            printf 'no usable pcm-core binary found on host (checked %s/bin/pcm-core, PATH, staged-default opt-in=%s)\n' "${host_pcm_prefix}" "${allow_staged_default}" >&2
            exit 1
        fi
    fi

    [[ -x "${pcm_bin}" ]] || {
        printf 'pcm binary is not executable: %s\n' "${pcm_bin}" >&2
        exit 1
    }
    [[ "${sample_mode}" =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'invalid sample mode: %s\n' "${sample_mode}" >&2
        exit 1
    }

    mkdir -p "${output_dir}"
    command_file="${output_dir}/command.txt"
    topology_file="${output_dir}/target-topology-map.txt"
    raw_file="${output_dir}/pcm-sample.raw.txt"
    csv_file="${output_dir}/pcm-core.csv"
    target_csv_file="${output_dir}/pcm-core.target.csv"
    summary_env_file="${output_dir}/summary.env"
    summary_txt_file="${output_dir}/summary.txt"
    audit_file="${output_dir}/audit-host.txt"

    write_command_file "${command_file}" "$0" "${original_args[@]}"

    host_name="$(hostname)"
    current_user="$(whoami)"
    timeout_sec=$(( duration_sec + 5 ))

    mapfile -t cpus < <(expand_cpuset "${cpuset_spec}")
    [[ "${#cpus[@]}" -gt 0 ]] || {
        printf 'invalid cpuset: %s\n' "${cpuset_spec}" >&2
        exit 1
    }
    cpu_list_csv="$(printf '%s\n' "${cpus[@]}" | paste -sd, -)"

    {
        printf 'hostname=%s\n' "${host_name}"
        printf 'user=%s\n' "${current_user}"
        printf 'role=%s\n' "${role_name}"
        printf 'cpuset=%s\n' "${cpuset_spec}"
        printf 'cpu_list=%s\n' "${cpu_list_csv}"
        printf 'pcm_bin=%s\n' "${pcm_bin}"
        printf 'pcm_bin_source=%s\n' "${pcm_bin_source}"
        printf 'host_pcm_prefix=%s\n' "${host_pcm_prefix}"
        printf 'allow_staged_default=%s\n' "${allow_staged_default}"
        printf 'runtime_loader=%s\n' "${runtime_loader}"
        printf 'runtime_library_path=%s\n' "${runtime_library_path}"
        printf 'duration_sec=%s\n' "${duration_sec}"
        printf 'sample_mode=%s\n' "${sample_mode}"
        printf 'remote_workdir=%s\n' "${remote_workdir}"
        printf 'ssh_target=%s\n' "${ssh_target}"
        printf 'ssh_target_ref=%s\n' "${ssh_target_ref}"
        printf 'source_artifact_dir=%s\n' "${source_artifact_dir}"
        printf 'source_cpuset_env=%s\n' "${source_cpuset_env}"
        printf '\n[binary]\n'
        ls -l "${pcm_bin}" 2>&1 || true
        if command -v file >/dev/null 2>&1; then
            file "${pcm_bin}" 2>&1 || true
        fi
        if command -v ldd >/dev/null 2>&1; then
            ldd "${pcm_bin}" 2>&1 || true
        fi
        printf '\n[topology-preview]\n'
        lscpu -p=CPU,SOCKET,CORE 2>/dev/null | grep -v '^#' | head -n 16 || true
    } > "${audit_file}"

    build_topology_map "${cpuset_spec}" "${topology_file}" || true
    if grep -q '^CPU_MAP_ERROR ' "${topology_file}" || [[ ! -s "${topology_file}" ]]; then
        sample_status='fail'
        sample_reason='host-topology-map-failed'
    else
        parse_topology_file "${topology_file}" target_rows target_summary
        if [[ -z "${target_rows}" ]]; then
            sample_status='fail'
            sample_reason='host-target-rows-empty'
        else
            allowed_before="$(awk '/Cpus_allowed_list/ { print $2 }' /proc/$$/status)"
            if ! taskset -pc "${cpuset_spec}" $$ >/dev/null 2>&1; then
                sample_status='fail'
                sample_reason='host-taskset-failed'
            else
                allowed_after="$(awk '/Cpus_allowed_list/ { print $2 }' /proc/$$/status)"
                local -a sample_cmd=()
                if [[ -n "${runtime_loader}" ]]; then
                    if [[ ! -x "${runtime_loader}" ]]; then
                        sample_status='fail'
                        sample_reason='host-runtime-loader-not-executable'
                    elif [[ -z "${runtime_library_path}" || ! -d "${runtime_library_path}" ]]; then
                        sample_status='fail'
                        sample_reason='host-runtime-library-path-missing'
                    else
                        sample_cmd=( "${runtime_loader}" "--library-path" "${runtime_library_path}" "${pcm_bin}" "${duration_sec}" "-i=1" "-csv=/dev/stdout" )
                    fi
                else
                    sample_cmd=( "${pcm_bin}" "${duration_sec}" "-i=1" "-csv=/dev/stdout" )
                fi
                if [[ ! "${sample_reason}" == host-runtime-* ]]; then
                    set +e
                    timeout "${timeout_sec}" "${sample_cmd[@]}" > "${raw_file}" 2>&1
                    sample_rc=$?
                    set -e

                    if (( sample_rc == 0 )) && extract_csv_from_raw "${raw_file}" "${csv_file}" && filter_core_rows "${csv_file}" "${target_rows}" "${target_csv_file}"; then
                        target_row_count=$(( $(wc -l < "${target_csv_file}") - 1 ))
                        if grep -q 'pthread_setaffinity_np .* failed' "${raw_file}"; then
                            sample_status='fail'
                            sample_reason='host-pcm-affinity-error'
                        elif grep -q 'Core is offline' "${raw_file}"; then
                            sample_status='fail'
                            sample_reason='host-pcm-target-core-offline'
                        elif (( target_row_count > 0 )); then
                            sample_status='pass'
                            sample_reason='host-target-core-rows-captured'
                        else
                            sample_status='fail'
                            sample_reason='host-target-core-rows-missing'
                        fi
                    else
                        if (( sample_rc != 0 )); then
                            sample_reason="host-pcm-command-failed:${sample_rc}"
                        elif [[ ! -s "${csv_file}" ]]; then
                            sample_reason='host-pcm-csv-not-found'
                        else
                            sample_reason='host-pcm-target-rows-not-found'
                        fi
                        sample_status='fail'
                    fi
                fi
            fi
        fi
    fi

    {
        printf 'PCM_HOST_SAMPLE_STATUS=%s\n' "${sample_status}"
        printf 'PCM_HOST_SAMPLE_REASON=%s\n' "${sample_reason}"
        printf 'PCM_HOST_SAMPLE_ROLE=%s\n' "${role_name}"
        printf 'PCM_HOST_SAMPLE_CPUSET=%s\n' "${cpuset_spec}"
        printf 'PCM_HOST_SAMPLE_CPU_LIST=%s\n' "${cpu_list_csv}"
        printf 'PCM_HOST_SAMPLE_TARGET_ROWS=%s\n' "${target_rows}"
        printf 'PCM_HOST_SAMPLE_TARGET_SUMMARY=%s\n' "${target_summary}"
        printf 'PCM_HOST_SAMPLE_TARGET_ROW_COUNT=%s\n' "${target_row_count}"
        printf 'PCM_HOST_SAMPLE_MODE=%s\n' "${sample_mode}"
        printf 'PCM_HOST_SAMPLE_DURATION_SEC=%s\n' "${duration_sec}"
        printf 'PCM_HOST_SAMPLE_TIMEOUT_SEC=%s\n' "${timeout_sec}"
        printf 'PCM_HOST_SAMPLE_HOSTNAME=%s\n' "${host_name}"
        printf 'PCM_HOST_SAMPLE_USER=%s\n' "${current_user}"
        printf 'PCM_HOST_SAMPLE_ROLE_NAMESPACE=%s\n' "${role_namespace}"
        printf 'PCM_HOST_SAMPLE_ROLE_POD=%s\n' "${role_pod}"
        printf 'PCM_HOST_SAMPLE_ROLE_CONTAINER=%s\n' "${role_container}"
        printf 'PCM_HOST_SAMPLE_RUN_LABEL=%s\n' "${run_label}"
        printf 'PCM_HOST_SAMPLE_SOURCE_ARTIFACT_DIR=%s\n' "${source_artifact_dir}"
        printf 'PCM_HOST_SAMPLE_SOURCE_CPUSET_ENV=%s\n' "${source_cpuset_env}"
        printf 'PCM_HOST_SAMPLE_SSH_TARGET=%s\n' "${ssh_target}"
        printf 'PCM_HOST_SAMPLE_SSH_TARGET_REF=%s\n' "${ssh_target_ref}"
        printf 'PCM_HOST_SAMPLE_REMOTE_WORKDIR=%s\n' "${remote_workdir}"
        printf 'PCM_HOST_SAMPLE_HANDOFF_ENV=%s\n' "${handoff_env}"
        printf 'PCM_HOST_SAMPLE_PCM_BIN=%s\n' "${pcm_bin}"
        printf 'PCM_HOST_SAMPLE_PCM_BIN_SOURCE=%s\n' "${pcm_bin_source}"
        printf 'PCM_HOST_SAMPLE_PCM_PREFIX=%s\n' "${host_pcm_prefix}"
        printf 'PCM_HOST_SAMPLE_ALLOW_STAGED_DEFAULT=%s\n' "${allow_staged_default}"
        printf 'PCM_HOST_SAMPLE_RUNTIME_LOADER=%s\n' "${runtime_loader}"
        printf 'PCM_HOST_SAMPLE_RUNTIME_LIBRARY_PATH=%s\n' "${runtime_library_path}"
        printf 'PCM_HOST_SAMPLE_ALLOWED_BEFORE=%s\n' "${allowed_before}"
        printf 'PCM_HOST_SAMPLE_ALLOWED_AFTER=%s\n' "${allowed_after}"
        printf 'PCM_HOST_SAMPLE_COMMAND_FILE=%s\n' "${command_file}"
        printf 'PCM_HOST_SAMPLE_AUDIT_FILE=%s\n' "${audit_file}"
        printf 'PCM_HOST_SAMPLE_TOPOLOGY_MAP=%s\n' "${topology_file}"
        printf 'PCM_HOST_SAMPLE_RAW_OUTPUT=%s\n' "${raw_file}"
        printf 'PCM_HOST_SAMPLE_CORE_CSV=%s\n' "${csv_file}"
        printf 'PCM_HOST_SAMPLE_TARGET_CSV=%s\n' "${target_csv_file}"
        printf 'PCM_HOST_SAMPLE_COMMAND_RC=%s\n' "${sample_rc}"
    } > "${summary_env_file}"

    cat > "${summary_txt_file}" <<EOF
PCM Host-Level Sample
Status              : ${sample_status}
Reason              : ${sample_reason}
Role                : ${role_name}
CPUSet              : ${cpuset_spec}
Target CPUs         : ${cpu_list_csv}
Target rows         : ${target_rows}
Target summary      : ${target_summary}
Target row count    : ${target_row_count}
Mode                : ${sample_mode}
Duration            : ${duration_sec}s
Timeout             : ${timeout_sec}s
Host                : ${host_name}
User                : ${current_user}
SSH target          : ${ssh_target_ref:-${ssh_target}}
Remote workdir      : ${remote_workdir}
Source artifact     : ${source_artifact_dir}
Source cpuset env   : ${source_cpuset_env}
Source role pod     : ${role_namespace}/${role_pod} container=${role_container}
PCM binary          : ${pcm_bin}
PCM binary source   : ${pcm_bin_source}
PCM prefix          : ${host_pcm_prefix}
Staged default opt  : ${allow_staged_default}
Runtime loader      : ${runtime_loader:-<none>}
Runtime lib path    : ${runtime_library_path:-<none>}
Allowed pre         : ${allowed_before}
Allowed post        : ${allowed_after}
Command file        : ${command_file}
Audit file          : ${audit_file}
Topology map        : ${topology_file}
Raw output          : ${raw_file}
Core CSV            : ${csv_file}
Target CSV          : ${target_csv_file}
EOF

    [[ "${sample_status}" == "pass" ]]
}

main "$@"
