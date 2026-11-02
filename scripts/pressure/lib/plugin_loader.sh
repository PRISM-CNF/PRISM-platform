#!/usr/bin/env bash

if [[ -n "${NSM_OVS_PRESSURE_PLUGIN_LOADER_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_PRESSURE_PLUGIN_LOADER_SH_LOADED=1

PRESSURE_PLUGIN_REQUIRED_FIELDS=(
    PLUGIN_NAME
    PLUGIN_DIMENSION
    PLUGIN_VERSION
    PLUGIN_INTENSITY_GRID
    PLUGIN_INTENSITY_UNIT
    PLUGIN_INTENSITY_MAPPING
    PLUGIN_RECOMMENDED_CPUSET
    PLUGIN_SAFE_TO_RUN_ON_VNF_CORE
)

pressure_plugin_root_dir() {
    printf '%s\n' "${PLATFORM_REPO_ROOT}/scripts/pressure/plugins"
}

pressure_plugin_dir() {
    local plugin_name=$1
    printf '%s/%s\n' "$(pressure_plugin_root_dir)" "${plugin_name}"
}

pressure_plugin_clear_loaded_state() {
    PRESSURE_PLUGIN_DIR=''
    PRESSURE_PLUGIN_START_SCRIPT=''
    PRESSURE_PLUGIN_STOP_SCRIPT=''
    PLUGIN_NAME=''
    PLUGIN_DIMENSION=''
    PLUGIN_VERSION=''
    PLUGIN_INTENSITY_GRID=''
    PLUGIN_INTENSITY_UNIT=''
    PLUGIN_INTENSITY_MAPPING=''
    PLUGIN_REQUIRES_TOOLS=''
    PLUGIN_REQUIRES_CAPS=''
    PLUGIN_KNOWN_SIDE_EFFECTS=''
    PLUGIN_RECOMMENDED_CPUSET=''
    PLUGIN_SAFE_TO_RUN_ON_VNF_CORE=''
    PLUGIN_STANDALONE=''
    PLUGIN_SUPPORTS_COMPOSITION=''
}

pressure_plugin_validate_loaded() {
    local field value

    [[ -d "${PRESSURE_PLUGIN_DIR}" ]] || die "pressure plugin dir not found: ${PRESSURE_PLUGIN_DIR:-}"
    [[ -x "${PRESSURE_PLUGIN_START_SCRIPT}" ]] || die "pressure plugin start.sh is not executable: ${PRESSURE_PLUGIN_START_SCRIPT:-}"
    [[ -x "${PRESSURE_PLUGIN_STOP_SCRIPT}" ]] || die "pressure plugin stop.sh is not executable: ${PRESSURE_PLUGIN_STOP_SCRIPT:-}"

    for field in "${PRESSURE_PLUGIN_REQUIRED_FIELDS[@]}"; do
        value="$(eval "printf '%s' \"\${${field}:-}\"")"
        [[ -n "${value}" ]] || die "pressure plugin missing required field ${field} in ${PRESSURE_PLUGIN_DIR}/plugin.env"
    done
}

pressure_plugin_load() {
    local plugin_name=$1
    local plugin_dir plugin_env

    pressure_plugin_clear_loaded_state
    plugin_dir="$(pressure_plugin_dir "${plugin_name}")"
    plugin_env="${plugin_dir}/plugin.env"

    [[ -d "${plugin_dir}" ]] || die "pressure plugin not found: ${plugin_name}"
    [[ -f "${plugin_env}" ]] || die "pressure plugin metadata missing: ${plugin_env}"

    PRESSURE_PLUGIN_DIR="${plugin_dir}"
    PRESSURE_PLUGIN_START_SCRIPT="${plugin_dir}/start.sh"
    PRESSURE_PLUGIN_STOP_SCRIPT="${plugin_dir}/stop.sh"

    # shellcheck source=/dev/null
    source "${plugin_env}"
    pressure_plugin_validate_loaded
}

pressure_plugin_supports_intensity() {
    local intensity=$1
    local token

    IFS=',' read -r -a pressure_intensities <<< "${PLUGIN_INTENSITY_GRID}"
    for token in "${pressure_intensities[@]}"; do
        if [[ "${token}" == "${intensity}" ]]; then
            return 0
        fi
    done
    return 1
}

pressure_plugin_intensity_physical() {
    local intensity=$1
    local mapping token key value

    mapping="${PLUGIN_INTENSITY_MAPPING}"
    IFS=',' read -r -a pressure_mappings <<< "${mapping}"
    for token in "${pressure_mappings[@]}"; do
        key="${token%%:*}"
        value="${token#*:}"
        if [[ "${key}" == "${intensity}" ]]; then
            printf '%s%s\n' "${value}" "${PLUGIN_INTENSITY_UNIT}"
            return 0
        fi
    done
    return 1
}

