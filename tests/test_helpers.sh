#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROCM_INSTALL_LIBRARY_MODE=1
source "${ROOT_DIR}/rocm-install.sh"

PASS_COUNT=0
TEST_TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rocm-install-tests.XXXXXX")
trap 'rm -rf -- "$TEST_TEMP_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_eq() {
    local expected=$1 actual=$2 message=$3
    [[ "$actual" == "$expected" ]] || fail "${message} (expected ${expected@Q}, got ${actual@Q})"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_contains() {
    local text=$1 expected=$2 message=$3
    [[ "$text" == *"$expected"* ]] || fail "${message} (missing ${expected@Q})"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_not_contains() {
    local text=$1 unexpected=$2 message=$3
    [[ "$text" != *"$unexpected"* ]] || fail "${message} (found ${unexpected@Q})"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_command_before() {
    local first=$1 second=$2 commands=$3 message=$4 prefix

    [[ "$commands" == *"$first"* && "$commands" == *"$second"* ]] || fail "${message} (missing command)"
    prefix=${commands%%"$second"*}
    [[ "$prefix" == *"$first"* ]] || fail "${message} (wrong order)"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_success() {
    local message=$1
    shift
    "$@" || fail "$message"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_fails() {
    local message=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "${message} (unexpected success)"
    fi
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_status() {
    local expected=$1 message=$2 actual
    shift 2
    if "$@"; then
        actual=0
    else
        actual=$?
    fi
    assert_eq "$expected" "$actual" "$message"
}

reset_test_state() {
    RECORDED_COMMANDS=""
    RUN_CMD_STATUS=0
}

recording_run_cmd() {
    local argument quoted command_line=""
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_line+="${command_line:+ }${quoted}"
    done
    RECORDED_COMMANDS+="${command_line}"$'\n'
    return "${RUN_CMD_STATUS:-0}"
}

finish_tests() {
    printf 'PASS: %d %s checks\n' "$PASS_COUNT" "$1"
}
