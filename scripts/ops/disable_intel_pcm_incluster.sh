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
Usage: disable_intel_pcm_incluster.sh [platform-options] [--namespace <name>] [--daemonset <name>] [--state-dir <dir>] [--dry-run]

Safely removes the in-cluster intel-pcm DaemonSet from active scheduling by adding
an impossible nodeSelector gate. It does not delete the namespace or manifest.
Rollback uses scripts/ops/enable_intel_pcm_incluster.sh.
EOF
}

main() {
    local namespace="intel-pcm"
    local daemonset_name="intel-pcm"
    local state_dir=""
    local dry_run=false
    local snapshot_dir snapshot_token state_file patch_file
    local annotation_key="nsm-ovs.platform/pcm-host-transition"
    local annotation_value="disabled"
    local node_selector_key="nsm-ovs.platform/pcm-host-transition-disabled"
    local node_selector_value="true"
    local current_json patch_payload

    platform_init "$@"
    state_dir="${STATE_ROOT}/intel-pcm-host-transition"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --namespace)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --namespace"
                namespace="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --daemonset)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --daemonset"
                daemonset_name="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
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
                die "unknown disable_intel_pcm_incluster argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_require_no_extra_args
    require_command jq
    k8s_require_cluster
    k8s_log_context

    [[ -n "${namespace}" ]] || die "namespace must not be empty"
    [[ -n "${daemonset_name}" ]] || die "daemonset name must not be empty"
    mkdir -p "${state_dir}"

    if ! k8s_namespace_exists "${namespace}"; then
        die "namespace not found: ${namespace}"
    fi

    current_json="$("${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o json)"
    if ! printf '%s' "${current_json}" | jq -e . >/dev/null 2>&1; then
        die "failed to load daemonset/${daemonset_name} json from namespace ${namespace}"
    fi

    if printf '%s' "${current_json}" | jq -e --arg key "${node_selector_key}" '(.spec.template.spec.nodeSelector // {}) | has($key)' >/dev/null; then
        die "daemonset/${daemonset_name} already has disable nodeSelector key ${node_selector_key}; refusing to stack another disable"
    fi
    if printf '%s' "${current_json}" | jq -e --arg key "${annotation_key}" '(.spec.template.metadata.annotations // {}) | has($key)' >/dev/null; then
        die "daemonset/${daemonset_name} already has transition annotation ${annotation_key}; refusing to continue"
    fi

    snapshot_token="$(platform_now_local_file_token)"
    snapshot_dir="${state_dir}/disable-${snapshot_token}"
    state_file="${state_dir}/current-disable.env"
    patch_file="${snapshot_dir}/disable-patch.json"
    mkdir -p "${snapshot_dir}"

    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o yaml > "${snapshot_dir}/daemonset.before.yaml"
    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o wide > "${snapshot_dir}/daemonset.before.txt"
    "${KUBECTL}" get pods -n "${namespace}" -o wide > "${snapshot_dir}/pods.before.txt" 2>&1 || true
    "${KUBECTL}" describe daemonset "${daemonset_name}" -n "${namespace}" > "${snapshot_dir}/daemonset.before.describe.txt" 2>&1 || true

    patch_payload="$(jq -cn \
        --arg annotation_key "${annotation_key}" \
        --arg annotation_value "${annotation_value}" \
        --arg selector_key "${node_selector_key}" \
        --arg selector_value "${node_selector_value}" \
        '{
            spec: {
                template: {
                    metadata: {
                        annotations: {
                            ($annotation_key): $annotation_value
                        }
                    },
                    spec: {
                        nodeSelector: {
                            ($selector_key): $selector_value
                        }
                    }
                }
            }
        }')"
    printf '%s\n' "${patch_payload}" > "${patch_file}"

    cat > "${state_file}" <<EOF
PCM_DEPLOYMENT_MODE_AT_DISABLE=${PCM_DEPLOYMENT_MODE:-in-cluster}
INTEL_PCM_NAMESPACE=${namespace}
INTEL_PCM_DAEMONSET=${daemonset_name}
INTEL_PCM_DISABLE_SNAPSHOT_DIR=${snapshot_dir}
INTEL_PCM_DISABLE_NODE_SELECTOR_KEY=${node_selector_key}
INTEL_PCM_DISABLE_NODE_SELECTOR_VALUE=${node_selector_value}
INTEL_PCM_DISABLE_ANNOTATION_KEY=${annotation_key}
INTEL_PCM_DISABLE_ANNOTATION_VALUE=${annotation_value}
INTEL_PCM_DISABLE_STATE_CREATED_AT=$(platform_now_local_iso8601)
EOF

    log_info "prepared intel-pcm in-cluster disable snapshot: ${snapshot_dir}"
    log_info "disable patch preview: ${patch_file}"

    if [[ "${dry_run}" == "true" ]]; then
        log_info "dry-run enabled; daemonset/${daemonset_name} was not patched"
        exit 0
    fi

    "${KUBECTL}" patch daemonset "${daemonset_name}" -n "${namespace}" --type merge -p "${patch_payload}" >/dev/null
    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o yaml > "${snapshot_dir}/daemonset.after.yaml"
    "${KUBECTL}" get daemonset "${daemonset_name}" -n "${namespace}" -o wide > "${snapshot_dir}/daemonset.after.txt"
    "${KUBECTL}" get pods -n "${namespace}" -o wide > "${snapshot_dir}/pods.after.txt" 2>&1 || true

    log_success "patched daemonset/${daemonset_name} in namespace ${namespace} for host-transition disable"
    log_info "rollback with: ${PLATFORM_REPO_ROOT}/scripts/ops/enable_intel_pcm_incluster.sh --state-dir ${state_dir}"
}

main "$@"
