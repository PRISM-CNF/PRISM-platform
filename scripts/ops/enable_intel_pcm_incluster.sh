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

usage() {
    cat <<'EOF'
Usage: enable_intel_pcm_incluster.sh [platform-options] [--state-dir <dir>] [--dry-run]

Rollback partner for scripts/ops/disable_intel_pcm_incluster.sh.
Removes the host-transition disable marker from the intel-pcm DaemonSet without deleting
the namespace or original manifest assets.
EOF
}

main() {
    local state_dir=""
    local dry_run=false
    local state_file namespace daemonset_name snapshot_dir
    local node_selector_key annotation_key current_json patch_ops
    local node_selector_present annotation_present

    platform_init "$@"
    state_dir="${STATE_ROOT}/intel-pcm-host-transition"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --state-dir)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --state-dir"
                state_dir="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --dry-run)
                dry_run=true
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown enable_intel_pcm_incluster argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_require_no_extra_args
    require_command jq
    k8s_require_cluster
    k8s_log_context

    state_file="${state_dir}/current-disable.env"
    [[ -f "${state_file}" ]] || die "disable state file not found: ${state_file}"

    namespace="$(sed -n 's/^INTEL_PCM_NAMESPACE=//p' "${state_file}" | tail -n 1)"
    daemonset_name="$(sed -n 's/^INTEL_PCM_DAEMONSET=//p' "${state_file}" | tail -n 1)"
    node_selector_key="$(sed -n 's/^INTEL_PCM_DISABLE_NODE_SELECTOR_KEY=//p' "${state_file}" | tail -n 1)"
    annotation_key="$(sed -n 's/^INTEL_PCM_DISABLE_ANNOTATION_KEY=//p' "${state_file}" | tail -n 1)"
    snapshot_dir="$(sed -n 's/^INTEL_PCM_DISABLE_SNAPSHOT_DIR=//p' "${state_file}" | tail -n 1)"

    [[ -n "${namespace}" ]] || die "INTEL_PCM_NAMESPACE missing in ${state_file}"
    [[ -n "${daemonset_name}" ]] || die "INTEL_PCM_DAEMONSET missing in ${state_file}"
    [[ -n "${node_selector_key}" ]] || die "INTEL_PCM_DISABLE_NODE_SELECTOR_KEY missing in ${state_file}"
    [[ -n "${annotation_key}" ]] || die "INTEL_PCM_DISABLE_ANNOTATION_KEY missing in ${state_file}"

    current_json="$("${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o json)"
    node_selector_present=false
    annotation_present=false

    if printf '%s' "${current_json}" | jq -e --arg key "${node_selector_key}" '(.spec.template.spec.nodeSelector // {}) | has($key)' >/dev/null; then
        node_selector_present=true
    fi
    if printf '%s' "${current_json}" | jq -e --arg key "${annotation_key}" '(.spec.template.metadata.annotations // {}) | has($key)' >/dev/null; then
        annotation_present=true
    fi

    if [[ "${node_selector_present}" != "true" && "${annotation_present}" != "true" ]]; then
        die "daemonset/${daemonset_name} no longer contains the expected host-transition disable markers"
    fi

    patch_ops="$(jq -cn \
        --arg selector_key "${node_selector_key}" \
        --arg annotation_key "${annotation_key}" \
        --argjson remove_selector "$(if [[ "${node_selector_present}" == "true" ]]; then printf 'true'; else printf 'false'; fi)" \
        --argjson remove_annotation "$(if [[ "${annotation_present}" == "true" ]]; then printf 'true'; else printf 'false'; fi)" \
        '
        [
            if $remove_selector then
                {"op":"remove","path":("/spec/template/spec/nodeSelector/" + ($selector_key | gsub("/"; "~1")))}
            else
                empty
            end,
            if $remove_annotation then
                {"op":"remove","path":("/spec/template/metadata/annotations/" + ($annotation_key | gsub("/"; "~1")))}
            else
                empty
            end
        ]')"

    mkdir -p "${snapshot_dir}"
    printf '%s\n' "${patch_ops}" > "${snapshot_dir}/enable-patch.json"
    log_info "prepared intel-pcm in-cluster enable patch: ${snapshot_dir}/enable-patch.json"

    if [[ "${dry_run}" == "true" ]]; then
        log_info "dry-run enabled; daemonset/${daemonset_name} was not patched"
        exit 0
    fi

    "${KUBECTL}" patch daemonset "${daemonset_name}" -n "${namespace}" --type json -p "${patch_ops}" >/dev/null
    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o yaml > "${snapshot_dir}/daemonset.rollback.yaml"
    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o wide > "${snapshot_dir}/daemonset.rollback.txt"
    "${KUBECTL}" get pods -n "${namespace}" -o wide > "${snapshot_dir}/pods.rollback.txt" 2>&1 || true

    log_success "removed host-transition disable markers from daemonset/${daemonset_name} in namespace ${namespace}"
}

main "$@"
