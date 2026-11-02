#!/usr/bin/env bash

if [[ -n "${NSM_OVS_LB_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_LB_STACK_SH_LOADED=1

LB_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${LB_STACK_LIB_DIR}/template_stack.sh"

lb_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|lb)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
        client)
            printf '%s\n' "${TEMPLATE_DEFAULT_CLIENT_NODE:-node01}"
            ;;
        server)
            printf '%s\n' "${TEMPLATE_DEFAULT_SERVER_NODE:-node01}"
            ;;
        *)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
    esac
}

lb_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == lb-* && "${stack_id#lb-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#lb-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

lb_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

lb_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(lb_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-lb-%s\n' "${suffix}"
}

lb_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${LB_STACK_STATE_ROOT}" "${stack_id}"
}

lb_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${LB_GENERATED_ROOT}" "${stack_id}"
}

lb_stack_plan_dirs() {
    mkdir -p "${LB_STACK_STATE_ROOT}" "${LB_GENERATED_ROOT}"
}

lb_stack_calculate_vip_ipv4() {
    local backend_ipv4=$1
    local backend_int vip_int

    backend_int="$(template_stack_ipv4_to_int "${backend_ipv4}")"
    vip_int=$((backend_int + 10))
    template_stack_int_to_ipv4 "${vip_int}"
}

lb_stack_backend_cidr_to_service_cidr() {
    local backend_cidr=$1
    local backend_ipv4 vip_ipv4

    backend_ipv4="${backend_cidr%%/*}"
    vip_ipv4="$(lb_stack_calculate_vip_ipv4 "${backend_ipv4}")"
    printf '%s/32\n' "${vip_ipv4}"
}

lb_stack_state_conflict_cidrs() {
    local state_file=$1
    local other_service_cidr other_backend_cidr
    local raw_line key value

    other_service_cidr=''
    other_backend_cidr=''

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        [[ -n "${raw_line}" ]] || continue
        [[ "${raw_line}" == \#* ]] && continue
        [[ "${raw_line}" == *=* ]] || continue

        key=${raw_line%%=*}
        value=${raw_line#*=}
        value=${value%$'\r'}

        case "${key}" in
            STACK_SERVICE_CIDR)
                other_service_cidr="${value}"
                ;;
            STACK_BACKEND_CIDR)
                other_backend_cidr="${value}"
                ;;
        esac
    done < "${state_file}"

    if [[ -n "${other_service_cidr}" ]]; then
        printf '%s\n' "${other_service_cidr}"
    fi

    if [[ -n "${other_backend_cidr}" && "${other_backend_cidr}" != "${other_service_cidr}" ]]; then
        printf '%s\n' "${other_backend_cidr}"
    fi
}

lb_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(lb_stack_name_suffix "${LB_STACK_ID}")"

    LB_STACK_LABEL_KEY='exp.nsm.ai/stack'
    LB_ROLE_LABEL_KEY='exp.nsm.ai/role'
    LB_STACK_LABEL_VALUE="${LB_STACK_ID}"
    LB_STACK_LABEL="${LB_STACK_LABEL_KEY}=${LB_STACK_LABEL_VALUE}"

    LB_ROLE_CLIENT='client'
    LB_ROLE_MIDDLE='middle'
    LB_ROLE_SERVER='server'

    LB_STACK_MIDDLE_DEPLOYMENT_NAME="nse-ovs-lb-${name_suffix}"
    LB_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    LB_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"
    LB_STACK_RULES_CONFIGMAP_NAME='nse-ovs-lb-rules'
    LB_STACK_RULES_CIDR_PATCH_ENABLED='true'

    LB_STACK_MIDDLE_POD_SELECTOR="${LB_STACK_LABEL_KEY}=${LB_STACK_ID},${LB_ROLE_LABEL_KEY}=${LB_ROLE_MIDDLE}"
    LB_STACK_SERVER_POD_SELECTOR="${LB_STACK_LABEL_KEY}=${LB_STACK_ID},${LB_ROLE_LABEL_KEY}=${LB_ROLE_SERVER}"
    LB_STACK_CLIENT_POD_SELECTOR="${LB_STACK_LABEL_KEY}=${LB_STACK_ID},${LB_ROLE_LABEL_KEY}=${LB_ROLE_CLIENT}"

    LB_STACK_MIDDLE_NSM_LABELS="${LB_STACK_LABEL_KEY}:${LB_STACK_ID},${LB_ROLE_LABEL_KEY}:${LB_ROLE_MIDDLE}"
    LB_STACK_SERVER_NSM_LABELS="${LB_STACK_LABEL_KEY}:${LB_STACK_ID},${LB_ROLE_LABEL_KEY}:${LB_ROLE_SERVER}"
    LB_STACK_CLIENT_NETWORK_SERVICES="kernel://${LB_STACK_NETWORK_SERVICE_NAME}/nsm-1"

    if [[ -z "${LB_STACK_BACKEND_CIDR:-}" ]]; then
        LB_STACK_BACKEND_CIDR="${LB_STACK_SERVICE_CIDR}"
        LB_STACK_BACKEND_CIDR_SOURCE="${LB_STACK_SERVICE_CIDR_SOURCE:-derived}"
        LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE="${LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE:-derived}"
    fi

    if [[ -z "${LB_STACK_SERVICE_CIDR:-}" || "${LB_STACK_SERVICE_CIDR##*/}" != "32" ]]; then
        LB_STACK_SERVICE_CIDR="$(lb_stack_backend_cidr_to_service_cidr "${LB_STACK_BACKEND_CIDR}")"
        LB_STACK_SERVICE_CIDR_SOURCE='derived'
        LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE:-derived}"
    fi

    LB_STACK_SERVER_IPV4="${LB_STACK_BACKEND_CIDR%%/*}"
    LB_STACK_BACKEND_IPV4="${LB_STACK_SERVER_IPV4}"
    LB_STACK_VIP_IPV4="$(lb_stack_calculate_vip_ipv4 "${LB_STACK_BACKEND_IPV4}")"

    LB_STACK_STATE_FILE="$(lb_stack_state_file "${LB_STACK_ID}")"
    LB_STACK_GENERATED_DIR="$(lb_stack_generated_dir_for "${LB_STACK_ID}")"
    LB_STACK_PATCH_DIR="${LB_STACK_GENERATED_DIR}/patches"
    LB_STACK_RESOLVED_VALUES_FILE="${LB_STACK_GENERATED_DIR}/resolved-values.env"
}

lb_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(lb_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

lb_stack_assert_no_conflicts() {
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local -A state_map=()

    for state_file in $(lb_stack_each_other_state "${LB_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_stack_id="${state_map[STACK_ID]:-$(basename "${state_file}" .env)}"
        other_namespace="${state_map[STACK_NAMESPACE]:-}"
        other_network_service="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
        other_cidr="${state_map[STACK_SERVICE_CIDR]:-}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${LB_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "lb namespace ${LB_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${LB_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "lb network service ${LB_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        while IFS= read -r other_cidr; do
            [[ -n "${other_cidr}" ]] || continue

            if template_stack_cidrs_overlap "${LB_STACK_SERVICE_CIDR}" "${other_cidr}"; then
                die "lb service CIDR ${LB_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
            fi

            if template_stack_cidrs_overlap "${LB_STACK_BACKEND_CIDR}" "${other_cidr}"; then
                die "lb backend CIDR ${LB_STACK_BACKEND_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
            fi
        done < <(lb_stack_state_conflict_cidrs "${state_file}")
    done
}

lb_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr candidate_service_cidr
    local candidate_end_int candidate_service_start_int candidate_service_end_int
    local subnet_size subnet_count index state_file other_cidr range_index
    local conflict
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid lb CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "lb CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))

    for state_file in $(lb_stack_each_other_state "${LB_STACK_ID}"); do
        while IFS= read -r other_cidr; do
            [[ -n "${other_cidr}" ]] || continue
            other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
            other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
        done < <(lb_stack_state_conflict_cidrs "${state_file}")
    done

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
        candidate_service_cidr="$(lb_stack_backend_cidr_to_service_cidr "${candidate_cidr}")"
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        candidate_service_start_int="$(template_stack_cidr_range_start "${candidate_service_cidr}")"
        candidate_service_end_int="$(template_stack_cidr_range_end "${candidate_service_cidr}")"
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi

            if (( candidate_service_start_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_service_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free lb service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

lb_stack_resolve_role_node() {
    local role_label=$1
    local requested_value=$2
    local persisted_value=$3
    local persisted_origin_source=$4
    local target_value_name=$5
    local target_source_name=$6
    local target_origin_name=$7
    local resolved_value resolved_source resolved_origin

    if [[ -n "${requested_value}" ]]; then
        resolved_value="${requested_value}"
        resolved_source='override'
        resolved_origin='override'
    elif [[ -n "${persisted_value}" ]]; then
        resolved_value="${persisted_value}"
        resolved_source='persisted'
        resolved_origin="${persisted_origin_source:-persisted}"
    else
        resolved_value="$(lb_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

lb_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(lb_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    LB_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    LB_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    LB_STACK_NAMESPACE_SOURCE='persisted'
    LB_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    LB_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    LB_STACK_SERVICE_CIDR_SOURCE='persisted'
    LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_BACKEND_CIDR="${state_map[STACK_BACKEND_CIDR]:-}"
    LB_STACK_BACKEND_CIDR_SOURCE='persisted'
    LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE="${state_map[STACK_BACKEND_CIDR_ORIGIN_SOURCE]:-${LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE:-persisted}}"
    LB_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    LB_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    LB_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    LB_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    LB_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    LB_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    LB_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    LB_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    LB_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${LB_STACK_NAMESPACE}" ]] || die "persisted lb stack namespace missing in ${state_file}"
    [[ -n "${LB_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted lb stack network service missing in ${state_file}"
    [[ -n "${LB_STACK_SERVICE_CIDR}" ]] || die "persisted lb stack service CIDR missing in ${state_file}"

    lb_stack_set_derived_values
    return 0
}

lb_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${LB_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${LB_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${LB_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

    if [[ -n "${created_at}" ]]; then
        if [[ -z "${created_at_local}" ]]; then
            created_at_local="$(platform_rfc3339_to_local_iso8601 "${created_at}")"
        fi
        if [[ -z "${created_at_epoch_ms}" ]]; then
            created_at_epoch_ms="$(platform_rfc3339_to_epoch_ms "${created_at}")"
        fi
    fi

    if [[ -z "${created_at}" ]]; then
        created_at_local="$(platform_now_local_iso8601)"
        created_at="$(platform_now_utc_iso8601)"
        created_at_epoch_ms="$(platform_now_epoch_ms)"
    fi

    cat > "${LB_STACK_STATE_FILE}" <<EOF
STACK_ID=${LB_STACK_ID}
STACK_NAMESPACE=${LB_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${LB_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${LB_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${LB_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_BACKEND_CIDR=${LB_STACK_BACKEND_CIDR}
STACK_BACKEND_CIDR_ORIGIN_SOURCE=${LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${LB_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${LB_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${LB_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${LB_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${LB_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${LB_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${LB_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${LB_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    LB_STACK_STATE_CREATED_AT="${created_at}"
    LB_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    LB_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

lb_stack_require_id() {
    LB_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${LB_STACK_ID}" ]] || die "missing required --stack-id for lb stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "lb stack operation requires an explicit --stack-id"
    TEMPLATE_STACK_ID="${LB_STACK_ID}"
    template_stack_validate_id "${LB_STACK_ID}"
}

lb_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    lb_stack_plan_dirs
    lb_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "lb namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "lb network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "lb VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "lb client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "lb server node override"
    fi

    if lb_stack_load_state "${LB_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${LB_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${LB_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "backend_cidr" "${requested_cidr}" "${LB_STACK_BACKEND_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${LB_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${LB_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${LB_STACK_SERVER_NODE_PERSISTED:-}"
        lb_stack_resolve_role_node "lb VNF" "${requested_vnf_node}" "${LB_STACK_VNF_NODE_PERSISTED:-}" "${LB_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" LB_STACK_VNF_NODE LB_STACK_VNF_NODE_SOURCE LB_STACK_VNF_NODE_ORIGIN_SOURCE
        lb_stack_resolve_role_node "lb client" "${requested_client_node}" "${LB_STACK_CLIENT_NODE_PERSISTED:-}" "${LB_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" LB_STACK_CLIENT_NODE LB_STACK_CLIENT_NODE_SOURCE LB_STACK_CLIENT_NODE_ORIGIN_SOURCE
        lb_stack_resolve_role_node "lb server" "${requested_server_node}" "${LB_STACK_SERVER_NODE_PERSISTED:-}" "${LB_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" LB_STACK_SERVER_NODE LB_STACK_SERVER_NODE_SOURCE LB_STACK_SERVER_NODE_ORIGIN_SOURCE
        return 0
    fi

    LB_STACK_NAMESPACE="${requested_namespace:-$(lb_stack_default_namespace "${LB_STACK_ID}")}"
    LB_STACK_NAMESPACE_SOURCE='default'
    LB_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        LB_STACK_NAMESPACE_SOURCE='override'
        LB_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    LB_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(lb_stack_default_network_service_name "${LB_STACK_ID}")}"
    LB_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        LB_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    LB_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    LB_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        LB_STACK_BACKEND_CIDR="${requested_cidr}"
        LB_STACK_BACKEND_CIDR_SOURCE='override'
        LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE='override'
    else
        LB_STACK_BACKEND_CIDR="$(lb_stack_allocate_cidr "${LB_STACK_CIDR_POOL}" "${LB_STACK_CIDR_PREFIX_LEN}")"
        LB_STACK_BACKEND_CIDR_SOURCE='allocated'
        LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE='allocated'
    fi
    LB_STACK_SERVICE_CIDR="$(lb_stack_backend_cidr_to_service_cidr "${LB_STACK_BACKEND_CIDR}")"
    LB_STACK_SERVICE_CIDR_SOURCE='derived'
    LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE}"

    template_stack_validate_k8s_name "${LB_STACK_NAMESPACE}" "lb namespace"
    template_stack_validate_k8s_name "${LB_STACK_NETWORK_SERVICE_NAME}" "lb network service name"
    lb_stack_resolve_role_node "lb VNF" "${requested_vnf_node}" "" "" LB_STACK_VNF_NODE LB_STACK_VNF_NODE_SOURCE LB_STACK_VNF_NODE_ORIGIN_SOURCE
    lb_stack_resolve_role_node "lb client" "${requested_client_node}" "" "" LB_STACK_CLIENT_NODE LB_STACK_CLIENT_NODE_SOURCE LB_STACK_CLIENT_NODE_ORIGIN_SOURCE
    lb_stack_resolve_role_node "lb server" "${requested_server_node}" "" "" LB_STACK_SERVER_NODE LB_STACK_SERVER_NODE_SOURCE LB_STACK_SERVER_NODE_ORIGIN_SOURCE
    lb_stack_set_derived_values
    lb_stack_assert_no_conflicts
    lb_stack_write_state
}

lb_stack_require_existing_state() {
    local state_file

    lb_stack_require_id
    state_file="$(lb_stack_state_file "${LB_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "lb stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-lb-plan --stack-id ${LB_STACK_ID} or deploy-lb --stack-id ${LB_STACK_ID} first"
}

lb_stack_write_resolved_values() {
    cat > "${LB_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${LB_STACK_ID}
STACK_NAMESPACE=${LB_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${LB_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${LB_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${LB_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${LB_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
SERVICE_CIDR=${LB_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR=${LB_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${LB_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
BACKEND_CIDR=${LB_STACK_BACKEND_CIDR}
BACKEND_CIDR_SOURCE=${LB_STACK_BACKEND_CIDR_SOURCE}
BACKEND_CIDR_ORIGIN_SOURCE=${LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${LB_STACK_LABEL}
STACK_LABEL_KEY=${LB_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${LB_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${LB_ROLE_LABEL_KEY}
ROLE_CLIENT=${LB_ROLE_CLIENT}
ROLE_MIDDLE=${LB_ROLE_MIDDLE}
ROLE_SERVER=${LB_ROLE_SERVER}
LB_DEPLOYMENT_NAME=${LB_STACK_MIDDLE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${LB_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${LB_STACK_CLIENT_DEPLOYMENT_NAME}
RULES_CONFIGMAP_NAME=${LB_STACK_RULES_CONFIGMAP_NAME}
RULES_CIDR_PATCH_ENABLED=${LB_STACK_RULES_CIDR_PATCH_ENABLED}
LB_POD_SELECTOR=${LB_STACK_MIDDLE_POD_SELECTOR}
SERVER_POD_SELECTOR=${LB_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${LB_STACK_CLIENT_POD_SELECTOR}
LB_NSM_LABELS=${LB_STACK_MIDDLE_NSM_LABELS}
SERVER_NSM_LABELS=${LB_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${LB_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${LB_STACK_SERVER_IPV4}
BACKEND_IPV4=${LB_STACK_BACKEND_IPV4}
VIP_IPV4=${LB_STACK_VIP_IPV4}
LB_STEERING_MODE=${LB_STEERING_MODE}
LB_STEERING_MODE_SOURCE=${PLATFORM_VALUE_SOURCE[LB_STEERING_MODE]}
VNF_NODE=${LB_STACK_VNF_NODE}
VNF_NODE_SOURCE=${LB_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${LB_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${LB_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${LB_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${LB_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${LB_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${LB_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${LB_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${LB_STACK_STATE_FILE}
GENERATED_DIR=${LB_STACK_GENERATED_DIR}
CIDR_POOL=${LB_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${LB_STACK_CIDR_PREFIX_LEN}
EOF
}

lb_stack_write_kustomization() {
    cat > "${LB_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${LB_STACK_NAMESPACE}

resources:
  - ../../../assets/lb/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-lb
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-lb
  - path: patches/15-lb-rules.yaml
    target:
      version: v1
      kind: ConfigMap
      name: nse-ovs-lb-rules
  - path: patches/20-nse-ovs-lb.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-lb
  - path: patches/30-nse-ovs-server.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-server
  - path: patches/40-nsc-ovs-client.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nsc-ovs-client
EOF
}

lb_stack_write_namespace_patch() {
    cat > "${LB_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${LB_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

lb_stack_write_networkservice_patch() {
    cat > "${LB_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${LB_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${LB_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
        ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
            ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
            ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_MIDDLE}
EOF
}

lb_stack_write_rules_patch() {
    cat > "${LB_STACK_PATCH_DIR}/15-lb-rules.yaml" <<EOF
- op: replace
  path: /metadata/namespace
  value: ${LB_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /data/rules.yaml
  value: |-
    mode: static_one_to_one
    vip: ${LB_STACK_VIP_IPV4}
    backend_ip: ${LB_STACK_BACKEND_IPV4}
EOF
}

lb_stack_write_lb_patch() {
    cat > "${LB_STACK_PATCH_DIR}/20-nse-ovs-lb.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${LB_STACK_MIDDLE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${LB_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${LB_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${LB_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${LB_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${LB_STACK_VNF_NODE}
- op: replace
  path: /spec/template/spec/containers/0/env
  value:
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: NSM_NAME
      value: "\$(POD_NAME)"
    - name: NSM_SERVICE_NAME
      value: ${LB_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${LB_STACK_MIDDLE_NSM_LABELS}
    - name: NSM_LB_RULES_PATH
      value: /etc/nse-lb/rules.yaml
    - name: NSM_LB_RULE_POLL_INTERVAL
      value: 2s
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

lb_stack_write_server_patch() {
    cat > "${LB_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${LB_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${LB_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${LB_STACK_SERVER_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${LB_STACK_SERVER_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${LB_STACK_SERVER_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${LB_STACK_SERVER_NODE}
- op: replace
  path: /spec/template/spec/containers/0/env
  value:
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: NSM_NAME
      value: "\$(POD_NAME)"
    - name: NSM_CIDR_PREFIX
      value: ${LB_STACK_BACKEND_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${LB_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${LB_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "5201"
EOF
}

lb_stack_write_client_patch() {
    cat > "${LB_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${LB_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${LB_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${LB_STACK_CLIENT_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${LB_STACK_CLIENT_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${LB_STACK_CLIENT_DEPLOYMENT_NAME}
    ${LB_STACK_LABEL_KEY}: ${LB_STACK_ID}
    ${LB_ROLE_LABEL_KEY}: ${LB_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${LB_STACK_CLIENT_NODE}
- op: replace
  path: /spec/template/spec/initContainers/0/env
  value:
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: NSM_NETWORK_SERVICES
      value: ${LB_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
- op: replace
  path: /spec/template/spec/containers/1/env
  value:
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_LIVENESS_CHECK_ENABLED
      value: "false"
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: NSM_NETWORK_SERVICES
      value: ${LB_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

lb_stack_render() {
    rm -rf "${LB_STACK_GENERATED_DIR}"
    mkdir -p "${LB_STACK_PATCH_DIR}"

    lb_stack_write_kustomization
    lb_stack_write_namespace_patch
    lb_stack_write_networkservice_patch
    lb_stack_write_rules_patch
    lb_stack_write_lb_patch
    lb_stack_write_server_patch
    lb_stack_write_client_patch
    lb_stack_write_resolved_values
}

lb_stack_apply_runtime_context() {
    LB_RUNTIME_ROOT="${LB_STACK_GENERATED_DIR}"
    LB_K8S_DIR="${LB_STACK_GENERATED_DIR}"
    LB_VERIFY_SCRIPT="${LB_VERIFY_ASSET_SCRIPT}"
    LB_NAMESPACE="${LB_STACK_NAMESPACE}"
    LB_NETWORK_SERVICE_NAME="${LB_STACK_NETWORK_SERVICE_NAME}"
    LB_DEPLOYMENT_NAME="${LB_STACK_MIDDLE_DEPLOYMENT_NAME}"
    LB_SERVER_DEPLOYMENT_NAME="${LB_STACK_SERVER_DEPLOYMENT_NAME}"
    LB_CLIENT_DEPLOYMENT_NAME="${LB_STACK_CLIENT_DEPLOYMENT_NAME}"
    LB_SERVICE_NAME="${LB_STACK_NETWORK_SERVICE_NAME}"
    LB_SERVER_CIDR_PREFIX="${LB_STACK_BACKEND_CIDR}"
    LB_SERVER_IPV4="${LB_STACK_SERVER_IPV4}"
    LB_BACKEND_IPV4="${LB_STACK_BACKEND_IPV4}"
    LB_VIP_IPV4="${LB_STACK_VIP_IPV4}"
    LB_MIDDLE_POD_SELECTOR="${LB_STACK_MIDDLE_POD_SELECTOR}"
    LB_SERVER_POD_SELECTOR="${LB_STACK_SERVER_POD_SELECTOR}"
    LB_CLIENT_POD_SELECTOR="${LB_STACK_CLIENT_POD_SELECTOR}"
}

lb_stack_prepare_rendered_runtime() {
    lb_init_runtime_context
    lb_require_runtime_assets
    lb_stack_prepare_plan
    lb_stack_render
    lb_stack_apply_runtime_context
}

lb_stack_prepare_existing_rendered_runtime() {
    lb_init_runtime_context
    lb_require_runtime_assets
    lb_stack_require_existing_state
    lb_stack_prepare_plan
    lb_stack_render
    lb_stack_apply_runtime_context
}

lb_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${LB_STACK_ID}"
    printf 'state file: %s\n' "${LB_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${LB_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${LB_STACK_NAMESPACE}" "${LB_STACK_NAMESPACE_SOURCE}" "${LB_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${LB_STACK_NETWORK_SERVICE_NAME}" "${LB_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${LB_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${LB_STACK_SERVICE_CIDR}" "${LB_STACK_SERVICE_CIDR_SOURCE}" "${LB_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'backend_cidr: %s [source=%s origin=%s]\n' "${LB_STACK_BACKEND_CIDR}" "${LB_STACK_BACKEND_CIDR_SOURCE}" "${LB_STACK_BACKEND_CIDR_ORIGIN_SOURCE}"
    printf 'stack_label: %s [source=derived]\n' "${LB_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${LB_ROLE_LABEL_KEY}" "${LB_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${LB_ROLE_LABEL_KEY}" "${LB_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${LB_ROLE_LABEL_KEY}" "${LB_ROLE_SERVER}"
    printf 'lb deployment: %s [source=derived]\n' "${LB_STACK_MIDDLE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${LB_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${LB_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'rules configmap: %s [source=derived]\n' "${LB_STACK_RULES_CONFIGMAP_NAME}"
    printf 'rules rules.yaml cidr patch: %s [source=derived]\n' "${LB_STACK_RULES_CIDR_PATCH_ENABLED}"
    printf 'lb rules.backend_ip: %s [source=derived]\n' "${LB_STACK_BACKEND_IPV4}"
    printf 'lb rules.vip: %s [source=derived]\n' "${LB_STACK_VIP_IPV4}"
    printf 'lb steering mode: %s [source=%s]\n' "${LB_STEERING_MODE}" "${PLATFORM_VALUE_SOURCE[LB_STEERING_MODE]}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${LB_STACK_VNF_NODE}" "${LB_STACK_VNF_NODE_SOURCE}" "${LB_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${LB_STACK_CLIENT_NODE}" "${LB_STACK_CLIENT_NODE_SOURCE}" "${LB_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${LB_STACK_SERVER_NODE}" "${LB_STACK_SERVER_NODE_SOURCE}" "${LB_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'lb env.NSM_SERVICE_NAME: %s [source=derived]\n' "${LB_STACK_NETWORK_SERVICE_NAME}"
    printf 'lb env.NSM_LABELS: %s [source=derived]\n' "${LB_STACK_MIDDLE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${LB_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${LB_STACK_BACKEND_CIDR}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${LB_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${LB_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${LB_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
}
