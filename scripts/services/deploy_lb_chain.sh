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
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/image_delivery.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab deploy-lb --stack-id <id> [platform-options]
EOF
}

main() {
    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown deploy-lb argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    image_delivery_log_mode "deploy-lb"
    lb_stack_prepare_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    lb_require_basic_ready

    log_info "deploying lb stack ${LB_STACK_ID} with rendered assets from ${LB_STACK_GENERATED_DIR}"
    lb_apply_dir "${LB_STACK_GENERATED_DIR}"
    lb_wait_ready "${WAIT_TIMEOUT:-180s}"

    log_success "lb stack deploy completed: ${LB_STACK_ID}"
}

main "$@"
