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
    image_delivery_log_mode "deploy-measurement-stack"

    k8s_require_cluster
    k8s_log_context

    log_info "deploying measurement stack in order: victoriametrics -> n9e -> categraf"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/deploy_vm.sh"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/deploy_n9e.sh"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/deploy_categraf.sh"

    log_success "measurement stack deploy completed"
}

main "$@"
