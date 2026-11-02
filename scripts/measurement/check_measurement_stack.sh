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

    log_info "checking measurement stack: victoriametrics -> n9e smoke -> categraf"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/check_vm.sh"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/check_n9e.sh"
    "${PLATFORM_REPO_ROOT}/scripts/measurement/check_categraf.sh"

    log_success "measurement stack check completed"
}

main "$@"
