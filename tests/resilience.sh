#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
LOG_DIR="$tmp/logs"
mkdir "$LOG_DIR"
LOG_FILE="$LOG_DIR/installer.log"
events="$tmp/events"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
fatal_action() { printf 'kept\n' > "$tmp/completed"; die 'Expected test failure'; printf 'unsafe\n' >> "$events"; }
failed_command() { false; printf 'unsafe\n' >> "$events"; }
failed_pipeline() { false | cat; printf 'unsafe\n' >> "$events"; }
failed_runner() { run_cmd 'Expected command failure' bash -c 'exit 7'; printf 'unsafe\n' >> "$events"; }
failed_stream() { run_cmd_stream 'Expected stream failure' bash -c 'exit 8'; printf 'unsafe\n' >> "$events"; }
cancelled_action() { return 130; }
: > "$events"
for action in fatal_action failed_command failed_pipeline failed_runner failed_stream cancelled_action; do
  run_menu_action "$action" >> "$tmp/output" 2>&1
done
[[ -f "$tmp/completed" ]] || fail 'completed state was lost'
[[ ! -s "$events" ]] || fail 'continued after an operation failed'
grep -q 'Operation cancelled' "$tmp/output" || fail 'cancellation not recognized'
grep -q 'exit 7' "$tmp/output" || fail 'command failure code lost'
grep -q 'exit 8' "$tmp/output" || fail 'stream failure code lost'
[[ "$-" == *e* ]] || fail 'errexit not restored'

trap ':' INT
previous_trap=$(trap -p INT)
set +e
run_menu_action failed_command >> "$tmp/output" 2>&1
[[ "$-" != *e* ]] || fail 'caller shell options changed'
[[ $(trap -p INT) == "$previous_trap" ]] || fail 'caller INT trap changed'
set -e
trap - INT

# An output/log pipeline failure is an operation failure even if the command succeeds.
(
  tee() { command cat >/dev/null; return 9; }
  if run_cmd_stream 'Broken output test' printf 'example\n'; then fail 'output failure ignored'; fi
) >> "$tmp/output" 2>&1

# The actual submenu must survive a failed action and execute the next selection.
read_input() { local line; IFS= read -r line || return 130; printf '%s' "$line"; }
show_panel_menu() { :; }
update_panel() { false; printf 'unsafe\n' >> "$events"; }
compose_action() { printf 'next action %s\n' "$2" >> "$events"; }
handle_panel_menu <<< $'4\n5\n0' >> "$tmp/output" 2>&1
grep -Fxq 'next action status' "$events" || fail 'did not return to panel menu'
if grep -q unsafe "$events"; then fail 'menu disabled errexit in action'; fi
handle_panel_menu </dev/null >> "$tmp/output" 2>&1

# Cancelling removal must preserve both the Panel and its reverse proxy/state.
PANEL_DIR="$tmp/panel"
PANEL_STATE_FILE="$tmp/panel-state"
mkdir "$PANEL_DIR"
printf 'saved\n' > "$PANEL_STATE_FILE"
load_panel_state() { :; }
assert_managed_dir() { :; }
remove_panel_reverse_proxy() { printf 'proxy removed\n' >> "$events"; }
confirm() { return 1; }
run_menu_action remove_panel >> "$tmp/output" 2>&1
ask_delete_confirmation() { printf -v "$1" '%s' 'wrong'; }
run_menu_action remove_panel_with_volumes >> "$tmp/output" 2>&1
[[ -d "$PANEL_DIR" && -f "$PANEL_STATE_FILE" ]] || fail 'cancelled removal changed saved installation'
if grep -q 'proxy removed' "$events"; then fail 'cancelled removal deleted proxy'; fi

# A failed shutdown must also preserve the saved files and reverse proxy.
printf 'saved compose\n' > "$PANEL_DIR/docker-compose.yml"
confirm() { return 0; }
run_cmd_stream() { return 1; }
run_menu_action remove_panel >> "$tmp/output" 2>&1
[[ -d "$PANEL_DIR" && -f "$PANEL_STATE_FILE" ]] || fail 'failed shutdown removed installation'
if grep -q 'proxy removed' "$events"; then fail 'failed shutdown deleted proxy'; fi

printf 'Resilience tests passed.\n'
