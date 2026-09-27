#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
STATE_DIR="$tmp/state"
LOG_DIR="$tmp/logs"
LOG_FILE="$LOG_DIR/test.log"
mkdir "$LOG_DIR"
OPERATION_TRACKING_ENABLED=1
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
failed_action() {
  section 'Prepare configuration'
  printf 'saved\n' > "$tmp/completed"
  operation_set_step 'Check backend availability' 'Repair the backend before continuing.'
  false
  touch "$tmp/unsafe"
}
run_menu_action failed_action > "$tmp/output" 2>&1
[[ -f "$tmp/completed" && ! -e "$tmp/unsafe" ]] || fail 'operation did not stop safely'
[[ $(operation_read_field status) == failed ]] || fail 'failure not recorded'
[[ $(operation_read_field step) == 'Check backend availability' ]] || fail 'failed step lost'
grep -Fq 'Stopped at: Check backend availability' "$tmp/output" || fail 'failed step not shown'
operation_report_last > "$tmp/report"
grep -Fxq last_status=failed "$tmp/report" || fail 'failure absent from report'
nested_action() ( operation_set_step 'Nested failure' 'Specific recovery hint'; false )
run_menu_action nested_action > "$tmp/output" 2>&1
[[ $(operation_read_field step) == 'Nested failure' ]] || fail 'nested step overwritten by parent'
grep -Fq 'Specific recovery hint' "$tmp/output" || fail 'recovery hint lost'

# Inspection must not replace the useful previous failure context.
diagnose_installation() { :; }
run_menu_action diagnose_installation
[[ $(operation_read_field status) == failed ]] || fail 'inspection overwrote failure'

# Even corrupted/untrusted metadata cannot copy arbitrary input into the report.
printf 'action=private-token\nstatus=private-password\nexit_code=private-token\nupdated=private-token\nstep=private-token\nhint=private-password\n' > "$STATE_DIR/last-operation"
operation_report_last > "$tmp/report"
if grep -q private- "$tmp/report"; then fail 'report included untrusted metadata'; fi
back_action() { return 131; }
run_menu_action back_action > "$tmp/output" 2>&1
[[ $(operation_read_field status) == back ]] || fail 'back not recorded'
grep -Fq 'previous menu' "$tmp/output" || fail 'back treated as a failure'
run_menu_action true
[[ $(operation_read_field status) == success ]] || fail 'success not recorded'
printf 'Operation context tests passed.\n'
