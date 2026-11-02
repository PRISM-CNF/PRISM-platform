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
source "${PLATFORM_REPO_ROOT}/scripts/lib/template.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/template_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    template_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    template_warn_if_gateway_present

    log_info "cleaning template stack ${TEMPLATE_STACK_ID} in namespace ${TEMPLATE_NAMESPACE} without touching gateway/basic or other stacks"
    template_delete_dir "${TEMPLATE_STACK_GENERATED_DIR}"
    "${KUBECTL:-kubectl}" delete namespace "${TEMPLATE_NAMESPACE}" --ignore-not-found=true >/dev/null || true
    k8s_wait_namespace_deletion "${TEMPLATE_NAMESPACE}" "${WAIT_TIMEOUT:-180s}"

    log_success "template stack cleanup completed: ${TEMPLATE_STACK_ID}"
}

main "$@"
