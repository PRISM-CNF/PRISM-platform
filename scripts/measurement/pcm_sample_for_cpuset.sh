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
source "${PLATFORM_REPO_ROOT}/scripts/lib/cpuset.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/pcm_cpuset.sh"

usage() {
    cat <<'EOF'
Usage: pcm_sample_for_cpuset.sh [platform-options] --output-dir <dir> (--cpuset <spec> | --cpuset-map-env <file> --role <name>) [options]

Options:
  --output-dir <dir>           Local artifact directory for the sample result.
  --cpuset <spec>              Explicit CPU set, for example 67 or 64-67.
  --cpuset-map-env <file>      Existing cpuset-map.env file to read a role cpuset from.
  --role <name>                Role name inside cpuset-map.env, for example vnf.
  --node <name>                Target node hosting the intel-pcm pod. Default: node01.
  --pcm-namespace <name>       Namespace of the intel-pcm DaemonSet. Default: intel-pcm.
  --pcm-pod <name>             Explicit intel-pcm pod name. Default: auto-discover on node.
  --pcm-container <name>       intel-pcm container name. Default: intel-pcm.
  --duration-sec <n>           PCM sample interval in seconds. Default: 1.
  --sample-mode <mode>         PCM command to execute. Default: pcm-core.
EOF
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
    local output_dir="" cpuset_spec="" cpuset_map_env="" role_name=""
    local node_name="node01" pcm_namespace="intel-pcm" pcm_pod="" pcm_container="intel-pcm"
    local duration_sec="1" sample_mode="pcm-core"
    local resolved_cpuset="" cpuset_source="" expanded_cpus="" cpu_list_csv=""
    local topology_file raw_file csv_file target_csv_file summary_env_file summary_txt_file command_file
    local sample_rc=0 sample_status="fail" sample_reason="" target_rows="" target_summary=""
    local target_row_count=0 wrapper_cgroup="" wrapper_allowed_before="" wrapper_allowed_after=""
    local -a expanded_cpu_array=()

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --output-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --output-dir"
                output_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --cpuset)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --cpuset"
                cpuset_spec="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --cpuset-map-env)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --cpuset-map-env"
                cpuset_map_env="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --role)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --role"
                role_name="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --node)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --node"
                node_name="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --pcm-namespace)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --pcm-namespace"
                pcm_namespace="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --pcm-pod)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --pcm-pod"
                pcm_pod="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --pcm-container)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --pcm-container"
                pcm_container="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
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
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown pcm_sample_for_cpuset argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    [[ -n "${output_dir}" ]] || die "pcm_sample_for_cpuset requires --output-dir"
    [[ "${duration_sec}" =~ ^[0-9]+$ ]] || die "invalid --duration-sec: ${duration_sec}"
    [[ "${sample_mode}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid --sample-mode: ${sample_mode}"

    pcm_cpuset_resolve_input "${cpuset_spec}" "${cpuset_map_env}" "${role_name}" resolved_cpuset cpuset_source
    mapfile -t expanded_cpu_array < <(cpuset_expand "${resolved_cpuset}")
    expanded_cpus="$(printf '%s\n' "${expanded_cpu_array[@]}")"
    cpu_list_csv="$(printf '%s\n' "${expanded_cpus}" | paste -sd, -)"

    mkdir -p "${output_dir}"
    topology_file="${output_dir}/target-topology-map.txt"
    raw_file="${output_dir}/pcm-sample.raw.txt"
    csv_file="${output_dir}/pcm-core.csv"
    target_csv_file="${output_dir}/pcm-core.target.csv"
    summary_env_file="${output_dir}/summary.env"
    summary_txt_file="${output_dir}/summary.txt"
    command_file="${output_dir}/command.txt"

    write_command_file "${command_file}" "$0" "$@"

    k8s_require_cluster

    if [[ -z "${pcm_pod}" ]]; then
        pcm_pod="$(pcm_cpuset_discover_pod_on_node "${pcm_namespace}" "${node_name}")"
    fi
    [[ -n "${pcm_pod}" ]] || die "failed to discover intel-pcm pod on node ${node_name} in namespace ${pcm_namespace}"

    local remote_topology_script
    read -r -d '' remote_topology_script <<'EOF' || true
set -eu
cpuset_spec="__CPUSET__"
expand_cpuset() {
    echo "${cpuset_spec}" | tr ',' '\n' | while IFS= read -r part; do
        [ -n "${part}" ] || continue
        case "${part}" in
            *-*)
                start=${part%-*}
                end=${part#*-}
                cpu="${start}"
                while [ "${cpu}" -le "${end}" ]; do
                    printf '%s\n' "${cpu}"
                    cpu=$((cpu + 1))
                done
                ;;
            *)
                printf '%s\n' "${part}"
                ;;
        esac
    done
}
pairs="$(
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "${cpu_dir}" ] || continue
        socket=$(cat "${cpu_dir}/topology/physical_package_id")
        core_id=$(cat "${cpu_dir}/topology/core_id")
        printf '%s:%s\n' "${socket}" "${core_id}"
    done | sort -u -t: -k1,1n -k2,2n
)"
expand_cpuset | while IFS= read -r cpu; do
    cpu_dir="/sys/devices/system/cpu/cpu${cpu}"
    [ -d "${cpu_dir}" ] || {
        echo "CPU_MAP_ERROR cpu=${cpu} reason=missing-cpu-dir"
        exit 1
    }
    socket=$(cat "${cpu_dir}/topology/physical_package_id")
    core_id=$(cat "${cpu_dir}/topology/core_id")
    siblings=$(cat "${cpu_dir}/topology/thread_siblings_list")
    global_core_row=$(printf '%s\n' "${pairs}" | awk -F: -v want="${socket}:${core_id}" 'BEGIN { idx = 0 } $0 == want { print idx; found = 1; exit } { idx++ } END { if (!found) exit 1 }')
    printf 'CPU_MAP cpu=%s socket=%s core_id=%s siblings=%s global_core_row=%s\n' "${cpu}" "${socket}" "${core_id}" "${siblings}" "${global_core_row}"
done
EOF
    remote_topology_script="${remote_topology_script//__CPUSET__/${resolved_cpuset}}"

    printf '%s\n' "${remote_topology_script}" | "${KUBECTL:-kubectl}" exec -i -n "${pcm_namespace}" "${pcm_pod}" -c "${pcm_container}" -- sh > "${topology_file}"

    if grep -q '^CPU_MAP_ERROR ' "${topology_file}"; then
        die "failed to resolve target topology: $(tr '\n' ' ' < "${topology_file}")"
    fi

    parse_topology_file "${topology_file}" target_rows target_summary
    [[ -n "${target_rows}" ]] || die "failed to resolve target core rows from ${topology_file}"

    local remote_sample_script
    read -r -d '' remote_sample_script <<'EOF' || true
set -eu
echo $$ > /sys/fs/cgroup/cgroup.procs
printf 'PCM_WRAPPER_CGROUP=%s\n' "$(cat /proc/$$/cgroup | tr '\n' ';')"
printf 'PCM_WRAPPER_ALLOWED_BEFORE=%s\n' "$(awk '/Cpus_allowed_list/ { print $2 }' /proc/$$/status)"
taskset -pc "__CPUSET__" $$
printf 'PCM_WRAPPER_ALLOWED_AFTER=%s\n' "$(awk '/Cpus_allowed_list/ { print $2 }' /proc/$$/status)"
timeout __TIMEOUT__ /usr/local/bin/__SAMPLE_MODE__ __DURATION__ -i=1 -csv=/dev/stdout
EOF
    remote_sample_script="${remote_sample_script//__CPUSET__/${resolved_cpuset}}"
    remote_sample_script="${remote_sample_script//__TIMEOUT__/$(( duration_sec + 5 ))}"
    remote_sample_script="${remote_sample_script//__DURATION__/${duration_sec}}"
    remote_sample_script="${remote_sample_script//__SAMPLE_MODE__/${sample_mode}}"

    set +e
    printf '%s\n' "${remote_sample_script}" | "${KUBECTL:-kubectl}" exec -i -n "${pcm_namespace}" "${pcm_pod}" -c "${pcm_container}" -- sh > "${raw_file}" 2>&1
    sample_rc=$?
    set -e

    wrapper_cgroup="$(sed -n 's/^PCM_WRAPPER_CGROUP=//p' "${raw_file}" | tail -n 1)"
    wrapper_allowed_before="$(sed -n 's/^PCM_WRAPPER_ALLOWED_BEFORE=//p' "${raw_file}" | tail -n 1)"
    wrapper_allowed_after="$(sed -n 's/^PCM_WRAPPER_ALLOWED_AFTER=//p' "${raw_file}" | tail -n 1)"

    if (( sample_rc == 0 )) && pcm_cpuset_extract_csv_from_raw "${raw_file}" "${csv_file}" && pcm_cpuset_filter_core_rows "${csv_file}" "${target_rows}" "${target_csv_file}"; then
        target_row_count=$(( $(wc -l < "${target_csv_file}") - 1 ))
        if grep -q 'pthread_setaffinity_np .* failed' "${raw_file}"; then
            sample_status='fail'
            sample_reason='pcm-affinity-error-detected-after-cgroup-escape'
        elif grep -q 'Core is offline' "${raw_file}"; then
            sample_status='fail'
            sample_reason='pcm-reported-target-core-offline-after-cgroup-escape'
        elif (( target_row_count > 0 )); then
            sample_status='pass'
            sample_reason='target-core-rows-captured'
        else
            sample_status='fail'
            sample_reason='target-core-rows-missing'
        fi
    else
        sample_status='fail'
        if (( sample_rc != 0 )); then
            sample_reason="pcm-command-failed:${sample_rc}"
        elif [[ ! -s "${csv_file}" ]]; then
            sample_reason='pcm-csv-not-found'
        else
            sample_reason='pcm-target-rows-not-found'
        fi
    fi

    {
        printf 'PCM_SAMPLE_STATUS=%s\n' "${sample_status}"
        printf 'PCM_SAMPLE_REASON=%s\n' "${sample_reason}"
        printf 'PCM_SAMPLE_MODE=%s\n' "${sample_mode}"
        printf 'PCM_SAMPLE_DURATION_SEC=%s\n' "${duration_sec}"
        printf 'PCM_SAMPLE_NODE=%s\n' "${node_name}"
        printf 'PCM_SAMPLE_NAMESPACE=%s\n' "${pcm_namespace}"
        printf 'PCM_SAMPLE_POD=%s\n' "${pcm_pod}"
        printf 'PCM_SAMPLE_CONTAINER=%s\n' "${pcm_container}"
        printf 'PCM_SAMPLE_CPUSET=%s\n' "${resolved_cpuset}"
        printf 'PCM_SAMPLE_CPUSET_SOURCE=%s\n' "${cpuset_source}"
        printf 'PCM_SAMPLE_CPU_LIST=%s\n' "${cpu_list_csv}"
        printf 'PCM_TARGET_CORE_ROWS=%s\n' "${target_rows}"
        printf 'PCM_TARGET_CORE_SUMMARY=%s\n' "${target_summary}"
        printf 'PCM_TARGET_ROW_COUNT=%s\n' "${target_row_count}"
        printf 'PCM_WRAPPER_CGROUP=%s\n' "${wrapper_cgroup}"
        printf 'PCM_WRAPPER_ALLOWED_BEFORE=%s\n' "${wrapper_allowed_before}"
        printf 'PCM_WRAPPER_ALLOWED_AFTER=%s\n' "${wrapper_allowed_after}"
        printf 'PCM_COMMAND_FILE=%s\n' "${command_file}"
        printf 'PCM_TOPOLOGY_MAP=%s\n' "${topology_file}"
        printf 'PCM_RAW_OUTPUT=%s\n' "${raw_file}"
        printf 'PCM_CORE_CSV=%s\n' "${csv_file}"
        printf 'PCM_TARGET_CSV=%s\n' "${target_csv_file}"
        printf 'PCM_COMMAND_RC=%s\n' "${sample_rc}"
    } > "${summary_env_file}"

    cat > "${summary_txt_file}" <<EOF
PCM Sample For CPUSet
Status              : ${sample_status}
Reason              : ${sample_reason}
Mode                : ${sample_mode}
Duration            : ${duration_sec}s
Node                : ${node_name}
intel-pcm pod       : ${pcm_namespace}/${pcm_pod} container=${pcm_container}
CPUSet input        : ${resolved_cpuset}
CPUSet source       : ${cpuset_source}
Expanded CPUs       : ${cpu_list_csv}
Target core rows    : ${target_rows}
Target core summary : ${target_summary}
Target row count    : ${target_row_count}
Wrapper cgroup      : ${wrapper_cgroup}
Wrapper allowed pre : ${wrapper_allowed_before}
Wrapper allowed post: ${wrapper_allowed_after}
Command file        : ${command_file}
Topology map        : ${topology_file}
Raw output          : ${raw_file}
PCM CSV             : ${csv_file}
Target CSV          : ${target_csv_file}

Limitation
- The current PCM CLI does not expose an explicit core-list filter in the daemon entrypoint.
- This wrapper accepts an external cpuset, escapes the container cgroup that blocks exclusive CPUs, runs a one-shot PCM core sample, and then filters the target core rows locally.
- Metrics stay at physical-core granularity. For node01, CPU 67 maps to socket0/core3, so the relevant PCM row is core row 3.
EOF

    log_info "pcm sample status=${sample_status} reason=${sample_reason}"
    log_info "pcm sample cpuset=${resolved_cpuset} target_rows=${target_rows}"
    log_info "pcm raw output=${raw_file}"
    log_info "pcm target csv=${target_csv_file}"

    if [[ "${sample_status}" != "pass" ]]; then
        exit 1
    fi
}

main "$@"
