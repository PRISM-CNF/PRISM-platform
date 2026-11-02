#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: stop.sh --pid-file <path>
EOF
}

main() {
    local pid_file='' pid=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid-file)
                pid_file=${2:-}
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'unknown LLC stop argument: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done

    [[ -n "${pid_file}" ]] || {
        printf 'missing --pid-file\n' >&2
        exit 1
    }
    [[ -f "${pid_file}" ]] || exit 0

    pid="$(tr -d '[:space:]' < "${pid_file}")"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            if ! kill -0 "${pid}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        if kill -0 "${pid}" >/dev/null 2>&1; then
            kill -9 "${pid}" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "${pid_file}"
}

main "$@"

