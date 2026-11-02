#!/usr/bin/env bash

if [[ -n "${NSM_OVS_FIREWALL_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_FIREWALL_STACK_SH_LOADED=1

FIREWALL_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${FIREWALL_STACK_LIB_DIR}/template_stack.sh"

firewall_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|firewall)
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

firewall_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == fw-* && "${stack_id#fw-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#fw-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

firewall_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

firewall_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(firewall_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-firewall-%s\n' "${suffix}"
}

firewall_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${FIREWALL_STACK_STATE_ROOT}" "${stack_id}"
}

firewall_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${FIREWALL_GENERATED_ROOT}" "${stack_id}"
}

firewall_stack_plan_dirs() {
    mkdir -p "${FIREWALL_STACK_STATE_ROOT}" "${FIREWALL_GENERATED_ROOT}"
}

firewall_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(firewall_stack_name_suffix "${FIREWALL_STACK_ID}")"

    FIREWALL_STACK_LABEL_KEY='exp.nsm.ai/stack'
    FIREWALL_ROLE_LABEL_KEY='exp.nsm.ai/role'
    FIREWALL_STACK_LABEL_VALUE="${FIREWALL_STACK_ID}"
    FIREWALL_STACK_LABEL="${FIREWALL_STACK_LABEL_KEY}=${FIREWALL_STACK_LABEL_VALUE}"

    FIREWALL_ROLE_CLIENT='client'
    FIREWALL_ROLE_MIDDLE='middle'
    FIREWALL_ROLE_SERVER='server'

    FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME="nse-ovs-firewall-${name_suffix}"
    FIREWALL_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"
    FIREWALL_STACK_RULES_CONFIGMAP_NAME='nse-ovs-firewall-rules'

    FIREWALL_STACK_MIDDLE_POD_SELECTOR="${FIREWALL_STACK_LABEL_KEY}=${FIREWALL_STACK_ID},${FIREWALL_ROLE_LABEL_KEY}=${FIREWALL_ROLE_MIDDLE}"
    FIREWALL_STACK_SERVER_POD_SELECTOR="${FIREWALL_STACK_LABEL_KEY}=${FIREWALL_STACK_ID},${FIREWALL_ROLE_LABEL_KEY}=${FIREWALL_ROLE_SERVER}"
    FIREWALL_STACK_CLIENT_POD_SELECTOR="${FIREWALL_STACK_LABEL_KEY}=${FIREWALL_STACK_ID},${FIREWALL_ROLE_LABEL_KEY}=${FIREWALL_ROLE_CLIENT}"

    FIREWALL_STACK_MIDDLE_NSM_LABELS="${FIREWALL_STACK_LABEL_KEY}:${FIREWALL_STACK_ID},${FIREWALL_ROLE_LABEL_KEY}:${FIREWALL_ROLE_MIDDLE}"
    FIREWALL_STACK_SERVER_NSM_LABELS="${FIREWALL_STACK_LABEL_KEY}:${FIREWALL_STACK_ID},${FIREWALL_ROLE_LABEL_KEY}:${FIREWALL_ROLE_SERVER}"
    FIREWALL_STACK_CLIENT_NETWORK_SERVICES="kernel://${FIREWALL_STACK_NETWORK_SERVICE_NAME}/nsm-1"
    FIREWALL_STACK_SERVER_IPV4="${FIREWALL_STACK_SERVICE_CIDR%%/*}"

    FIREWALL_STACK_STATE_FILE="$(firewall_stack_state_file "${FIREWALL_STACK_ID}")"
    FIREWALL_STACK_GENERATED_DIR="$(firewall_stack_generated_dir_for "${FIREWALL_STACK_ID}")"
    FIREWALL_STACK_PATCH_DIR="${FIREWALL_STACK_GENERATED_DIR}/patches"
    FIREWALL_STACK_RESOLVED_VALUES_FILE="${FIREWALL_STACK_GENERATED_DIR}/resolved-values.env"
}

firewall_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(firewall_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

firewall_stack_assert_no_conflicts() {
    local other_stack_id other_namespace other_network_service other_cidr
    local range_index
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()

    template_stack_collect_other_state_details \
        "$(firewall_stack_state_file "${FIREWALL_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for (( range_index = 0; range_index < ${#other_state_files[@]}; range_index++ )); do
        other_stack_id="${other_stack_ids[range_index]}"
        other_namespace="${other_namespaces[range_index]}"
        other_network_service="${other_network_services[range_index]}"
        other_cidr="${other_cidrs[range_index]}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${FIREWALL_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "firewall namespace ${FIREWALL_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${FIREWALL_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "firewall network service ${FIREWALL_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        if [[ -n "${other_cidr}" ]] && template_stack_cidrs_overlap "${FIREWALL_STACK_SERVICE_CIDR}" "${other_cidr}"; then
            die "firewall service CIDR ${FIREWALL_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
        fi
    done
}

firewall_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr
    local candidate_end_int pool_end_int subnet_size subnet_count index other_cidr
    local range_index conflict highest_used_end fast_candidate_int fast_candidate_end last_range_index
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid firewall CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "firewall CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))
    pool_end_int=$(( pool_network_int + subnet_size * subnet_count - 1 ))
    highest_used_end=$(( pool_network_int - 1 ))

    template_stack_collect_other_state_details \
        "$(firewall_stack_state_file "${FIREWALL_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for other_cidr in "${other_cidrs[@]}"; do
        [[ -n "${other_cidr}" ]] || continue
        other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
        other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
        last_range_index=$(( ${#other_range_starts[@]} - 1 ))

        if (( other_range_starts[last_range_index] <= pool_end_int && other_range_ends[last_range_index] >= pool_network_int && other_range_ends[last_range_index] > highest_used_end )); then
            highest_used_end=${other_range_ends[last_range_index]}
        fi
    done

    if (( highest_used_end >= pool_network_int )); then
        fast_candidate_int=$(( ((highest_used_end + 1 + subnet_size - 1) / subnet_size) * subnet_size ))
        if (( fast_candidate_int < pool_network_int )); then
            fast_candidate_int=${pool_network_int}
        fi

        fast_candidate_end=$(( fast_candidate_int + subnet_size - 1 ))
        if (( fast_candidate_end <= pool_end_int )); then
            conflict=false
            for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
                if (( fast_candidate_int <= other_range_ends[range_index] && other_range_starts[range_index] <= fast_candidate_end )); then
                    conflict=true
                    break
                fi
            done

            if [[ "${conflict}" == "false" ]]; then
                candidate_cidr="$(template_stack_int_to_ipv4 "${fast_candidate_int}")/${target_prefix_len}"
                printf '%s\n' "${candidate_cidr}"
                return 0
            fi
        fi
    fi

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free firewall service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

firewall_stack_resolve_role_node() {
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
        resolved_value="$(firewall_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

firewall_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(firewall_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    FIREWALL_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    FIREWALL_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    FIREWALL_STACK_NAMESPACE_SOURCE='persisted'
    FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    FIREWALL_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    FIREWALL_STACK_SERVICE_CIDR_SOURCE='persisted'
    FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    FIREWALL_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    FIREWALL_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    FIREWALL_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    FIREWALL_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    FIREWALL_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    FIREWALL_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    FIREWALL_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    FIREWALL_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${FIREWALL_STACK_NAMESPACE}" ]] || die "persisted firewall stack namespace missing in ${state_file}"
    [[ -n "${FIREWALL_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted firewall stack network service missing in ${state_file}"
    [[ -n "${FIREWALL_STACK_SERVICE_CIDR}" ]] || die "persisted firewall stack service CIDR missing in ${state_file}"

    firewall_stack_set_derived_values
    return 0
}

firewall_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${FIREWALL_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${FIREWALL_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${FIREWALL_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

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

    cat > "${FIREWALL_STACK_STATE_FILE}" <<EOF
STACK_ID=${FIREWALL_STACK_ID}
STACK_NAMESPACE=${FIREWALL_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${FIREWALL_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${FIREWALL_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${FIREWALL_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${FIREWALL_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${FIREWALL_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${FIREWALL_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${FIREWALL_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    FIREWALL_STACK_STATE_CREATED_AT="${created_at}"
    FIREWALL_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    FIREWALL_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

firewall_stack_require_id() {
    FIREWALL_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${FIREWALL_STACK_ID}" ]] || die "missing required --stack-id for firewall stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "firewall stack operation requires an explicit --stack-id"
    template_stack_validate_id "${FIREWALL_STACK_ID}"
}

firewall_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    firewall_stack_plan_dirs
    firewall_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "firewall namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "firewall network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "firewall VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "firewall client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "firewall server node override"
    fi

    if firewall_stack_load_state "${FIREWALL_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${FIREWALL_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${FIREWALL_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "service_cidr" "${requested_cidr}" "${FIREWALL_STACK_SERVICE_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${FIREWALL_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${FIREWALL_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${FIREWALL_STACK_SERVER_NODE_PERSISTED:-}"
        firewall_stack_resolve_role_node "firewall VNF" "${requested_vnf_node}" "${FIREWALL_STACK_VNF_NODE_PERSISTED:-}" "${FIREWALL_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" FIREWALL_STACK_VNF_NODE FIREWALL_STACK_VNF_NODE_SOURCE FIREWALL_STACK_VNF_NODE_ORIGIN_SOURCE
        firewall_stack_resolve_role_node "firewall client" "${requested_client_node}" "${FIREWALL_STACK_CLIENT_NODE_PERSISTED:-}" "${FIREWALL_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" FIREWALL_STACK_CLIENT_NODE FIREWALL_STACK_CLIENT_NODE_SOURCE FIREWALL_STACK_CLIENT_NODE_ORIGIN_SOURCE
        firewall_stack_resolve_role_node "firewall server" "${requested_server_node}" "${FIREWALL_STACK_SERVER_NODE_PERSISTED:-}" "${FIREWALL_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" FIREWALL_STACK_SERVER_NODE FIREWALL_STACK_SERVER_NODE_SOURCE FIREWALL_STACK_SERVER_NODE_ORIGIN_SOURCE
        return 0
    fi

    FIREWALL_STACK_NAMESPACE="${requested_namespace:-$(firewall_stack_default_namespace "${FIREWALL_STACK_ID}")}"
    FIREWALL_STACK_NAMESPACE_SOURCE='default'
    FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        FIREWALL_STACK_NAMESPACE_SOURCE='override'
        FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    FIREWALL_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(firewall_stack_default_network_service_name "${FIREWALL_STACK_ID}")}"
    FIREWALL_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        FIREWALL_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    FIREWALL_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    FIREWALL_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        FIREWALL_STACK_SERVICE_CIDR="${requested_cidr}"
        FIREWALL_STACK_SERVICE_CIDR_SOURCE='override'
        FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE='override'
    else
        FIREWALL_STACK_SERVICE_CIDR="$(firewall_stack_allocate_cidr "${FIREWALL_STACK_CIDR_POOL}" "${FIREWALL_STACK_CIDR_PREFIX_LEN}")"
        FIREWALL_STACK_SERVICE_CIDR_SOURCE='allocated'
        FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE='allocated'
    fi

    template_stack_validate_k8s_name "${FIREWALL_STACK_NAMESPACE}" "firewall namespace"
    template_stack_validate_k8s_name "${FIREWALL_STACK_NETWORK_SERVICE_NAME}" "firewall network service name"
    firewall_stack_resolve_role_node "firewall VNF" "${requested_vnf_node}" "" "" FIREWALL_STACK_VNF_NODE FIREWALL_STACK_VNF_NODE_SOURCE FIREWALL_STACK_VNF_NODE_ORIGIN_SOURCE
    firewall_stack_resolve_role_node "firewall client" "${requested_client_node}" "" "" FIREWALL_STACK_CLIENT_NODE FIREWALL_STACK_CLIENT_NODE_SOURCE FIREWALL_STACK_CLIENT_NODE_ORIGIN_SOURCE
    firewall_stack_resolve_role_node "firewall server" "${requested_server_node}" "" "" FIREWALL_STACK_SERVER_NODE FIREWALL_STACK_SERVER_NODE_SOURCE FIREWALL_STACK_SERVER_NODE_ORIGIN_SOURCE
    firewall_stack_set_derived_values
    firewall_stack_assert_no_conflicts
    firewall_stack_write_state
}

firewall_stack_require_existing_state() {
    local state_file

    firewall_stack_require_id
    state_file="$(firewall_stack_state_file "${FIREWALL_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "firewall stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-firewall-plan --stack-id ${FIREWALL_STACK_ID} or deploy-firewall --stack-id ${FIREWALL_STACK_ID} first"
}

firewall_stack_write_resolved_values() {
    cat > "${FIREWALL_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${FIREWALL_STACK_ID}
STACK_NAMESPACE=${FIREWALL_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${FIREWALL_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${FIREWALL_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${FIREWALL_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${FIREWALL_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${FIREWALL_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${FIREWALL_STACK_LABEL}
STACK_LABEL_KEY=${FIREWALL_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${FIREWALL_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${FIREWALL_ROLE_LABEL_KEY}
ROLE_CLIENT=${FIREWALL_ROLE_CLIENT}
ROLE_MIDDLE=${FIREWALL_ROLE_MIDDLE}
ROLE_SERVER=${FIREWALL_ROLE_SERVER}
FIREWALL_DEPLOYMENT_NAME=${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}
RULES_CONFIGMAP_NAME=${FIREWALL_STACK_RULES_CONFIGMAP_NAME}
FIREWALL_POD_SELECTOR=${FIREWALL_STACK_MIDDLE_POD_SELECTOR}
SERVER_POD_SELECTOR=${FIREWALL_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${FIREWALL_STACK_CLIENT_POD_SELECTOR}
FIREWALL_NSM_LABELS=${FIREWALL_STACK_MIDDLE_NSM_LABELS}
SERVER_NSM_LABELS=${FIREWALL_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${FIREWALL_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${FIREWALL_STACK_SERVER_IPV4}
VNF_NODE=${FIREWALL_STACK_VNF_NODE}
VNF_NODE_SOURCE=${FIREWALL_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${FIREWALL_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${FIREWALL_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${FIREWALL_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${FIREWALL_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${FIREWALL_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${FIREWALL_STACK_STATE_FILE}
GENERATED_DIR=${FIREWALL_STACK_GENERATED_DIR}
CIDR_POOL=${FIREWALL_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${FIREWALL_STACK_CIDR_PREFIX_LEN}
EOF
}

firewall_stack_write_kustomization() {
    cat > "${FIREWALL_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${FIREWALL_STACK_NAMESPACE}

resources:
  - ../../../assets/firewall/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-firewall
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-firewall
  - path: patches/15-firewall-rules.yaml
    target:
      version: v1
      kind: ConfigMap
      name: nse-ovs-firewall-rules
  - path: patches/20-nse-ovs-firewall.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-firewall
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

firewall_stack_write_namespace_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${FIREWALL_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

firewall_stack_write_networkservice_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${FIREWALL_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${FIREWALL_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
        ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
            ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
            ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_MIDDLE}
EOF
}

firewall_stack_write_rules_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/15-firewall-rules.yaml" <<EOF
- op: replace
  path: /metadata/namespace
  value: ${FIREWALL_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /data/rules.yaml
  value: |-
    mode: allowlist
    rules:
      - name: allow-icmp
        left_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        right_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        protocol: icmp
      - name: allow-tcp-5201
        left_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        right_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        protocol: tcp
        dst_ports:
          - 5201
      - name: allow-udp-5201
        left_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        right_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        protocol: udp
        dst_ports:
          - 5201
      - name: allow-tcp-8080
        left_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        right_cidrs:
          - ${FIREWALL_STACK_SERVICE_CIDR}
        protocol: tcp
        dst_ports:
          - 8080
EOF
}

firewall_stack_write_firewall_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/20-nse-ovs-firewall.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${FIREWALL_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${FIREWALL_STACK_VNF_NODE}
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
      value: ${FIREWALL_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${FIREWALL_STACK_MIDDLE_NSM_LABELS}
    - name: NSM_FIREWALL_RULES_PATH
      value: /etc/nse-firewall/rules.yaml
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

firewall_stack_write_server_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${FIREWALL_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${FIREWALL_STACK_SERVER_NODE}
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
      value: ${FIREWALL_STACK_SERVICE_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${FIREWALL_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${FIREWALL_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "5201"
EOF
}

firewall_stack_write_client_patch() {
    cat > "${FIREWALL_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${FIREWALL_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}
    ${FIREWALL_STACK_LABEL_KEY}: ${FIREWALL_STACK_ID}
    ${FIREWALL_ROLE_LABEL_KEY}: ${FIREWALL_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${FIREWALL_STACK_CLIENT_NODE}
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
      value: ${FIREWALL_STACK_CLIENT_NETWORK_SERVICES}
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
      value: ${FIREWALL_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

firewall_stack_render() {
    rm -rf "${FIREWALL_STACK_GENERATED_DIR}"
    mkdir -p "${FIREWALL_STACK_PATCH_DIR}"

    firewall_stack_write_kustomization
    firewall_stack_write_namespace_patch
    firewall_stack_write_networkservice_patch
    firewall_stack_write_rules_patch
    firewall_stack_write_firewall_patch
    firewall_stack_write_server_patch
    firewall_stack_write_client_patch
    firewall_stack_write_resolved_values
}

firewall_stack_apply_runtime_context() {
    FIREWALL_RUNTIME_ROOT="${FIREWALL_STACK_GENERATED_DIR}"
    FIREWALL_K8S_DIR="${FIREWALL_STACK_GENERATED_DIR}"
    FIREWALL_VERIFY_SCRIPT="${FIREWALL_VERIFY_ASSET_SCRIPT}"
    FIREWALL_NAMESPACE="${FIREWALL_STACK_NAMESPACE}"
    FIREWALL_NETWORK_SERVICE_NAME="${FIREWALL_STACK_NETWORK_SERVICE_NAME}"
    FIREWALL_DEPLOYMENT_NAME="${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}"
    FIREWALL_SERVER_DEPLOYMENT_NAME="${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}"
    FIREWALL_CLIENT_DEPLOYMENT_NAME="${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}"
    FIREWALL_SERVICE_NAME="${FIREWALL_STACK_NETWORK_SERVICE_NAME}"
    FIREWALL_SERVER_CIDR_PREFIX="${FIREWALL_STACK_SERVICE_CIDR}"
    FIREWALL_SERVER_IPV4="${FIREWALL_STACK_SERVER_IPV4}"
    FIREWALL_MIDDLE_POD_SELECTOR="${FIREWALL_STACK_MIDDLE_POD_SELECTOR}"
    FIREWALL_SERVER_POD_SELECTOR="${FIREWALL_STACK_SERVER_POD_SELECTOR}"
    FIREWALL_CLIENT_POD_SELECTOR="${FIREWALL_STACK_CLIENT_POD_SELECTOR}"
}

firewall_stack_prepare_rendered_runtime() {
    firewall_init_runtime_context
    firewall_require_runtime_assets
    firewall_stack_prepare_plan
    firewall_stack_render
    firewall_stack_apply_runtime_context
}

firewall_stack_prepare_existing_rendered_runtime() {
    firewall_init_runtime_context
    firewall_require_runtime_assets
    firewall_stack_require_existing_state
    firewall_stack_prepare_plan
    firewall_stack_render
    firewall_stack_apply_runtime_context
}

firewall_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${FIREWALL_STACK_ID}"
    printf 'state file: %s\n' "${FIREWALL_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${FIREWALL_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_NAMESPACE}" "${FIREWALL_STACK_NAMESPACE_SOURCE}" "${FIREWALL_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_NETWORK_SERVICE_NAME}" "${FIREWALL_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${FIREWALL_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_SERVICE_CIDR}" "${FIREWALL_STACK_SERVICE_CIDR_SOURCE}" "${FIREWALL_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'stack_label: %s [source=derived]\n' "${FIREWALL_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${FIREWALL_ROLE_LABEL_KEY}" "${FIREWALL_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${FIREWALL_ROLE_LABEL_KEY}" "${FIREWALL_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${FIREWALL_ROLE_LABEL_KEY}" "${FIREWALL_ROLE_SERVER}"
    printf 'firewall deployment: %s [source=derived]\n' "${FIREWALL_STACK_MIDDLE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${FIREWALL_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${FIREWALL_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'rules configmap: %s [source=derived]\n' "${FIREWALL_STACK_RULES_CONFIGMAP_NAME}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_VNF_NODE}" "${FIREWALL_STACK_VNF_NODE_SOURCE}" "${FIREWALL_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_CLIENT_NODE}" "${FIREWALL_STACK_CLIENT_NODE_SOURCE}" "${FIREWALL_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${FIREWALL_STACK_SERVER_NODE}" "${FIREWALL_STACK_SERVER_NODE_SOURCE}" "${FIREWALL_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'firewall env.NSM_SERVICE_NAME: %s [source=derived]\n' "${FIREWALL_STACK_NETWORK_SERVICE_NAME}"
    printf 'firewall env.NSM_LABELS: %s [source=derived]\n' "${FIREWALL_STACK_MIDDLE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${FIREWALL_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${FIREWALL_STACK_SERVICE_CIDR}"
    printf 'rules.yaml cidr: %s [source=derived]\n' "${FIREWALL_STACK_SERVICE_CIDR}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${FIREWALL_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${FIREWALL_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${FIREWALL_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
}
