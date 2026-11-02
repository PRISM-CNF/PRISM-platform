#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb_stack.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab render-lb-stack --stack-id <id> [platform-options]
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
                die "unknown render-lb-stack argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    lb_stack_prepare_rendered_runtime
    lb_render_dir "${LB_STACK_GENERATED_DIR}"

    log_info "rendered lb stack ${LB_STACK_ID} into ${LB_STACK_GENERATED_DIR}"
    log_info "resolved values file: ${LB_STACK_RESOLVED_VALUES_FILE}"
    lb_stack_print_plan
}

main "$@"
