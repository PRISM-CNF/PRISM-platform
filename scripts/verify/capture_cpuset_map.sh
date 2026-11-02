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

usage() {
    cat <<'EOF'
Usage: capture_cpuset_map.sh [platform-options] --output-dir <dir> [--namespace <name>] --role-binding <role,pod,container> [--role-binding <role,namespace,pod,container> ...]
EOF
}

json_escape() {
    local value=${1:-}

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "${value}"
}

binding_parse() {
    local binding=$1
    local default_namespace=$2
    local role_var=$3
    local namespace_var=$4
    local pod_var=$5
    local container_var=$6
    local parsed_role="" parsed_namespace="" parsed_pod_name="" parsed_container_name="" extra=""
    local field_count

    field_count="$(awk -F',' '{ print NF }' <<< "${binding}")"
    case "${field_count}" in
        3)
            IFS=',' read -r parsed_role parsed_pod_name parsed_container_name <<< "${binding}"
            parsed_namespace="${default_namespace}"
            ;;
        4)
            IFS=',' read -r parsed_role parsed_namespace parsed_pod_name parsed_container_name extra <<< "${binding}"
            ;;
        *)
            die "invalid --role-binding format: ${binding}"
            ;;
    esac

    parsed_role="$(platform_trim "${parsed_role}")"
    parsed_namespace="$(platform_trim "${parsed_namespace}")"
    parsed_pod_name="$(platform_trim "${parsed_pod_name}")"
    parsed_container_name="$(platform_trim "${parsed_container_name}")"

    [[ -n "${parsed_role}" ]] || die "role-binding role is empty: ${binding}"
    [[ -n "${parsed_namespace}" ]] || die "role-binding namespace is empty: ${binding}; use --namespace or role,namespace,pod,container"
    [[ -n "${parsed_pod_name}" ]] || die "role-binding pod is empty: ${binding}"
    [[ -n "${parsed_container_name}" ]] || die "role-binding container is empty: ${binding}"

    printf -v "${role_var}" '%s' "${parsed_role}"
    printf -v "${namespace_var}" '%s' "${parsed_namespace}"
    printf -v "${pod_var}" '%s' "${parsed_pod_name}"
    printf -v "${container_var}" '%s' "${parsed_container_name}"
}

capture_cpuset_for_binding() {
    local namespace=$1
    local pod_name=$2
    local container_name=$3
    local cpuset_var=$4
    local source_var=$5
    local status_var=$6
    local reason_var=$7
    local cpuset_output='' source_output='' status_output='missing' reason_output='' exec_output='' exec_status=0
    local stderr_file

    stderr_file="$(mktemp)"

    set +e
    exec_output="$("${KUBECTL:-kubectl}" exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- \
        sh -c "awk '/Cpus_allowed_list/ { print \$2; exit }' /proc/1/status 2>/dev/null" 2>"${stderr_file}")"
    exec_status=$?
    set -e

    if [[ "${exec_status}" -eq 0 ]]; then
        cpuset_output="$(platform_trim "${exec_output}")"
        if [[ -n "${cpuset_output}" ]]; then
            source_output='proc1-status'
            status_output='ok'
            reason_output=''
        else
            cpuset_output=''
        fi
    fi

    if [[ -z "${cpuset_output}" ]]; then
        set +e
        : > "${stderr_file}"
        exec_output="$("${KUBECTL:-kubectl}" exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- \
            sh -c 'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset.cpus 2>/dev/null' 2>"${stderr_file}")"
        exec_status=$?
        set -e

        if [[ "${exec_status}" -eq 0 ]]; then
            cpuset_output="$(platform_trim "${exec_output}")"
            if [[ -n "${cpuset_output}" ]]; then
                source_output='cgroup-cpuset'
                status_output='ok'
                reason_output=''
            else
                status_output='missing'
                reason_output='empty-cpuset-output'
            fi
        else
            cpuset_output=''
            source_output=''
            reason_output="$(tr '\n' ' ' < "${stderr_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
            reason_output="${reason_output:0:240}"
            if [[ -z "${reason_output}" ]]; then
                reason_output="kubectl-exec-failed:${exec_status}"
            else
                reason_output="kubectl-exec-failed:${exec_status}:${reason_output}"
            fi
            status_output='missing'
        fi
    fi

    printf -v "${cpuset_var}" '%s' "${cpuset_output}"
    printf -v "${source_var}" '%s' "${source_output}"
    printf -v "${status_var}" '%s' "${status_output}"
    printf -v "${reason_var}" '%s' "${reason_output}"
    rm -f "${stderr_file}"
}

main() {
    local output_dir="" default_namespace=""
    local env_file txt_file json_file
    local binding role_name="" role_namespace="" pod_name="" container_name="" role_key=""
    local role_count=0 actual_layout="" role_entry
    local cpuset_value cpuset_source status_value reason_value
    local -a role_bindings=() json_entries=()

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --output-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --output-dir"
                output_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --namespace)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --namespace"
                default_namespace="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --role-binding)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --role-binding"
                role_bindings+=("${PLATFORM_EXTRA_ARGS[1]}")
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown capture_cpuset_map argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    [[ -n "${output_dir}" ]] || die "capture_cpuset_map requires --output-dir"
    [[ "${#role_bindings[@]}" -gt 0 ]] || die "capture_cpuset_map requires at least one --role-binding"

    mkdir -p "${output_dir}"
    env_file="${output_dir}/cpuset-map.env"
    txt_file="${output_dir}/cpuset-map.txt"
    json_file="${output_dir}/cpuset-map.json"

    k8s_require_cluster

    {
        printf 'NAMESPACE_DEFAULT=%s\n' "${default_namespace}"
        printf 'ROLE_COUNT=%s\n' "${#role_bindings[@]}"
    } > "${env_file}"

    cat > "${txt_file}" <<EOF
CPUSet Map
Default namespace  : ${default_namespace:-<none>}
Role count         : ${#role_bindings[@]}
EOF

    for binding in "${role_bindings[@]}"; do
        binding_parse "${binding}" "${default_namespace}" role_name role_namespace pod_name container_name
        role_count=$((role_count + 1))
        role_key="$(cpuset_role_key "${role_name}")"

        capture_cpuset_for_binding "${role_namespace}" "${pod_name}" "${container_name}" cpuset_value cpuset_source status_value reason_value

        printf 'ROLE_%s_NAME=%s\n' "${role_count}" "${role_name}" >> "${env_file}"
        printf 'ROLE_%s_KEY=%s\n' "${role_count}" "${role_key}" >> "${env_file}"
        printf 'ROLE_%s_NAMESPACE=%s\n' "${role_count}" "${role_namespace}" >> "${env_file}"
        printf 'ROLE_%s_POD=%s\n' "${role_count}" "${pod_name}" >> "${env_file}"
        printf 'ROLE_%s_CONTAINER=%s\n' "${role_count}" "${container_name}" >> "${env_file}"
        printf 'ROLE_%s_CPUSET=%s\n' "${role_count}" "${cpuset_value}" >> "${env_file}"
        printf 'ROLE_%s_CPUSET_SOURCE=%s\n' "${role_count}" "${cpuset_source}" >> "${env_file}"
        printf 'ROLE_%s_STATUS=%s\n' "${role_count}" "${status_value}" >> "${env_file}"
        printf 'ROLE_%s_REASON=%s\n' "${role_count}" "${reason_value}" >> "${env_file}"
        printf 'CPUSET_%s_NAMESPACE=%s\n' "${role_key}" "${role_namespace}" >> "${env_file}"
        printf 'CPUSET_%s_POD=%s\n' "${role_key}" "${pod_name}" >> "${env_file}"
        printf 'CPUSET_%s_CONTAINER=%s\n' "${role_key}" "${container_name}" >> "${env_file}"
        printf 'CPUSET_%s_CPUSET=%s\n' "${role_key}" "${cpuset_value}" >> "${env_file}"
        printf 'CPUSET_%s_CPUSET_SOURCE=%s\n' "${role_key}" "${cpuset_source}" >> "${env_file}"
        printf 'CPUSET_%s_STATUS=%s\n' "${role_key}" "${status_value}" >> "${env_file}"
        printf 'CPUSET_%s_REASON=%s\n' "${role_key}" "${reason_value}" >> "${env_file}"

        role_entry="${role_name}=${cpuset_value:-missing}"
        if [[ "${status_value}" != "ok" ]]; then
            role_entry="${role_entry}[${status_value}${reason_value:+:${reason_value}}]"
        fi
        if [[ -n "${actual_layout}" ]]; then
            actual_layout="${actual_layout}; "
        fi
        actual_layout="${actual_layout}${role_entry}"

        {
            printf '\n[%s]\n' "${role_name}"
            printf 'namespace           : %s\n' "${role_namespace}"
            printf 'pod                 : %s\n' "${pod_name}"
            printf 'container           : %s\n' "${container_name}"
            printf 'cpuset              : %s\n' "${cpuset_value:-<missing>}"
            printf 'cpuset source       : %s\n' "${cpuset_source:-<unknown>}"
            printf 'status              : %s\n' "${status_value}"
            printf 'reason              : %s\n' "${reason_value:-<none>}"
        } >> "${txt_file}"

        json_entries+=("    {\"name\":\"$(json_escape "${role_name}")\",\"key\":\"$(json_escape "${role_key}")\",\"namespace\":\"$(json_escape "${role_namespace}")\",\"pod\":\"$(json_escape "${pod_name}")\",\"container\":\"$(json_escape "${container_name}")\",\"cpuset\":\"$(json_escape "${cpuset_value}")\",\"cpuset_source\":\"$(json_escape "${cpuset_source}")\",\"status\":\"$(json_escape "${status_value}")\",\"reason\":\"$(json_escape "${reason_value}")\"}")
    done

    printf 'ACTUAL_LAYOUT=%s\n' "${actual_layout}" >> "${env_file}"
    printf '\nActual layout      : %s\n' "${actual_layout}" >> "${txt_file}"

    {
        printf '{\n'
        printf '  "namespace_default": "%s",\n' "$(json_escape "${default_namespace}")"
        printf '  "role_count": %s,\n' "${role_count}"
        printf '  "actual_layout": "%s",\n' "$(json_escape "${actual_layout}")"
        printf '  "roles": [\n'
        if [[ "${#json_entries[@]}" -gt 0 ]]; then
            local json_index
            for (( json_index = 0; json_index < ${#json_entries[@]}; json_index++ )); do
                printf '%s' "${json_entries[json_index]}"
                if (( json_index + 1 < ${#json_entries[@]} )); then
                    printf ','
                fi
                printf '\n'
            done
        fi
        printf '  ]\n'
        printf '}\n'
    } > "${json_file}"

    log_info "captured cpuset map: ${txt_file}"
    log_info "captured cpuset env: ${env_file}"
    log_info "captured cpuset json: ${json_file}"
}

main "$@"
