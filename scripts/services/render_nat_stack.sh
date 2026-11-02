#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat_stack.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab render-nat-stack --stack-id <id> [platform-options]
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
                die "unknown render-nat-stack argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    nat_stack_prepare_rendered_runtime
    nat_render_dir "${NAT_STACK_GENERATED_DIR}"

    log_info "rendered nat stack ${NAT_STACK_ID} into ${NAT_STACK_GENERATED_DIR}"
    log_info "resolved values file: ${NAT_STACK_RESOLVED_VALUES_FILE}"
    nat_stack_print_plan
}

main "$@"
