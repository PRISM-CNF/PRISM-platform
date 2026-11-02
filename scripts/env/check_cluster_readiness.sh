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
source "${PLATFORM_REPO_ROOT}/scripts/lib/image_delivery.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/basic.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/victoriametrics.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/n9e.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/categraf.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/preflight.sh"

VM_STATEFULSET_NAME_DEFAULT='victoria-metrics'
VM_HEADLESS_SERVICE_NAME_DEFAULT='victoria-metrics-internal'
VM_PVC_NAME_DEFAULT='data-victoria-metrics-0'
N9E_DEPLOYMENT_NAME_DEFAULT='n9e'
N9E_CONFIGMAP_NAME_DEFAULT='n9e-config'
N9E_PVC_NAME_DEFAULT='n9e-data'
CATEGRAF_DAEMONSET_NAME_DEFAULT='categraf-agent'

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab check-cluster-readiness [platform-options]

Runs a read-only / lightweight preflight against the current cluster target and
reports whether the environment is ready to start deploy/run workflows.
EOF
}

preflight_blocked_by_cluster_target() {
    local section_key=$1
    local summary_label=$2

    preflight_set_section_status "${section_key}" fail "${summary_label} check was skipped because cluster-target is not ready"
    preflight_add_section_evidence "${section_key}" "cluster-target status: ${PREFLIGHT_SECTION_STATUS[cluster-target]:-fail}"
    preflight_add_section_action "${section_key}" "Fix cluster target connectivity and context resolution first, then rerun check-cluster-readiness."
}

preflight_check_render_dir() {
    local section_key=$1
    local label=$2
    local dir_path=$3

    if [[ ! -d "${dir_path}" ]]; then
        preflight_set_section_status "${section_key}" fail "${label} assets are missing"
        preflight_add_section_evidence "${section_key}" "missing directory: ${dir_path}"
        return 1
    fi

    if "${KUBECTL}" kustomize --load-restrictor LoadRestrictionsNone "${dir_path}" >/dev/null 2>&1; then
        preflight_add_section_evidence "${section_key}" "${label} render check passed: ${dir_path}"
        return 0
    fi

    preflight_set_section_status "${section_key}" fail "${label} manifests do not render cleanly"
    preflight_add_section_evidence "${section_key}" "kubectl kustomize failed: ${dir_path}"
    return 1
}

preflight_check_selector_ready() {
    local section_key=$1
    local namespace=$2
    local selector=$3
    local label=$4
    local timeout=${5:-5s}
    local pod_names

    pod_names="$("${KUBECTL}" get pods -n "${namespace}" -l "${selector}" -o name 2>/dev/null || true)"
    if [[ -z "${pod_names}" ]]; then
        preflight_set_section_status "${section_key}" fail "${label} pods are missing"
        preflight_add_section_evidence "${section_key}" "no pods for selector=${selector} in namespace=${namespace}"
        return 1
    fi

    if "${KUBECTL}" wait --for=condition=Ready --timeout="${timeout}" pod -l "${selector}" -n "${namespace}" >/dev/null 2>&1; then
        preflight_add_section_evidence "${section_key}" "${label} pods ready: selector=${selector} namespace=${namespace}"
        return 0
    fi

    preflight_set_section_status "${section_key}" fail "${label} pods are not Ready"
    preflight_add_section_evidence "${section_key}" "readiness timeout for selector=${selector} in namespace=${namespace}"
    return 1
}

preflight_check_cluster_target() {
    local section_key='cluster-target'
    local current_context=""
    local cluster_target_warn=false

    preflight_add_section_evidence "${section_key}" "cluster profile: ${CLUSTER_PROFILE}"
    preflight_add_section_evidence "${section_key}" "cluster profile file: ${CLUSTER_PROFILE_FILE}"
    preflight_add_section_evidence "${section_key}" "kubectl real bin: ${KUBECTL_BIN_REAL}"

    if ! command -v "${KUBECTL_BIN_REAL}" >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "kubectl binary is not available"
        preflight_add_section_evidence "${section_key}" "missing command: ${KUBECTL_BIN_REAL}"
        preflight_add_section_action "${section_key}" "Install kubectl or set NSM_OVS_KUBECTL_BIN / --kubeconfig / --context correctly."
        return 0
    fi

    if [[ -n "${KUBECONFIG_PATH}" ]]; then
        if [[ -f "${KUBECONFIG_PATH}" ]]; then
            preflight_add_section_evidence "${section_key}" "kubeconfig file exists: ${KUBECONFIG_PATH}"
        else
            preflight_set_section_status "${section_key}" fail "configured kubeconfig file does not exist"
            preflight_add_section_evidence "${section_key}" "missing kubeconfig: ${KUBECONFIG_PATH}"
            preflight_add_section_action "${section_key}" "Provide a valid --kubeconfig path or fix the cluster profile/local override."
            return 0
        fi
    else
        cluster_target_warn=true
        preflight_add_section_evidence "${section_key}" "kubeconfig is unresolved; platform will inherit ambient kubectl config"
        preflight_add_section_action "${section_key}" "Prefer explicit --kubeconfig or cluster profile defaults before migrating to a new cluster."
    fi

    if [[ -n "${KUBECTL_CONTEXT}" ]]; then
        if k8s_context_exists "${KUBECTL_CONTEXT}"; then
            preflight_add_section_evidence "${section_key}" "configured context exists: ${KUBECTL_CONTEXT}"
        else
            preflight_set_section_status "${section_key}" fail "configured kubectl context does not exist"
            preflight_add_section_evidence "${section_key}" "missing context: ${KUBECTL_CONTEXT}"
            preflight_add_section_action "${section_key}" "Use a valid --context or update the cluster profile/local override."
            return 0
        fi
    else
        current_context="$(k8s_config_current_context)"
        if [[ -n "${current_context}" ]]; then
            cluster_target_warn=true
            preflight_add_section_evidence "${section_key}" "context is unresolved; using ambient current-context=${current_context}"
            preflight_add_section_action "${section_key}" "Pin --context explicitly once the target cluster is known."
        else
            preflight_set_section_status "${section_key}" fail "no kubectl context can be resolved"
            preflight_add_section_evidence "${section_key}" "kubectl config current-context returned empty"
            preflight_add_section_action "${section_key}" "Set --context or configure a default current-context in kubeconfig."
            return 0
        fi
    fi

    if k8s_cluster_reachable; then
        preflight_add_section_evidence "${section_key}" "API server reachable via ${KUBECTL}"
    else
        preflight_set_section_status "${section_key}" fail "kubectl cannot reach the API server for the resolved cluster target"
        preflight_add_section_evidence "${section_key}" "cluster-info failed for profile=${CLUSTER_PROFILE} context=${KUBECTL_CONTEXT:-ambient}"
        preflight_add_section_action "${section_key}" "Verify kubeconfig/context credentials and cluster network reachability."
        return 0
    fi

    if [[ "${cluster_target_warn}" == "true" ]]; then
        preflight_set_section_status "${section_key}" warn "cluster target is reachable but still depends on ambient kubeconfig/context state"
    else
        preflight_set_section_status "${section_key}" pass "cluster target is explicit and API server is reachable"
    fi
}

preflight_image_registry_host() {
    local image_ref=$1
    local first_segment=${image_ref%%/*}

    if [[ "${image_ref}" != */* ]]; then
        printf 'docker.io\n'
    elif [[ "${first_segment}" == *.* || "${first_segment}" == *:* || "${first_segment}" == "localhost" ]]; then
        printf '%s\n' "${first_segment}"
    else
        printf 'docker.io\n'
    fi
}

preflight_image_ref_is_local_only() {
    local image_ref=$1
    local registry_host

    registry_host="$(preflight_image_registry_host "${image_ref}")"

    case "${registry_host}" in
        localhost|127.*|*.svc|*.svc.cluster.local|cluster.local|kind-registry*|registry.local*)
            return 0
            ;;
    esac

    return 1
}

preflight_collect_manifest_images() {
    grep -RhoE 'image:[[:space:]]*[^[:space:]#"]+' "$@" 2>/dev/null \
        | sed -E 's/^image:[[:space:]]*//' \
        | sort -u
}

preflight_check_image_delivery() {
    local section_key='image-delivery'
    local image_refs=()
    local public_registries=()
    local local_only_refs=()
    local image_ref registry_host
    local docker_missing=false

    mapfile -t image_refs < <(preflight_collect_manifest_images \
        "${BASIC_ASSETS_ROOT}" \
        "${TEMPLATE_K8S_ASSETS_DIR}" \
        "${VICTORIAMETRICS_MANIFESTS_BASE_DIR}" \
        "${N9E_MANIFESTS_BASE_DIR}" \
        "${CATEGRAF_MANIFESTS_BASE_DIR}")

    preflight_add_section_evidence "${section_key}" "image delivery mode: ${IMAGE_DELIVERY_MODE}"

    if [[ ${#image_refs[@]} -eq 0 ]]; then
        preflight_set_section_status "${section_key}" fail "no runtime image references were discovered from tracked assets"
        preflight_add_section_action "${section_key}" "Check synced assets and manifest paths before relying on image delivery preflight."
        return 0
    fi

    for image_ref in "${image_refs[@]}"; do
        registry_host="$(preflight_image_registry_host "${image_ref}")"
        public_registries+=("${registry_host}")
        if preflight_image_ref_is_local_only "${image_ref}"; then
            local_only_refs+=("${image_ref}")
        fi
    done

    mapfile -t public_registries < <(printf '%s\n' "${public_registries[@]}" | sort -u)
    preflight_add_section_evidence "${section_key}" "discovered ${#image_refs[@]} unique runtime image refs"
    preflight_add_section_evidence "${section_key}" "registry hosts: $(IFS=,; printf '%s' "${public_registries[*]}")"

    if image_delivery_is_registry_pull; then
        if [[ ${#local_only_refs[@]} -gt 0 ]]; then
            preflight_set_section_status "${section_key}" fail "registry-pull mode still points at local-only image references"
            preflight_add_section_evidence "${section_key}" "local-only refs: $(IFS=,; printf '%s' "${local_only_refs[*]}")"
            preflight_add_section_action "${section_key}" "Replace local-only image refs or switch explicitly to preload-import compatibility mode."
            return 0
        fi

        preflight_set_section_status "${section_key}" pass "registry-pull mode resolves to public-registry / Docker Hub compatible image references"
        preflight_add_section_action "${section_key}" "Keep target cluster egress to Docker Hub / public registries available."
        return 0
    fi

    if ! command -v ctr >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "preload-import mode requires ctr on the operator host"
        preflight_add_section_evidence "${section_key}" "missing command: ctr"
        preflight_add_section_action "${section_key}" "Install containerd ctr tooling or switch back to registry-pull."
        return 0
    fi
    preflight_add_section_evidence "${section_key}" "ctr command is available"

    if ! ctr version >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "ctr is installed but not usable from the current host context"
        preflight_add_section_evidence "${section_key}" "ctr version failed"
        preflight_add_section_action "${section_key}" "Verify containerd access on the operator host or switch back to registry-pull."
        return 0
    fi
    preflight_add_section_evidence "${section_key}" "ctr version succeeded"

    if ! command -v docker >/dev/null 2>&1; then
        docker_missing=true
        preflight_add_section_evidence "${section_key}" "docker command is missing; source build -> import flow is unavailable"
        preflight_add_section_action "${section_key}" "Install docker if local template source builds need to feed preload-import."
    else
        preflight_add_section_evidence "${section_key}" "docker command is available"
    fi

    if [[ "${docker_missing}" == "true" ]]; then
        preflight_set_section_status "${section_key}" warn "preload-import compatibility mode is partially available, but source build -> import tooling is incomplete"
    else
        preflight_set_section_status "${section_key}" warn "preload-import compatibility mode is available but remains host-coupled and is not the preferred portable path"
    fi
    preflight_add_section_action "${section_key}" "Use registry-pull for new clusters unless node-local import is explicitly required."
}

preflight_check_basic_contract() {
    local section_key='basic-contract'
    local forwarder_namespace forwarder_daemonset

    basic_init_context "${BASIC_ASSETS_ROOT}"

    if ! ( basic_require_runtime_assets ) >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "basic runtime assets are incomplete"
        preflight_add_section_evidence "${section_key}" "required bundled basic assets are missing"
        preflight_add_section_action "${section_key}" "Run ./bin/nsm-ovs-lab sync-basic-assets before relying on the basic contract."
        return 0
    fi

    preflight_check_render_dir "${section_key}" "basic SPIRE core" "${BASIC_SPIRE_CORE_DIR}" || true
    preflight_check_render_dir "${section_key}" "basic SPIRE workload IDs" "${BASIC_SPIRE_WORKLOAD_IDS_DIR}" || true
    preflight_check_render_dir "${section_key}" "basic OVS/NSM" "${BASIC_OVS_BASIC_DIR}" || true

    forwarder_namespace="$(basic_forwarder_namespace)"
    forwarder_daemonset="$(basic_forwarder_daemonset_name)"

    if ! basic_namespace_exists "$(basic_spire_namespace)"; then
        preflight_set_section_status "${section_key}" fail "SPIRE namespace is missing"
        preflight_add_section_evidence "${section_key}" "namespace not found: $(basic_spire_namespace)"
    fi
    if ! basic_namespace_exists "$(basic_nsm_system_namespace)"; then
        preflight_set_section_status "${section_key}" fail "NSM system namespace is missing"
        preflight_add_section_evidence "${section_key}" "namespace not found: $(basic_nsm_system_namespace)"
    fi

    if basic_namespace_exists "$(basic_spire_namespace)"; then
        preflight_check_selector_ready "${section_key}" "$(basic_spire_namespace)" "app=spire-server" "spire-server" || true
        preflight_check_selector_ready "${section_key}" "$(basic_spire_namespace)" "app=spire-agent" "spire-agent" || true
    fi

    if basic_namespace_exists "$(basic_nsm_system_namespace)"; then
        preflight_check_selector_ready "${section_key}" "$(basic_nsm_system_namespace)" "app=registry" "registry-k8s" || true
        preflight_check_selector_ready "${section_key}" "$(basic_nsm_system_namespace)" "app=admission-webhook-k8s" "admission-webhook-k8s" || true
        preflight_check_selector_ready "${section_key}" "$(basic_nsm_system_namespace)" "app=nsmgr" "nsmgr" || true
        preflight_check_selector_ready "${section_key}" "${forwarder_namespace}" "app=${forwarder_daemonset}" "${forwarder_daemonset}" || true
        if "${KUBECTL}" rollout status "daemonset/${forwarder_daemonset}" -n "${forwarder_namespace}" --timeout=5s >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "daemonset rollout ready: ${forwarder_namespace}/${forwarder_daemonset}"
        else
            preflight_set_section_status "${section_key}" fail "forwarder daemonset rollout is incomplete"
            preflight_add_section_evidence "${section_key}" "rollout status failed: daemonset/${forwarder_daemonset} namespace=${forwarder_namespace}"
        fi
    fi

    if "${KUBECTL}" get clusterspiffeid nsm-workloads nsm-workloads-webhook >/dev/null 2>&1; then
        preflight_add_section_evidence "${section_key}" "ClusterSPIFFEIDs present: nsm-workloads, nsm-workloads-webhook"
    else
        preflight_set_section_status "${section_key}" fail "SPIRE workload identity objects are missing"
        preflight_add_section_evidence "${section_key}" "clusterspiffeid nsm-workloads / nsm-workloads-webhook not found"
    fi

    if [[ -z "${PREFLIGHT_SECTION_STATUS[${section_key}]:-}" ]]; then
        preflight_set_section_status "${section_key}" pass "basic NSM / SPIRE contract is present and Ready"
    fi
    preflight_add_section_action "${section_key}" "If this section fails, run ./bin/nsm-ovs-lab deploy-basic and ./bin/nsm-ovs-lab check-basic."
}

preflight_check_measurement_contract() {
    local section_key='measurement-contract'
    local vm_pvc_phase=""
    local n9e_pvc_phase=""
    local categraf_desired=""
    local categraf_current=""
    local categraf_ready=""
    local expected_n9e_writer expected_vm_remote_write live_n9e_config live_categraf_config

    if ! ( victoriametrics_assets_require_synced ) >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "victoriametrics assets are incomplete"
        preflight_add_section_evidence "${section_key}" "missing victoriametrics synced assets"
    fi
    if ! ( n9e_assets_require_synced ) >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "n9e assets are incomplete"
        preflight_add_section_evidence "${section_key}" "missing n9e synced assets"
    fi
    if ! ( categraf_assets_require_synced ) >/dev/null 2>&1; then
        preflight_set_section_status "${section_key}" fail "categraf assets are incomplete"
        preflight_add_section_evidence "${section_key}" "missing categraf synced assets"
    fi

    preflight_check_render_dir "${section_key}" "victoriametrics" "${VICTORIAMETRICS_MANIFESTS_BASE_DIR}" || true
    preflight_check_render_dir "${section_key}" "n9e" "${N9E_MANIFESTS_BASE_DIR}" || true
    preflight_check_render_dir "${section_key}" "categraf" "${CATEGRAF_MANIFESTS_BASE_DIR}" || true

    if ! k8s_namespace_exists "${VM_NAMESPACE}"; then
        preflight_set_section_status "${section_key}" fail "victoriametrics namespace is missing"
        preflight_add_section_evidence "${section_key}" "namespace not found: ${VM_NAMESPACE}"
    fi
    if ! k8s_namespace_exists "${N9E_NAMESPACE}"; then
        preflight_set_section_status "${section_key}" fail "n9e namespace is missing"
        preflight_add_section_evidence "${section_key}" "namespace not found: ${N9E_NAMESPACE}"
    fi
    if ! k8s_namespace_exists "${CATEGRAF_NAMESPACE}"; then
        preflight_set_section_status "${section_key}" fail "categraf namespace is missing"
        preflight_add_section_evidence "${section_key}" "namespace not found: ${CATEGRAF_NAMESPACE}"
    fi

    if k8s_namespace_exists "${VM_NAMESPACE}"; then
        if "${KUBECTL}" get statefulset "${VM_STATEFULSET_NAME_DEFAULT}" -n "${VM_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "victoriametrics statefulset exists: ${VM_NAMESPACE}/${VM_STATEFULSET_NAME_DEFAULT}"
            if "${KUBECTL}" rollout status "statefulset/${VM_STATEFULSET_NAME_DEFAULT}" -n "${VM_NAMESPACE}" --timeout=5s >/dev/null 2>&1; then
                preflight_add_section_evidence "${section_key}" "victoriametrics rollout ready"
            else
                preflight_set_section_status "${section_key}" fail "victoriametrics rollout is incomplete"
                preflight_add_section_evidence "${section_key}" "rollout status failed for statefulset/${VM_STATEFULSET_NAME_DEFAULT}"
            fi
        else
            preflight_set_section_status "${section_key}" fail "victoriametrics statefulset is missing"
            preflight_add_section_evidence "${section_key}" "statefulset not found: ${VM_NAMESPACE}/${VM_STATEFULSET_NAME_DEFAULT}"
        fi

        if "${KUBECTL}" get service "${VM_SERVICE_NAME}" -n "${VM_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "victoriametrics service exists: ${VM_NAMESPACE}/${VM_SERVICE_NAME}"
        else
            preflight_set_section_status "${section_key}" fail "victoriametrics service is missing"
            preflight_add_section_evidence "${section_key}" "service not found: ${VM_NAMESPACE}/${VM_SERVICE_NAME}"
        fi

        if "${KUBECTL}" get service "${VM_HEADLESS_SERVICE_NAME_DEFAULT}" -n "${VM_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "victoriametrics headless service exists: ${VM_NAMESPACE}/${VM_HEADLESS_SERVICE_NAME_DEFAULT}"
        else
            preflight_set_section_status "${section_key}" fail "victoriametrics headless service is missing"
            preflight_add_section_evidence "${section_key}" "service not found: ${VM_NAMESPACE}/${VM_HEADLESS_SERVICE_NAME_DEFAULT}"
        fi

        vm_pvc_phase="$("${KUBECTL}" get pvc "${VM_PVC_NAME_DEFAULT}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "${vm_pvc_phase}" == "Bound" ]]; then
            preflight_add_section_evidence "${section_key}" "victoriametrics PVC is Bound: ${VM_PVC_NAME_DEFAULT}"
        else
            preflight_set_section_status "${section_key}" fail "victoriametrics PVC is missing or not Bound"
            preflight_add_section_evidence "${section_key}" "PVC ${VM_PVC_NAME_DEFAULT} phase=${vm_pvc_phase:-missing}"
        fi
    fi

    if k8s_namespace_exists "${N9E_NAMESPACE}"; then
        if "${KUBECTL}" get deployment "${N9E_DEPLOYMENT_NAME_DEFAULT}" -n "${N9E_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "n9e deployment exists: ${N9E_NAMESPACE}/${N9E_DEPLOYMENT_NAME_DEFAULT}"
            if "${KUBECTL}" rollout status "deployment/${N9E_DEPLOYMENT_NAME_DEFAULT}" -n "${N9E_NAMESPACE}" --timeout=5s >/dev/null 2>&1; then
                preflight_add_section_evidence "${section_key}" "n9e rollout ready"
            else
                preflight_set_section_status "${section_key}" fail "n9e rollout is incomplete"
                preflight_add_section_evidence "${section_key}" "rollout status failed for deployment/${N9E_DEPLOYMENT_NAME_DEFAULT}"
            fi
        else
            preflight_set_section_status "${section_key}" fail "n9e deployment is missing"
            preflight_add_section_evidence "${section_key}" "deployment not found: ${N9E_NAMESPACE}/${N9E_DEPLOYMENT_NAME_DEFAULT}"
        fi

        if "${KUBECTL}" get service "${N9E_SERVICE_NAME}" -n "${N9E_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "n9e service exists: ${N9E_NAMESPACE}/${N9E_SERVICE_NAME}"
        else
            preflight_set_section_status "${section_key}" fail "n9e service is missing"
            preflight_add_section_evidence "${section_key}" "service not found: ${N9E_NAMESPACE}/${N9E_SERVICE_NAME}"
        fi

        if "${KUBECTL}" get configmap "${N9E_CONFIGMAP_NAME_DEFAULT}" -n "${N9E_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "n9e configmap exists: ${N9E_NAMESPACE}/${N9E_CONFIGMAP_NAME_DEFAULT}"
            live_n9e_config="$("${KUBECTL}" get configmap "${N9E_CONFIGMAP_NAME_DEFAULT}" -n "${N9E_NAMESPACE}" -o jsonpath='{.data.config\.toml}' 2>/dev/null || true)"
            expected_vm_remote_write="http://${VM_SERVICE_NAME}.${VM_NAMESPACE}.svc.cluster.local:${VM_HTTP_PORT}/api/v1/write"
            if grep -Fq 'ForceUseServerTS = false' <<< "${live_n9e_config}"; then
                preflight_add_section_evidence "${section_key}" "n9e preserves sender sample time: ForceUseServerTS=false"
            else
                preflight_set_section_status "${section_key}" fail "n9e timestamp semantics drifted from sender-sample-time"
                preflight_add_section_evidence "${section_key}" "ForceUseServerTS=false not found in n9e config"
            fi
            if grep -Fq "${expected_vm_remote_write}" <<< "${live_n9e_config}"; then
                preflight_add_section_evidence "${section_key}" "n9e remote write target matches victoriametrics service contract"
            else
                preflight_set_section_status "${section_key}" fail "n9e remote write target does not match the resolved victoriametrics contract"
                preflight_add_section_evidence "${section_key}" "expected remote write URL: ${expected_vm_remote_write}"
            fi
        else
            preflight_set_section_status "${section_key}" fail "n9e configmap is missing"
            preflight_add_section_evidence "${section_key}" "configmap not found: ${N9E_NAMESPACE}/${N9E_CONFIGMAP_NAME_DEFAULT}"
        fi

        n9e_pvc_phase="$("${KUBECTL}" get pvc "${N9E_PVC_NAME_DEFAULT}" -n "${N9E_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "${n9e_pvc_phase}" == "Bound" ]]; then
            preflight_add_section_evidence "${section_key}" "n9e PVC is Bound: ${N9E_PVC_NAME_DEFAULT}"
        else
            preflight_set_section_status "${section_key}" fail "n9e PVC is missing or not Bound"
            preflight_add_section_evidence "${section_key}" "PVC ${N9E_PVC_NAME_DEFAULT} phase=${n9e_pvc_phase:-missing}"
        fi
    fi

    if k8s_namespace_exists "${CATEGRAF_NAMESPACE}"; then
        if "${KUBECTL}" get configmap "${CATEGRAF_CONFIGMAP_NAME}" -n "${CATEGRAF_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "categraf configmap exists: ${CATEGRAF_NAMESPACE}/${CATEGRAF_CONFIGMAP_NAME}"
            live_categraf_config="$("${KUBECTL}" get configmap "${CATEGRAF_CONFIGMAP_NAME}" -n "${CATEGRAF_NAMESPACE}" -o jsonpath='{.data.config\.toml}' 2>/dev/null || true)"
            expected_n9e_writer="http://${N9E_SERVICE_NAME}.${N9E_NAMESPACE}.svc.cluster.local:${N9E_HTTP_PORT}/prometheus/v1/write"
            if grep -Fq "${expected_n9e_writer}" <<< "${live_categraf_config}"; then
                preflight_add_section_evidence "${section_key}" "categraf remote write target matches n9e service contract"
            else
                preflight_set_section_status "${section_key}" fail "categraf remote write target does not match the resolved n9e contract"
                preflight_add_section_evidence "${section_key}" "expected writer URL: ${expected_n9e_writer}"
            fi
        else
            preflight_set_section_status "${section_key}" fail "categraf configmap is missing"
            preflight_add_section_evidence "${section_key}" "configmap not found: ${CATEGRAF_NAMESPACE}/${CATEGRAF_CONFIGMAP_NAME}"
        fi

        if "${KUBECTL}" get daemonset "${CATEGRAF_DAEMONSET_NAME_DEFAULT}" -n "${CATEGRAF_NAMESPACE}" >/dev/null 2>&1; then
            preflight_add_section_evidence "${section_key}" "categraf daemonset exists: ${CATEGRAF_NAMESPACE}/${CATEGRAF_DAEMONSET_NAME_DEFAULT}"
            categraf_desired="$("${KUBECTL}" get daemonset "${CATEGRAF_DAEMONSET_NAME_DEFAULT}" -n "${CATEGRAF_NAMESPACE}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
            categraf_current="$("${KUBECTL}" get daemonset "${CATEGRAF_DAEMONSET_NAME_DEFAULT}" -n "${CATEGRAF_NAMESPACE}" -o jsonpath='{.status.currentNumberScheduled}' 2>/dev/null || true)"
            categraf_ready="$("${KUBECTL}" get daemonset "${CATEGRAF_DAEMONSET_NAME_DEFAULT}" -n "${CATEGRAF_NAMESPACE}" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
            if [[ -n "${categraf_desired}" && "${categraf_desired}" != "0" && "${categraf_desired}" == "${categraf_current}" && "${categraf_desired}" == "${categraf_ready}" ]]; then
                preflight_add_section_evidence "${section_key}" "categraf daemonset scheduled/current/ready = ${categraf_desired}"
            else
                preflight_set_section_status "${section_key}" fail "categraf daemonset is not fully ready on cluster nodes"
                preflight_add_section_evidence "${section_key}" "categraf desired=${categraf_desired:-missing} current=${categraf_current:-missing} ready=${categraf_ready:-missing}"
            fi
        else
            preflight_set_section_status "${section_key}" fail "categraf daemonset is missing"
            preflight_add_section_evidence "${section_key}" "daemonset not found: ${CATEGRAF_NAMESPACE}/${CATEGRAF_DAEMONSET_NAME_DEFAULT}"
        fi
    fi

    if [[ -z "${PREFLIGHT_SECTION_STATUS[${section_key}]:-}" ]]; then
        preflight_set_section_status "${section_key}" pass "measurement stack contract is present and aligned with the resolved profile"
    fi
    preflight_add_section_action "${section_key}" "If this section fails, run sync-* assets as needed, then ./bin/nsm-ovs-lab deploy-measurement-stack."
}

preflight_check_node_placement() {
    local section_key='node-placement'
    local -a role_entries=(
        "vnf:${TEMPLATE_DEFAULT_VNF_NODE}"
        "client:${TEMPLATE_DEFAULT_CLIENT_NODE}"
        "server:${TEMPLATE_DEFAULT_SERVER_NODE}"
    )
    local -A seen_nodes=()
    local role_name node_name
    local schedulable_total=""

    preflight_add_section_evidence "${section_key}" "resolved role nodes: vnf=${TEMPLATE_DEFAULT_VNF_NODE}, client=${TEMPLATE_DEFAULT_CLIENT_NODE}, server=${TEMPLATE_DEFAULT_SERVER_NODE}"

    schedulable_total="$("${KUBECTL}" get nodes --field-selector spec.unschedulable!=true --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ -n "${schedulable_total}" ]]; then
        preflight_add_section_evidence "${section_key}" "schedulable node count: ${schedulable_total}"
    fi

    for role_name in "${role_entries[@]}"; do
        node_name=${role_name#*:}
        role_name=${role_name%%:*}

        [[ -n "${seen_nodes[${node_name}]:-}" ]] && continue
        seen_nodes["${node_name}"]=1

        if ! k8s_node_exists "${node_name}"; then
            preflight_set_section_status "${section_key}" fail "configured placement node does not exist"
            preflight_add_section_evidence "${section_key}" "node missing for role=${role_name}: ${node_name}"
            continue
        fi
        preflight_add_section_evidence "${section_key}" "node exists: ${node_name}"

        if k8s_node_is_ready "${node_name}"; then
            preflight_add_section_evidence "${section_key}" "node Ready=True: ${node_name}"
        else
            preflight_set_section_status "${section_key}" fail "configured placement node is not Ready"
            preflight_add_section_evidence "${section_key}" "node Ready!=True: ${node_name}"
        fi

        if k8s_node_is_schedulable "${node_name}"; then
            preflight_add_section_evidence "${section_key}" "node schedulable: ${node_name}"
        else
            preflight_set_section_status "${section_key}" fail "configured placement node is unschedulable"
            preflight_add_section_evidence "${section_key}" "node unschedulable: ${node_name}"
        fi
    done

    if [[ -z "${PREFLIGHT_SECTION_STATUS[${section_key}]:-}" ]]; then
        preflight_set_section_status "${section_key}" pass "resolved placement nodes exist and are schedulable"
    fi
    preflight_add_section_action "${section_key}" "Adjust --vnf-node / --client-node / --server-node defaults or cluster profile values if node names drift on the target cluster."
}

main() {
    preflight_init_report
    preflight_register_section "cluster-target" "cluster-target"
    preflight_register_section "image-delivery" "image-delivery"
    preflight_register_section "basic-contract" "basic-contract"
    preflight_register_section "measurement-contract" "measurement-contract"
    preflight_register_section "node-placement" "node-placement"

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown check-cluster-readiness argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    preflight_check_cluster_target
    preflight_check_image_delivery

    if [[ "${PREFLIGHT_SECTION_STATUS[cluster-target]:-pass}" == "fail" ]]; then
        preflight_blocked_by_cluster_target "basic-contract" "basic-contract"
        preflight_blocked_by_cluster_target "measurement-contract" "measurement-contract"
        preflight_blocked_by_cluster_target "node-placement" "node-placement"
    else
        preflight_check_basic_contract
        preflight_check_measurement_contract
        preflight_check_node_placement
    fi

    preflight_print_report
    preflight_exit_code
}

main "$@"
