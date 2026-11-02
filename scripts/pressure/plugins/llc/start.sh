#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: start.sh --instance-id <id> --intensity <n> [--cpuset <csv>] --duration <seconds> --pid-file <path> --log-file <path> [--param key=value]
EOF
}

build_helper_if_needed() {
    local source_file="${SCRIPT_DIR}/helpers/llc_pressure.c"
    local output_file="${SCRIPT_DIR}/helpers/llc-pressure"

    [[ -f "${source_file}" ]] || {
        printf 'missing LLC helper source: %s\n' "${source_file}" >&2
        exit 1
    }

    if [[ ! -x "${output_file}" || "${source_file}" -nt "${output_file}" ]]; then
        cc -O2 -pthread -o "${output_file}" "${source_file}"
    fi

    printf '%s\n' "${output_file}"
}

intensity_to_working_set_mb() {
    case "$1" in
        0) printf '0\n' ;;
        1) printf '8\n' ;;
        2) printf '32\n' ;;
        3) printf '128\n' ;;
        4) printf '512\n' ;;
        5) printf '2048\n' ;;
        *)
            printf 'unsupported llc intensity: %s\n' "$1" >&2
            exit 1
            ;;
    esac
}

intensity_to_workers() {
    case "$1" in
        0|1|2) printf '1\n' ;;
        3) printf '2\n' ;;
        4) printf '4\n' ;;
        5) printf '8\n' ;;
        *)
            printf 'unsupported llc intensity: %s\n' "$1" >&2
            exit 1
            ;;
    esac
}

main() {
    local instance_id='' intensity='' cpuset='' duration='' pid_file='' log_file=''
    local helper_bin='' working_set_mb='' workers='' stride_bytes='64'
    local param_key='' param_value=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance-id)
                instance_id=${2:-}
                shift 2
                ;;
            --intensity)
                intensity=${2:-}
                shift 2
                ;;
            --cpuset)
                cpuset=${2:-}
                shift 2
                ;;
            --duration)
                duration=${2:-}
                shift 2
                ;;
            --pid-file)
                pid_file=${2:-}
                shift 2
                ;;
            --log-file)
                log_file=${2:-}
                shift 2
                ;;
            --param)
                [[ $# -ge 2 ]] || {
                    usage >&2
                    exit 1
                }
                if [[ "${2}" != *=* ]]; then
                    printf 'invalid --param (expected key=value): %s\n' "${2}" >&2
                    exit 1
                fi
                param_key=${2%%=*}
                param_value=${2#*=}
                case "${param_key}" in
                    workers)
                        workers=${param_value}
                        ;;
                    stride_bytes)
                        stride_bytes=${param_value}
                        ;;
                    *)
                        printf 'unsupported LLC plugin param: %s\n' "${param_key}" >&2
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'unknown LLC plugin argument: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done

    [[ -n "${instance_id}" ]] || {
        printf 'missing --instance-id\n' >&2
        exit 1
    }
    [[ -n "${intensity}" ]] || {
        printf 'missing --intensity\n' >&2
        exit 1
    }
    cpuset=${cpuset:-4}
    [[ -n "${duration}" ]] || {
        printf 'missing --duration\n' >&2
        exit 1
    }
    [[ -n "${pid_file}" ]] || {
        printf 'missing --pid-file\n' >&2
        exit 1
    }
    [[ -n "${log_file}" ]] || {
        printf 'missing --log-file\n' >&2
        exit 1
    }

    helper_bin="$(build_helper_if_needed)"
    working_set_mb="$(intensity_to_working_set_mb "${intensity}")"
    if [[ -z "${workers}" ]]; then
        workers="$(intensity_to_workers "${intensity}")"
    fi

    mkdir -p "$(dirname "${pid_file}")" "$(dirname "${log_file}")"

    taskset -c "${cpuset}" "${helper_bin}" \
        --working-set-mb "${working_set_mb}" \
        --workers "${workers}" \
        --stride-bytes "${stride_bytes}" > "${log_file}" 2>&1 &
    printf '%s\n' "$!" > "${pid_file}"
}

main "$@"
