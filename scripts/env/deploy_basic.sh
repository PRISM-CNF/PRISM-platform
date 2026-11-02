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

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config
    image_delivery_log_mode "deploy-basic"

    k8s_require_cluster
    k8s_log_context
    [[ -x "${BASIC_DEPLOY_WRAPPER}" ]] || die "basic runtime wrapper not found or not executable: ${BASIC_DEPLOY_WRAPPER}; run ./bin/nsm-ovs-lab sync-basic-assets"

    log_info "running basic deploy asset wrapper: ${BASIC_DEPLOY_WRAPPER}"
    "${BASIC_DEPLOY_WRAPPER}"
    log_success "basic deploy completed"
}

main "$@"
