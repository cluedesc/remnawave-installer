#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
STATE_DIR="$tmp/state"
LOG_DIR="$tmp/logs"
LOG_FILE="$LOG_DIR/test.log"
mkdir "$LOG_DIR"
events="$tmp/events"
need_root() { :; }
check_os() { :; }
prepare_log() { :; }
show_startup_support_notice() { :; }
show_dashboard() { printf 'dashboard\n'; }
read_input() { local value; IFS= read -r value || return 130; printf '%s' "$value"; }
resume_panel_setup() { printf 'resume\n' >> "$events"; }
reconfigure_panel_https() { printf 'https\n' >> "$events"; }
diagnose_installation() { printf 'diagnose\n' >> "$events"; }
export_diagnostic_report() { printf 'report\n' >> "$events"; }
list_backups() { printf 'list\n' >> "$events"; }
verify_backup() { printf 'verify\n' >> "$events"; }
configure_backup_schedule() { printf 'schedule\n' >> "$events"; }
show_backup_schedule() { printf 'schedule_status\n' >> "$events"; }
(
  main <<< $'1\n4\n/back\n2\n12\n13\n0\n4\n4\n5\n0\n7\n3\n4\n5\n6\n0\n9\n0'
) > "$tmp/output" 2>&1
printf 'resume\nhttps\nresume\ndiagnose\nreport\nlist\nverify\nschedule\nschedule_status\ndiagnose\n' > "$tmp/expected"
cmp "$events" "$tmp/expected"
grep -q dashboard "$tmp/output"
printf 'Menu integration tests passed.\n'
