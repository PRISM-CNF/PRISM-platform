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
source "${PLATFORM_REPO_ROOT}/scripts/lib/categraf.sh"

main() {
    local live_config expected_url

    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    k8s_require_cluster
    k8s_log_context
    categraf_run_asset_script "${CATEGRAF_CHECK_SCRIPT}" "check"

    expected_url="http://${N9E_SERVICE_NAME}.${N9E_NAMESPACE}.svc.cluster.local:${N9E_HTTP_PORT}/prometheus/v1/write"
    live_config="$("${KUBECTL:-kubectl}" get configmap "${CATEGRAF_CONFIGMAP_NAME}" -n "${CATEGRAF_NAMESPACE}" -o jsonpath='{.data.config\.toml}')"
    grep -Fq "${expected_url}" <<< "${live_config}" \
        || die "live categraf config does not point to n9e /prometheus/v1/write"
    log_info "verified categraf remote write target: ${expected_url}"

    log_success "platform categraf check completed"
}

main "$@"
