#!/usr/bin/env bash

if [[ -n "${NSM_OVS_VICTORIAMETRICS_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_VICTORIAMETRICS_SH_LOADED=1

victoriametrics_assets_require_synced() {
    [[ -d "${VICTORIAMETRICS_ASSETS_ROOT}" ]] || die "victoriametrics assets root not found: ${VICTORIAMETRICS_ASSETS_ROOT}; verify the bundled assets"
    [[ -d "${VICTORIAMETRICS_MANIFESTS_BASE_DIR}" ]] || die "victoriametrics manifest assets not found: ${VICTORIAMETRICS_MANIFESTS_BASE_DIR}; verify the bundled assets"
    [[ -x "${VICTORIAMETRICS_DEPLOY_SCRIPT}" ]] || die "victoriametrics deploy asset script not found or not executable: ${VICTORIAMETRICS_DEPLOY_SCRIPT}; verify the bundled assets"
    [[ -x "${VICTORIAMETRICS_CHECK_SCRIPT}" ]] || die "victoriametrics check asset script not found or not executable: ${VICTORIAMETRICS_CHECK_SCRIPT}; verify the bundled assets"
    [[ -x "${VICTORIAMETRICS_CLEANUP_SCRIPT}" ]] || die "victoriametrics cleanup asset script not found or not executable: ${VICTORIAMETRICS_CLEANUP_SCRIPT}; verify the bundled assets"
    [[ -f "${VICTORIAMETRICS_COMMON_LIB_SCRIPT}" ]] || die "victoriametrics common asset library not found: ${VICTORIAMETRICS_COMMON_LIB_SCRIPT}; verify the bundled assets"
}

victoriametrics_run_asset_script() {
    local script_path=$1
    local action_label=$2

    victoriametrics_assets_require_synced
    log_info "running victoriametrics ${action_label} asset script: ${script_path}"
    "${script_path}"
}
