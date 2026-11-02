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
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    lb_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context

    log_info "cleaning lb stack ${LB_STACK_ID} in namespace ${LB_NAMESPACE} without touching basic or other stacks"
    lb_delete_dir "${LB_STACK_GENERATED_DIR}"
    "${KUBECTL:-kubectl}" delete namespace "${LB_NAMESPACE}" --ignore-not-found=true >/dev/null || true
    k8s_wait_namespace_deletion "${LB_NAMESPACE}" "${WAIT_TIMEOUT:-180s}"

    log_success "lb stack cleanup completed: ${LB_STACK_ID}"
}

main "$@"
