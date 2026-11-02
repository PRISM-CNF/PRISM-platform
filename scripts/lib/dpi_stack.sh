#!/usr/bin/env bash

if [[ -n "${NSM_OVS_DPI_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_DPI_STACK_SH_LOADED=1

DPI_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${DPI_STACK_LIB_DIR}/template_stack.sh"

dpi_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|dpi)
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

dpi_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == dpi-* && "${stack_id#dpi-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#dpi-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

dpi_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

dpi_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(dpi_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-dpi-%s\n' "${suffix}"
}

dpi_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${DPI_STACK_STATE_ROOT}" "${stack_id}"
}

dpi_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${DPI_GENERATED_ROOT}" "${stack_id}"
}

dpi_stack_plan_dirs() {
    mkdir -p "${DPI_STACK_STATE_ROOT}" "${DPI_GENERATED_ROOT}"
}

dpi_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(dpi_stack_name_suffix "${DPI_STACK_ID}")"

    DPI_STACK_LABEL_KEY='exp.nsm.ai/stack'
    DPI_ROLE_LABEL_KEY='exp.nsm.ai/role'
    DPI_STACK_LABEL_VALUE="${DPI_STACK_ID}"
    DPI_STACK_LABEL="${DPI_STACK_LABEL_KEY}=${DPI_STACK_LABEL_VALUE}"

    DPI_ROLE_CLIENT='client'
    DPI_ROLE_MIDDLE='middle'
    DPI_ROLE_SERVER='server'

    DPI_STACK_MIDDLE_DEPLOYMENT_NAME="nse-ovs-dpi-${name_suffix}"
    DPI_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    DPI_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"
    DPI_STACK_RULES_CONFIGMAP_NAME='nse-ovs-dpi-rules'
    DPI_STACK_RULES_CIDR_PATCH_ENABLED='true'

    DPI_STACK_MIDDLE_POD_SELECTOR="${DPI_STACK_LABEL_KEY}=${DPI_STACK_ID},${DPI_ROLE_LABEL_KEY}=${DPI_ROLE_MIDDLE}"
    DPI_STACK_SERVER_POD_SELECTOR="${DPI_STACK_LABEL_KEY}=${DPI_STACK_ID},${DPI_ROLE_LABEL_KEY}=${DPI_ROLE_SERVER}"
    DPI_STACK_CLIENT_POD_SELECTOR="${DPI_STACK_LABEL_KEY}=${DPI_STACK_ID},${DPI_ROLE_LABEL_KEY}=${DPI_ROLE_CLIENT}"

    DPI_STACK_MIDDLE_NSM_LABELS="${DPI_STACK_LABEL_KEY}:${DPI_STACK_ID},${DPI_ROLE_LABEL_KEY}:${DPI_ROLE_MIDDLE}"
    DPI_STACK_SERVER_NSM_LABELS="${DPI_STACK_LABEL_KEY}:${DPI_STACK_ID},${DPI_ROLE_LABEL_KEY}:${DPI_ROLE_SERVER}"
    DPI_STACK_CLIENT_NETWORK_SERVICES="kernel://${DPI_STACK_NETWORK_SERVICE_NAME}/nsm-1"
    DPI_STACK_SERVER_IPV4="${DPI_STACK_SERVICE_CIDR%%/*}"

    DPI_STACK_STATE_FILE="$(dpi_stack_state_file "${DPI_STACK_ID}")"
    DPI_STACK_GENERATED_DIR="$(dpi_stack_generated_dir_for "${DPI_STACK_ID}")"
    DPI_STACK_PATCH_DIR="${DPI_STACK_GENERATED_DIR}/patches"
    DPI_STACK_RESOLVED_VALUES_FILE="${DPI_STACK_GENERATED_DIR}/resolved-values.env"
}

dpi_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(dpi_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

dpi_stack_assert_no_conflicts() {
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local -A state_map=()

    for state_file in $(dpi_stack_each_other_state "${DPI_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_stack_id="${state_map[STACK_ID]:-$(basename "${state_file}" .env)}"
        other_namespace="${state_map[STACK_NAMESPACE]:-}"
        other_network_service="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
        other_cidr="${state_map[STACK_SERVICE_CIDR]:-}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${DPI_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "dpi namespace ${DPI_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${DPI_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "dpi network service ${DPI_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        if [[ -n "${other_cidr}" ]] && template_stack_cidrs_overlap "${DPI_STACK_SERVICE_CIDR}" "${other_cidr}"; then
            die "dpi service CIDR ${DPI_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
        fi
    done
}

dpi_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr
    local candidate_end_int subnet_size subnet_count index other_cidr range_index
    local conflict
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid dpi CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "dpi CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))

    template_stack_collect_other_state_details \
        "$(dpi_stack_state_file "${DPI_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for other_cidr in "${other_cidrs[@]}"; do
        [[ -n "${other_cidr}" ]] || continue
        other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
        other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
    done

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free dpi service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

dpi_stack_resolve_role_node() {
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
        resolved_value="$(dpi_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

dpi_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(dpi_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    DPI_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    DPI_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    DPI_STACK_NAMESPACE_SOURCE='persisted'
    DPI_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    DPI_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    DPI_STACK_SERVICE_CIDR_SOURCE='persisted'
    DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    DPI_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    DPI_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    DPI_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    DPI_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    DPI_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    DPI_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    DPI_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    DPI_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${DPI_STACK_NAMESPACE}" ]] || die "persisted dpi stack namespace missing in ${state_file}"
    [[ -n "${DPI_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted dpi stack network service missing in ${state_file}"
    [[ -n "${DPI_STACK_SERVICE_CIDR}" ]] || die "persisted dpi stack service CIDR missing in ${state_file}"

    dpi_stack_set_derived_values
    return 0
}

dpi_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${DPI_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${DPI_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${DPI_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

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

    cat > "${DPI_STACK_STATE_FILE}" <<EOF
STACK_ID=${DPI_STACK_ID}
STACK_NAMESPACE=${DPI_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${DPI_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${DPI_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${DPI_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${DPI_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${DPI_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${DPI_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${DPI_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${DPI_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${DPI_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${DPI_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${DPI_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    DPI_STACK_STATE_CREATED_AT="${created_at}"
    DPI_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    DPI_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

dpi_stack_require_id() {
    DPI_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${DPI_STACK_ID}" ]] || die "missing required --stack-id for dpi stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "dpi stack operation requires an explicit --stack-id"
    template_stack_validate_id "${DPI_STACK_ID}"
}

dpi_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    dpi_stack_plan_dirs
    dpi_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "dpi namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "dpi network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "dpi VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "dpi client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "dpi server node override"
    fi

    if dpi_stack_load_state "${DPI_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${DPI_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${DPI_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "service_cidr" "${requested_cidr}" "${DPI_STACK_SERVICE_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${DPI_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${DPI_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${DPI_STACK_SERVER_NODE_PERSISTED:-}"
        dpi_stack_resolve_role_node "dpi VNF" "${requested_vnf_node}" "${DPI_STACK_VNF_NODE_PERSISTED:-}" "${DPI_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" DPI_STACK_VNF_NODE DPI_STACK_VNF_NODE_SOURCE DPI_STACK_VNF_NODE_ORIGIN_SOURCE
        dpi_stack_resolve_role_node "dpi client" "${requested_client_node}" "${DPI_STACK_CLIENT_NODE_PERSISTED:-}" "${DPI_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" DPI_STACK_CLIENT_NODE DPI_STACK_CLIENT_NODE_SOURCE DPI_STACK_CLIENT_NODE_ORIGIN_SOURCE
        dpi_stack_resolve_role_node "dpi server" "${requested_server_node}" "${DPI_STACK_SERVER_NODE_PERSISTED:-}" "${DPI_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" DPI_STACK_SERVER_NODE DPI_STACK_SERVER_NODE_SOURCE DPI_STACK_SERVER_NODE_ORIGIN_SOURCE
        return 0
    fi

    DPI_STACK_NAMESPACE="${requested_namespace:-$(dpi_stack_default_namespace "${DPI_STACK_ID}")}"
    DPI_STACK_NAMESPACE_SOURCE='default'
    DPI_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        DPI_STACK_NAMESPACE_SOURCE='override'
        DPI_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    DPI_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(dpi_stack_default_network_service_name "${DPI_STACK_ID}")}"
    DPI_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        DPI_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    DPI_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    DPI_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        DPI_STACK_SERVICE_CIDR="${requested_cidr}"
        DPI_STACK_SERVICE_CIDR_SOURCE='override'
        DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE='override'
    else
        DPI_STACK_SERVICE_CIDR="$(dpi_stack_allocate_cidr "${DPI_STACK_CIDR_POOL}" "${DPI_STACK_CIDR_PREFIX_LEN}")"
        DPI_STACK_SERVICE_CIDR_SOURCE='allocated'
        DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE='allocated'
    fi

    template_stack_validate_k8s_name "${DPI_STACK_NAMESPACE}" "dpi namespace"
    template_stack_validate_k8s_name "${DPI_STACK_NETWORK_SERVICE_NAME}" "dpi network service name"
    dpi_stack_resolve_role_node "dpi VNF" "${requested_vnf_node}" "" "" DPI_STACK_VNF_NODE DPI_STACK_VNF_NODE_SOURCE DPI_STACK_VNF_NODE_ORIGIN_SOURCE
    dpi_stack_resolve_role_node "dpi client" "${requested_client_node}" "" "" DPI_STACK_CLIENT_NODE DPI_STACK_CLIENT_NODE_SOURCE DPI_STACK_CLIENT_NODE_ORIGIN_SOURCE
    dpi_stack_resolve_role_node "dpi server" "${requested_server_node}" "" "" DPI_STACK_SERVER_NODE DPI_STACK_SERVER_NODE_SOURCE DPI_STACK_SERVER_NODE_ORIGIN_SOURCE
    dpi_stack_set_derived_values
    dpi_stack_assert_no_conflicts
    dpi_stack_write_state
}

dpi_stack_require_existing_state() {
    local state_file

    dpi_stack_require_id
    state_file="$(dpi_stack_state_file "${DPI_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "dpi stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-dpi-plan --stack-id ${DPI_STACK_ID} or deploy-dpi --stack-id ${DPI_STACK_ID} first"
}

dpi_stack_write_resolved_values() {
    cat > "${DPI_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${DPI_STACK_ID}
STACK_NAMESPACE=${DPI_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${DPI_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${DPI_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${DPI_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${DPI_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${DPI_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${DPI_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${DPI_STACK_LABEL}
STACK_LABEL_KEY=${DPI_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${DPI_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${DPI_ROLE_LABEL_KEY}
ROLE_CLIENT=${DPI_ROLE_CLIENT}
ROLE_MIDDLE=${DPI_ROLE_MIDDLE}
ROLE_SERVER=${DPI_ROLE_SERVER}
DPI_DEPLOYMENT_NAME=${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${DPI_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${DPI_STACK_CLIENT_DEPLOYMENT_NAME}
RULES_CONFIGMAP_NAME=${DPI_STACK_RULES_CONFIGMAP_NAME}
RULES_CIDR_PATCH_ENABLED=${DPI_STACK_RULES_CIDR_PATCH_ENABLED}
DPI_POD_SELECTOR=${DPI_STACK_MIDDLE_POD_SELECTOR}
SERVER_POD_SELECTOR=${DPI_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${DPI_STACK_CLIENT_POD_SELECTOR}
DPI_NSM_LABELS=${DPI_STACK_MIDDLE_NSM_LABELS}
SERVER_NSM_LABELS=${DPI_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${DPI_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${DPI_STACK_SERVER_IPV4}
VNF_NODE=${DPI_STACK_VNF_NODE}
VNF_NODE_SOURCE=${DPI_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${DPI_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${DPI_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${DPI_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${DPI_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${DPI_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${DPI_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${DPI_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${DPI_STACK_STATE_FILE}
GENERATED_DIR=${DPI_STACK_GENERATED_DIR}
CIDR_POOL=${DPI_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${DPI_STACK_CIDR_PREFIX_LEN}
EOF
}

dpi_stack_write_kustomization() {
    cat > "${DPI_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${DPI_STACK_NAMESPACE}

resources:
  - ../../../assets/dpi/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-dpi
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-dpi
  - path: patches/15-dpi-rules.yaml
    target:
      version: v1
      kind: ConfigMap
      name: nse-ovs-dpi-rules
  - path: patches/20-nse-ovs-dpi.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-dpi
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

dpi_stack_write_namespace_patch() {
    cat > "${DPI_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${DPI_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

dpi_stack_write_networkservice_patch() {
    cat > "${DPI_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${DPI_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${DPI_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
        ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
            ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
            ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_MIDDLE}
EOF
}

dpi_stack_upstream_server_cidr() {
    local server_manifest="${DPI_K8S_ASSETS_DIR}/30-nse-ovs-server.yaml"

    [[ -f "${server_manifest}" ]] || return 0

    awk '
        $1 == "-" && $2 == "name:" && $3 == "NSM_CIDR_PREFIX" {
            found = 1
            next
        }
        found && $1 == "value:" {
            print $2
            exit
        }
    ' "${server_manifest}"
}

dpi_stack_extract_rules_content() {
    local rules_file="${DPI_K8S_ASSETS_DIR}/15-dpi-rules.yaml"
    local upstream_server_cidr
    local rules_content

    [[ -f "${rules_file}" ]] || return 0

    rules_content="$(sed -n '/^  local\.rules: |$/,$p' "${rules_file}" | sed '1d;s/^    //')"
    upstream_server_cidr="$(dpi_stack_upstream_server_cidr)"

    if [[ -n "${upstream_server_cidr}" ]]; then
        rules_content="${rules_content//${upstream_server_cidr}/${DPI_STACK_SERVICE_CIDR}}"
    fi

    rules_content="${rules_content//__STACK_SERVICE_CIDR__/${DPI_STACK_SERVICE_CIDR}}"

    printf '%s\n' "${rules_content}"
}

dpi_stack_write_rules_patch() {
    local rules_content

    rules_content="$(dpi_stack_extract_rules_content)"

    {
        cat <<EOF
- op: replace
  path: /metadata/namespace
  value: ${DPI_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /data/local.rules
  value: |-
EOF
        while IFS= read -r line || [[ -n "${line}" ]]; do
            printf '    %s\n' "${line}"
        done <<< "${rules_content}"
    } > "${DPI_STACK_PATCH_DIR}/15-dpi-rules.yaml"
}

dpi_stack_write_dpi_patch() {
    cat > "${DPI_STACK_PATCH_DIR}/20-nse-ovs-dpi.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${DPI_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${DPI_STACK_VNF_NODE}
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
      value: ${DPI_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${DPI_STACK_MIDDLE_NSM_LABELS}
    - name: NSM_DPI_RULES_PATH
      value: /etc/nse-dpi/local.rules
    - name: NSM_DPI_SURICATA_CONFIG_PATH
      value: /etc/suricata/suricata.yaml
    - name: NSM_DPI_TEMP_ROOT
      value: /tmp/nse-ovs-dpi
    - name: NSM_DPI_RULE_POLL_INTERVAL
      value: 2s
    - name: NSM_DPI_HTTP_PORT
      value: "8080"
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

dpi_stack_write_server_patch() {
    cat > "${DPI_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${DPI_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${DPI_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${DPI_STACK_SERVER_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${DPI_STACK_SERVER_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${DPI_STACK_SERVER_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${DPI_STACK_SERVER_NODE}
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
      value: ${DPI_STACK_SERVICE_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${DPI_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${DPI_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "5201"
EOF
}

dpi_stack_write_client_patch() {
    cat > "${DPI_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${DPI_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${DPI_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${DPI_STACK_CLIENT_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${DPI_STACK_CLIENT_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${DPI_STACK_CLIENT_DEPLOYMENT_NAME}
    ${DPI_STACK_LABEL_KEY}: ${DPI_STACK_ID}
    ${DPI_ROLE_LABEL_KEY}: ${DPI_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${DPI_STACK_CLIENT_NODE}
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
      value: ${DPI_STACK_CLIENT_NETWORK_SERVICES}
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
      value: ${DPI_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

dpi_stack_render() {
    rm -rf "${DPI_STACK_GENERATED_DIR}"
    mkdir -p "${DPI_STACK_PATCH_DIR}"

    dpi_stack_write_kustomization
    dpi_stack_write_namespace_patch
    dpi_stack_write_networkservice_patch
    dpi_stack_write_rules_patch
    dpi_stack_write_dpi_patch
    dpi_stack_write_server_patch
    dpi_stack_write_client_patch
    dpi_stack_write_resolved_values
}

dpi_stack_apply_runtime_context() {
    DPI_RUNTIME_ROOT="${DPI_STACK_GENERATED_DIR}"
    DPI_K8S_DIR="${DPI_STACK_GENERATED_DIR}"
    DPI_VERIFY_SCRIPT="${DPI_VERIFY_ASSET_SCRIPT}"
    DPI_NAMESPACE="${DPI_STACK_NAMESPACE}"
    DPI_NETWORK_SERVICE_NAME="${DPI_STACK_NETWORK_SERVICE_NAME}"
    DPI_DEPLOYMENT_NAME="${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}"
    DPI_SERVER_DEPLOYMENT_NAME="${DPI_STACK_SERVER_DEPLOYMENT_NAME}"
    DPI_CLIENT_DEPLOYMENT_NAME="${DPI_STACK_CLIENT_DEPLOYMENT_NAME}"
    DPI_SERVICE_NAME="${DPI_STACK_NETWORK_SERVICE_NAME}"
    DPI_SERVER_CIDR_PREFIX="${DPI_STACK_SERVICE_CIDR}"
    DPI_SERVER_IPV4="${DPI_STACK_SERVER_IPV4}"
    DPI_MIDDLE_POD_SELECTOR="${DPI_STACK_MIDDLE_POD_SELECTOR}"
    DPI_SERVER_POD_SELECTOR="${DPI_STACK_SERVER_POD_SELECTOR}"
    DPI_CLIENT_POD_SELECTOR="${DPI_STACK_CLIENT_POD_SELECTOR}"
}

dpi_stack_prepare_rendered_runtime() {
    dpi_init_runtime_context
    dpi_require_runtime_assets
    dpi_stack_prepare_plan
    dpi_stack_render
    dpi_stack_apply_runtime_context
}

dpi_stack_prepare_existing_rendered_runtime() {
    dpi_init_runtime_context
    dpi_require_runtime_assets
    dpi_stack_require_existing_state
    dpi_stack_prepare_plan
    dpi_stack_render
    dpi_stack_apply_runtime_context
}

dpi_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${DPI_STACK_ID}"
    printf 'state file: %s\n' "${DPI_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${DPI_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${DPI_STACK_NAMESPACE}" "${DPI_STACK_NAMESPACE_SOURCE}" "${DPI_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${DPI_STACK_NETWORK_SERVICE_NAME}" "${DPI_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${DPI_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${DPI_STACK_SERVICE_CIDR}" "${DPI_STACK_SERVICE_CIDR_SOURCE}" "${DPI_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'stack_label: %s [source=derived]\n' "${DPI_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${DPI_ROLE_LABEL_KEY}" "${DPI_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${DPI_ROLE_LABEL_KEY}" "${DPI_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${DPI_ROLE_LABEL_KEY}" "${DPI_ROLE_SERVER}"
    printf 'dpi deployment: %s [source=derived]\n' "${DPI_STACK_MIDDLE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${DPI_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${DPI_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'rules configmap: %s [source=derived]\n' "${DPI_STACK_RULES_CONFIGMAP_NAME}"
    printf 'rules local.rules cidr patch: %s [source=derived]\n' "${DPI_STACK_RULES_CIDR_PATCH_ENABLED}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${DPI_STACK_VNF_NODE}" "${DPI_STACK_VNF_NODE_SOURCE}" "${DPI_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${DPI_STACK_CLIENT_NODE}" "${DPI_STACK_CLIENT_NODE_SOURCE}" "${DPI_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${DPI_STACK_SERVER_NODE}" "${DPI_STACK_SERVER_NODE_SOURCE}" "${DPI_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'dpi env.NSM_SERVICE_NAME: %s [source=derived]\n' "${DPI_STACK_NETWORK_SERVICE_NAME}"
    printf 'dpi env.NSM_LABELS: %s [source=derived]\n' "${DPI_STACK_MIDDLE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${DPI_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${DPI_STACK_SERVICE_CIDR}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${DPI_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${DPI_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${DPI_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
}
