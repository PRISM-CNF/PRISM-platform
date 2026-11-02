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
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    nat_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context

    log_info "cleaning nat stack ${NAT_STACK_ID} in namespace ${NAT_NAMESPACE} without touching basic or other stacks"
    nat_delete_dir "${NAT_STACK_GENERATED_DIR}"
    "${KUBECTL:-kubectl}" delete namespace "${NAT_NAMESPACE}" --ignore-not-found=true >/dev/null || true
    k8s_wait_namespace_deletion "${NAT_NAMESPACE}" "${WAIT_TIMEOUT:-180s}"

    log_success "nat stack cleanup completed: ${NAT_STACK_ID}"
}

main "$@"
