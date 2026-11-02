#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/gateway.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/gateway_stack.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab render-gateway-stack --stack-id <id> [platform-options]
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
                die "unknown render-gateway-stack argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    gateway_stack_prepare_rendered_runtime
    gateway_render_dir "${GATEWAY_STACK_GENERATED_DIR}"

    log_info "rendered gateway stack ${GATEWAY_STACK_ID} into ${GATEWAY_STACK_GENERATED_DIR}"
    log_info "resolved values file: ${GATEWAY_STACK_RESOLVED_VALUES_FILE}"
    gateway_stack_print_plan
}

main "$@"
