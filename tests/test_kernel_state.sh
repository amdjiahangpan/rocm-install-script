#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

INSTALLER_STATE_ROOT="${TEST_TEMP_ROOT}/state"
KERNEL_BOOT_DIR="${TEST_TEMP_ROOT}/boot"
GRUB_CONFIG_FILE="${TEST_TEMP_ROOT}/grub.cfg"
GRUB_ENV_FILE="${TEST_TEMP_ROOT}/grubenv"
BOOT_ID_FILE="${TEST_TEMP_ROOT}/boot-id"
mkdir -p "$KERNEL_BOOT_DIR"
printf 'kernel image\n' > "${KERNEL_BOOT_DIR}/vmlinuz-6.8.0-138-generic"
printf 'boot-a\n' > "$BOOT_ID_FILE"
cat > "$GRUB_CONFIG_FILE" <<'EOF'
submenu 'Advanced options for Ubuntu' {
    menuentry 'Ubuntu, with Linux 6.8.0-138-generic' {
    }
}
EOF

expected_entry='Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-138-generic'
assert_eq "$expected_entry" "$(resolve_grub_kernel_entry '6.8.*-generic')" "GRUB resolver selects the exact reviewed kernel entry"
assert_fails "GRUB resolver rejects an unavailable target series" resolve_grub_kernel_entry '6.14.*-oem'

assert_success "pending kernel state is written atomically" write_pending_kernel_state '6.8.*-generic' "$expected_entry" boot-a 1
assert_success "pending kernel state can be read" read_pending_kernel_state
assert_eq '6.8.*-generic' "$PENDING_KERNEL_TARGET" "pending state retains the target"
assert_eq "$expected_entry" "$PENDING_KERNEL_ENTRY" "pending state retains the boot entry"
assert_eq boot-a "$PENDING_KERNEL_BOOT_ID" "pending state retains the pre-reboot boot ID"
assert_eq 1 "$PENDING_KERNEL_ATTEMPTS" "pending state retains the attempt count"

KERNEL_VERSION=6.8.0-138-generic
assert_success "matching kernel completes pending state" reconcile_pending_kernel_state
assert_fails "successful pending state is removed" test -e "${INSTALLER_STATE_ROOT}/pending-kernel"

assert_success "failed-boot test state is written" write_pending_kernel_state '6.8.*-generic' "$expected_entry" boot-a 1
printf 'boot-b\n' > "$BOOT_ID_FILE"
KERNEL_VERSION=7.0.0-28-generic
reset_test_state
run_cmd() { recording_run_cmd "$@"; }
assert_status 22 "a changed boot ID with the wrong kernel fails permanently" reconcile_pending_kernel_state
assert_not_contains "$RECORDED_COMMANDS" reboot "failed kernel selection never triggers another reboot"
assert_success "failed pending state remains for diagnosis" test -e "${INSTALLER_STATE_ROOT}/pending-kernel"

rm -f "${INSTALLER_STATE_ROOT}/pending-kernel"
printf 'boot-a\n' > "$BOOT_ID_FILE"
assert_success "not-yet-rebooted state is written" write_pending_kernel_state '6.8.*-generic' "$expected_entry" boot-a 1
assert_status 21 "unchanged boot ID reports a pending reboot" reconcile_pending_kernel_state
assert_not_contains "$RECORDED_COMMANDS" reboot "pending state does not reboot implicitly"

MOCK_NEXT_ENTRY=''
MOCK_PREV_SAVED_ENTRY=''
MOCK_GRUB_VERIFY=true
MOCK_GRUB_ARMED=false
run_cmd() {
    recording_run_cmd "$@"
    if [[ "$1" == grub-reboot ]]; then
        MOCK_NEXT_ENTRY=$2
        MOCK_GRUB_ARMED=true
    elif [[ "$1" == grub-editenv && "${3:-}" == unset ]]; then
        case "${4:-}" in
            next_entry) MOCK_NEXT_ENTRY='' ;;
            prev_saved_entry) MOCK_PREV_SAVED_ENTRY='' ;;
        esac
        MOCK_GRUB_ARMED=false
    elif [[ "$1" == grub-editenv && "${3:-}" == set ]]; then
        case "${4:-}" in
            next_entry=*) MOCK_NEXT_ENTRY=${4#next_entry=} ;;
            prev_saved_entry=*) MOCK_PREV_SAVED_ENTRY=${4#prev_saved_entry=} ;;
        esac
    fi
}
capture_cmd() {
    if [[ "$*" == "grub-editenv ${GRUB_ENV_FILE} list" ]]; then
        if [[ "$MOCK_GRUB_VERIFY" != true && "$MOCK_GRUB_ARMED" == true ]]; then
            printf 'next_entry=%s\n' 'wrong-entry'
        elif [[ -n "$MOCK_NEXT_ENTRY" ]]; then
            printf 'next_entry=%s\n' "$MOCK_NEXT_ENTRY"
        fi
        [[ -z "$MOCK_PREV_SAVED_ENTRY" ]] || printf 'prev_saved_entry=%s\n' "$MOCK_PREV_SAVED_ENTRY"
        return 0
    fi
    return 1
}
rm -f "${INSTALLER_STATE_ROOT}/pending-kernel"
INSTALL_PLAN=([kernel_target]='6.8.*-generic' [kernel_package]=linux-generic)
KERNEL_VERSION=7.0.0-28-generic
PREPARE_KERNEL=true
REBOOT_AFTER_KERNEL=true
NON_INTERACTIVE=true
REBOOT_DELAY=-1

original_state_root=$INSTALLER_STATE_ROOT
INSTALLER_STATE_ROOT=relative-state
reset_test_state
assert_fails "state-write failure prevents GRUB one-shot selection" prepare_kernel_reboot
assert_not_contains "$RECORDED_COMMANDS" "grub-reboot" "GRUB remains untouched when pending state cannot be written"
INSTALLER_STATE_ROOT=$original_state_root

MOCK_NEXT_ENTRY='maintenance-entry'
MOCK_PREV_SAVED_ENTRY='saved-default'
MOCK_GRUB_VERIFY=false
MOCK_GRUB_ARMED=false
reset_test_state
assert_fails "failed GRUB verification restores existing one-shot state" prepare_kernel_reboot
assert_eq maintenance-entry "$MOCK_NEXT_ENTRY" "failed setup restores the previous next entry"
assert_eq saved-default "$MOCK_PREV_SAVED_ENTRY" "failed setup restores the previous saved entry"
assert_contains "$RECORDED_COMMANDS" "set next_entry=maintenance-entry" "rollback rewrites the previous next entry"
assert_contains "$RECORDED_COMMANDS" "set prev_saved_entry=saved-default" "rollback rewrites the previous saved entry"
assert_fails "failed GRUB verification removes pending state" test -e "${INSTALLER_STATE_ROOT}/pending-kernel"
MOCK_GRUB_VERIFY=true
MOCK_GRUB_ARMED=false
MOCK_NEXT_ENTRY=''
MOCK_PREV_SAVED_ENTRY=''
reset_test_state
assert_status 21 "explicit one-shot setup records a reboot-pending state" prepare_kernel_reboot
assert_contains "$RECORDED_COMMANDS" "grub-reboot" "one-shot setup invokes GRUB one-shot selection"
assert_contains "$RECORDED_COMMANDS" "6.8.0-138-generic" "one-shot setup selects the exact target release"
assert_success "one-shot setup writes pending state" test -s "${INSTALLER_STATE_ROOT}/pending-kernel"
assert_not_contains "$RECORDED_COMMANDS" $'reboot\n' "skip-reboot suppresses the final reboot command"

finish_tests "kernel state"
