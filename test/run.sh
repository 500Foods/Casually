#!/usr/bin/env bash
# Run one phase gate, or every gate that exists when no number is given.
# Index gates are test/phaseN.lua. Backup gates are test/backup_phaseN.lua.
set -euo pipefail

cd "$(dirname "$0")/.."

run_lua() {
    local test="$1"
    env -u LUA_PATH -u LUA_CPATH -u LUA_INIT lua "${test}"
}

run_index_phase() {
    local n="$1"
    local test="test/phase${n}.lua"
    if [[ ! -f "${test}" ]]; then
        echo "casually_index: no gate for phase ${n}" >&2
        exit 1
    fi
    run_lua "${test}"
}

run_backup_phase() {
    local n="$1"
    local test="test/backup_phase${n}.lua"
    if [[ ! -f "${test}" ]]; then
        echo "casually_backup: no gate for phase ${n}" >&2
        exit 1
    fi
    run_lua "${test}"
}

run_all_index() {
    local found=0
    local test n
    for test in test/phase*.lua; do
        [[ -f "${test}" ]] || continue
        found=1
        n="${test#test/phase}"
        n="${n%.lua}"
        run_index_phase "${n}"
    done
    if [[ "${found}" -eq 0 ]]; then
        echo "casually_index: no phase gates" >&2
        exit 1
    fi
}

run_all_backup() {
    local found=0
    local test n
    for test in test/backup_phase*.lua; do
        [[ -f "${test}" ]] || continue
        found=1
        n="${test#test/backup_phase}"
        n="${n%.lua}"
        run_backup_phase "${n}"
    done
    if [[ "${found}" -eq 0 ]]; then
        echo "casually_backup: no phase gates" >&2
        exit 1
    fi
}

usage() {
    echo "usage: test/run.sh [phase]" >&2
    echo "       test/run.sh backup [phase]" >&2
    exit 1
}

if [[ $# -eq 0 ]]; then
    run_all_index
    exit 0
fi

if [[ "$1" == "backup" ]]; then
    if [[ $# -eq 1 ]]; then
        run_all_backup
        exit 0
    fi
    if [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]]; then
        run_backup_phase "$2"
        exit 0
    fi
    usage
fi

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
    usage
fi

run_index_phase "$1"
