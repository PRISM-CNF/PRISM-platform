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

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    k8s_require_cluster
    k8s_log_context
    [[ -x "${BASIC_STATUS_WRAPPER}" ]] || die "basic runtime wrapper not found or not executable: ${BASIC_STATUS_WRAPPER}; run ./bin/nsm-ovs-lab sync-basic-assets"

    log_info "running basic health check asset wrapper: ${BASIC_STATUS_WRAPPER}"
    "${BASIC_STATUS_WRAPPER}"
    log_success "basic health check completed"
}

main "$@"
