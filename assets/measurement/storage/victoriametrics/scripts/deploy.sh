#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_command "${KUBECTL}"
    require_cluster
    ensure_repo_layout

    log_info "deploying victoria metrics from ${KUSTOMIZE_DIR}"
    render_manifests | "${KUBECTL}" apply -f -

    log_info "waiting for statefulset rollout: ${STATEFULSET_NAME}"
    "${KUBECTL}" rollout status statefulset/"${STATEFULSET_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"

    log_success "victoria metrics deployment completed"
    print_statefulset_summary
    print_service_summary
    print_pvc_summary
}

main "$@"

