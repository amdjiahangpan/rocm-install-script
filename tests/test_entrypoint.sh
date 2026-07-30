#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

ENTRYPOINT_STDOUT_FILE="${TEST_TEMP_ROOT}/entrypoint-stdout"
ENTRYPOINT_STDERR_FILE="${TEST_TEMP_ROOT}/entrypoint-stderr"
ENTRYPOINT_INPUT_FILE="${TEST_TEMP_ROOT}/entrypoint-input"
ENTRYPOINT_STDOUT=""
ENTRYPOINT_STDERR=""

capture_entrypoint() {
    local input=$1 status
    shift

    printf '%s' "$input" > "$ENTRYPOINT_INPUT_FILE"
    if run_entrypoint "$@" < "$ENTRYPOINT_INPUT_FILE" > "$ENTRYPOINT_STDOUT_FILE" 2> "$ENTRYPOINT_STDERR_FILE"; then
        status=0
    else
        status=$?
    fi
    ENTRYPOINT_STDOUT=$(<"$ENTRYPOINT_STDOUT_FILE")
    ENTRYPOINT_STDERR=$(<"$ENTRYPOINT_STDERR_FILE")
    return "$status"
}

count_occurrences() {
    local text=$1 expected=$2 count=0

    while [[ "$text" == *"$expected"* ]]; do
        text=${text#*"$expected"}
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

FLOW=""
record_entrypoint_step() { FLOW+="$1"$'\n'; }
is_interactive_terminal() { return 0; }
require_root() { record_entrypoint_step root; }
detect_system() {
    record_entrypoint_step system
    OS_ID=ubuntu
    OS_VERSION=24.04
    ARCH=x86_64
    KERNEL_VERSION=6.14.0-1020-oem
}
do_uninstall() { record_entrypoint_step uninstall; }
resolve_gpu_identity() { fail "menu uninstall must not resolve GPU/KFD identity"; }
resolve_install_plan() { fail "menu uninstall must not resolve an install plan"; }
kernel_policy_for() { fail "menu uninstall must not resolve kernel policy"; }
prepare_approved_kernel() { fail "menu uninstall must not prepare a kernel"; }

assert_success "menu uninstall enters the real main lifecycle" capture_entrypoint $'3\n'
assert_eq $'root\nsystem\nuninstall' "${FLOW%$'\n'}" "menu uninstall runs root, system, and uninstall in order"
assert_contains "$ENTRYPOINT_STDOUT" "1. Install or repair ROCm" "menu shows the install option"
assert_contains "$ENTRYPOINT_STDOUT" "2. Verify ROCm installation" "menu shows the verify option"
assert_contains "$ENTRYPOINT_STDOUT" "3. Uninstall ROCm" "menu shows the uninstall option"
assert_contains "$ENTRYPOINT_STDOUT" "4. Exit" "menu shows the exit option"

MAIN_CALL_COUNT=0
MOCK_MAIN_STATUS=0
CAPTURED_MAIN_ARGS=()
main() {
    MAIN_CALL_COUNT=$((MAIN_CALL_COUNT + 1))
    CAPTURED_MAIN_ARGS=("$@")
    return "$MOCK_MAIN_STATUS"
}

reset_entrypoint_capture() {
    MAIN_CALL_COUNT=0
    MOCK_MAIN_STATUS=0
    CAPTURED_MAIN_ARGS=()
    ENTRYPOINT_STDOUT=""
    ENTRYPOINT_STDERR=""
}

is_interactive_terminal() { return 1; }
reset_entrypoint_capture
assert_success "non-TTY no-argument entrypoint calls main without reading stdin" capture_entrypoint ""
assert_eq "1" "$MAIN_CALL_COUNT" "non-TTY no-argument entrypoint calls main once"
assert_eq "0" "${#CAPTURED_MAIN_ARGS[@]}" "non-TTY no-argument entrypoint passes no arguments"
assert_eq "" "$ENTRYPOINT_STDOUT$ENTRYPOINT_STDERR" "non-TTY no-argument entrypoint does not show a menu"

is_interactive_terminal() { return 0; }
reset_entrypoint_capture
MOCK_MAIN_STATUS=29
assert_status 29 "explicit arguments bypass the menu and preserve main status" capture_entrypoint $'3\n' --root-password 'two words * ?' '' --gpu-arch gfx1151
assert_eq "1" "$MAIN_CALL_COUNT" "explicit arguments call main once"
assert_eq "5" "${#CAPTURED_MAIN_ARGS[@]}" "explicit arguments retain their count"
assert_eq "--root-password" "${CAPTURED_MAIN_ARGS[0]}" "explicit argument order retains the option"
assert_eq "two words * ?" "${CAPTURED_MAIN_ARGS[1]}" "explicit argument bytes retain spaces and glob characters"
assert_eq "" "${CAPTURED_MAIN_ARGS[2]}" "explicit arguments retain an empty value"
assert_eq "--gpu-arch" "${CAPTURED_MAIN_ARGS[3]}" "explicit argument order retains the second option"
assert_eq "gfx1151" "${CAPTURED_MAIN_ARGS[4]}" "explicit argument order retains the final value"
assert_eq "" "$ENTRYPOINT_STDOUT$ENTRYPOINT_STDERR" "explicit arguments never show or read the menu"

reset_entrypoint_capture
MOCK_MAIN_STATUS=23
assert_status 23 "install menu choice preserves main status" capture_entrypoint $'1\n'
assert_eq "1" "$MAIN_CALL_COUNT" "install menu choice calls main once"
assert_eq "0" "${#CAPTURED_MAIN_ARGS[@]}" "install menu choice calls main with no arguments"

reset_entrypoint_capture
assert_success "verify menu choice dispatches" capture_entrypoint $'2\n'
assert_eq "1" "$MAIN_CALL_COUNT" "verify menu choice calls main once"
assert_eq "1" "${#CAPTURED_MAIN_ARGS[@]}" "verify menu choice passes one argument"
assert_eq "--verify-only" "${CAPTURED_MAIN_ARGS[0]}" "verify menu choice passes --verify-only"

reset_entrypoint_capture
assert_success "uninstall menu choice dispatches" capture_entrypoint $'3\n'
assert_eq "1" "$MAIN_CALL_COUNT" "uninstall menu choice calls main once"
assert_eq "1" "${#CAPTURED_MAIN_ARGS[@]}" "uninstall menu choice passes one argument"
assert_eq "--uninstall" "${CAPTURED_MAIN_ARGS[0]}" "uninstall menu choice passes --uninstall"

reset_entrypoint_capture
assert_success "exit menu choice succeeds without dispatch" capture_entrypoint $'4\n'
assert_eq "0" "$MAIN_CALL_COUNT" "exit menu choice does not call main"

reset_entrypoint_capture
assert_success "EOF at the menu succeeds without dispatch" capture_entrypoint ""
assert_eq "0" "$MAIN_CALL_COUNT" "EOF at the menu does not call main"

reset_entrypoint_capture
assert_success "invalid menu input retries until exit" capture_entrypoint $'invalid\n4\n'
assert_eq "0" "$MAIN_CALL_COUNT" "invalid input followed by exit does not call main"
assert_eq "Invalid selection. Enter 1, 2, 3, or 4." "$ENTRYPOINT_STDERR" "invalid input prints one concise stderr error"
assert_eq "1" "$(count_occurrences "$ENTRYPOINT_STDOUT" "1. Install or repair ROCm")" "invalid input does not repeat the install option"
assert_eq "1" "$(count_occurrences "$ENTRYPOINT_STDOUT" "2. Verify ROCm installation")" "invalid input does not repeat the verify option"
assert_eq "1" "$(count_occurrences "$ENTRYPOINT_STDOUT" "3. Uninstall ROCm")" "invalid input does not repeat the uninstall option"
assert_eq "1" "$(count_occurrences "$ENTRYPOINT_STDOUT" "4. Exit")" "invalid input does not repeat the exit option"
assert_eq "2" "$(count_occurrences "$ENTRYPOINT_STDOUT" "Select an action [1-4]: ")" "invalid input prints the non-newline prompt before both reads"

installer_source=$(<"${ROOT_DIR}/rocm-install.sh")
assert_contains "$installer_source" $'if [[ "${ROCM_INSTALL_LIBRARY_MODE:-}" != 1 ]]; then\n    run_entrypoint "$@"\nfi' "launcher dispatches through run_entrypoint"

finish_tests "entrypoint"
