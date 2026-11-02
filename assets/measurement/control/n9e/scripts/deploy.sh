#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_command "${KUBECTL}"
    require_cluster
    ensure_repo_layout

    log_info "deploying n9e from ${KUSTOMIZE_DIR}"
    render_manifests | "${KUBECTL}" apply -f -

    log_info "waiting for deployment rollout: ${DEPLOYMENT_NAME}"
    "${KUBECTL}" rollout status deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"

    log_success "n9e deployment completed"
    print_deployment_summary
    print_service_summary
    print_pvc_summary
}

main "$@"
