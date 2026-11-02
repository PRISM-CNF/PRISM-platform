#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_command "${KUBECTL}"
    require_cluster

    log_info "cleaning categraf resources from ${KUSTOMIZE_DIR}"
    render_manifests | "${KUBECTL}" delete -f - --ignore-not-found=true >/dev/null || true
    "${KUBECTL}" delete namespace "${NAMESPACE}" --ignore-not-found=true >/dev/null || true

    if namespace_exists; then
        log_info "waiting for namespace deletion: ${NAMESPACE}"
        wait_for_namespace_deletion 180
    fi

    log_success "categraf cleanup completed"
}

main "$@"
