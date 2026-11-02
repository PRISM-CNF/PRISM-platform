#!/usr/bin/env bash

# CPU-list utilities shared by sampling and pressure tools (Bash 4.3+).
cpuset_role_key() {
    printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

cpuset_expand() {
    local raw=${1:-} part start end cpu
    local -a parts=() numbers=()
    raw="${raw//[[:space:]]/}"
    [[ -n "${raw}" && "${raw}" != ,* && "${raw}" != *, && "${raw}" != *,,* ]] || return 1
    IFS=',' read -r -a parts <<< "${raw}"
    for part in "${parts[@]}"; do
        if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=$((10#${BASH_REMATCH[1]}))
            end=$((10#${BASH_REMATCH[2]}))
            (( start <= end && end <= 1048575 )) || return 1
            for ((cpu=start; cpu<=end; cpu++)); do numbers+=("${cpu}"); done
        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            numbers+=("$((10#${part}))")
        else
            return 1
        fi
    done
    printf '%s\n' "${numbers[@]}" | sort -nu
}

cpuset_compact() {
    sort -nu | awk '
        NR == 1 { start = prev = $1; next }
        $1 == prev + 1 { prev = $1; next }
        { emit(); start = prev = $1 }
        function emit() {
            printf "%s%s", sep, start
            if (start != prev) printf "-%s", prev
            sep = ","
        }
        END { if (NR) { emit(); print "" } }
    '
}

cpuset_map_role_field() {
    local -n cpuset_fields=$1
    local role_key
    role_key="$(cpuset_role_key "$2")"
    printf '%s' "${cpuset_fields[CPUSET_${role_key}_$3]:-}"
}
