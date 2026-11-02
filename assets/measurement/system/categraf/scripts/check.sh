#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    local desired ready current

    require_command "${KUBECTL}"
    require_cluster

    namespace_exists || die "namespace not found: ${NAMESPACE}"
    daemonset_exists || die "daemonset not found: ${DAEMONSET_NAME}"

    desired="$("${KUBECTL}" get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.desiredNumberScheduled}')"
    current="$("${KUBECTL}" get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.currentNumberScheduled}')"
    ready="$("${KUBECTL}" get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.numberReady}')"

    log_info "daemonset desired=${desired} current=${current} ready=${ready}"
    (( desired > 0 )) || die "daemonset desiredNumberScheduled is zero"
    [[ "${desired}" == "${current}" ]] || die "currentNumberScheduled mismatch: desired=${desired} current=${current}"
    [[ "${desired}" == "${ready}" ]] || die "numberReady mismatch: desired=${desired} ready=${ready}"

    "${KUBECTL}" wait --for=condition=Ready pod -l "${POD_SELECTOR}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}" >/dev/null

    log_success "categraf daemonset is ready"
    print_daemonset_summary
    print_pod_summary
}

main "$@"
