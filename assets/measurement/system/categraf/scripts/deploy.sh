#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_command "${KUBECTL}"
    require_cluster

    log_info "deploying categraf system collector from ${KUSTOMIZE_DIR}"
    render_manifests | "${KUBECTL}" apply -f -

    log_info "waiting for daemonset rollout: ${DAEMONSET_NAME}"
    "${KUBECTL}" rollout status daemonset/"${DAEMONSET_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"

    log_success "categraf deployment completed"
    print_daemonset_summary
}

main "$@"
