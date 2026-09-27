#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
PANEL_DIR="$work/panel" NODE_DIR="$work/node" STATE_DIR="$work/state" BACKUP_ROOT="$work/backups"
mkdir -p "$NODE_DIR" "$STATE_DIR" "$BACKUP_ROOT/.verified" "$work/units"
printf 'node\n' > "$NODE_DIR/config"
ok() { :; }
warn() { printf '%s\n' "$*" >> "$work/warnings"; }
flock() { [ "$*" = '-n 9' ] && [ "${lock_busy:-0}" = 0 ]; }
confirm() { [ "${approve:-1}" = 1 ]; }
# Lock refusal must prevent creating an archive or a success record.
lock_busy=1
if backup_all; then exit 1; fi
[ ! -e "$STATE_DIR/last-backup.status" ]
lock_busy=0
backup_all
newest="$(backup_archive_paths)"
verify_backup "$newest"
grep -q '^status=success$' "$STATE_DIR/last-backup.status"
# Verification rejects corrupt input without touching current configuration.
printf 'not an archive\n' > "$work/corrupt.tar.gz"
if verify_backup "$work/corrupt.tar.gz" 2>/dev/null; then exit 1; fi
[ "$(cat "$NODE_DIR/config")" = node ]
# Selection: listing, explicit manual path, retry invalid number, back and cancel.
list_backups | grep -q 'bytes'
ask() { IFS= read -r answer; printf -v "$2" '%s' "$answer"; }
ask_required() { ask "$@"; }
select_backup_archive picked <<< $'999\n1'
[ "$picked" = "$newest" ]
select_backup_archive picked <<< "$(printf 'm\n%s\n' "$newest")"
[ "$picked" = "$newest" ]
if select_backup_archive picked <<< 0; then exit 1; else [ "$?" = 131 ]; fi
if select_backup_archive picked <<< /cancel; then exit 1; else [ "$?" = 130 ]; fi
# Retention touches only recognized archives with regular success markers.
old="$BACKUP_ROOT/remnawave-backup-20000101000000-old.tar.gz"
unmanaged="$BACKUP_ROOT/remnawave-backup-19990101000000-manual.tar.gz"
cp "$newest" "$old"
cp "$newest" "$unmanaged"
printf '1\n' > "$BACKUP_ROOT/.verified/${old##*/}.status"
printf 'frequency=daily\ntime=03:00\nkeep=1\ndays=1\n' > "$STATE_DIR/backup-schedule.conf"
backup_prune "$newest"
[ ! -e "$old" ] && [ -f "$unmanaged" ] && [ -f "$newest" ]
# A failed new backup never invokes retention.
cp "$newest" "$old"
printf '1\n' > "$BACKUP_ROOT/.verified/${old##*/}.status"
lock_busy=1
if backup_all; then exit 1; fi
[ -f "$old" ]
lock_busy=0
# Invalid config is parsed as data, never sourced.
printf 'frequency=$(touch %s/pwned)\n' "$work" > "$STATE_DIR/backup-schedule.conf"
if backup_load_schedule; then exit 1; fi
[ ! -e "$work/pwned" ]
rm "$STATE_DIR/backup-schedule.conf"
# Only temporary unit files and a mocked service controller are used.
backup_schedule_unit_dir() { printf '%s\n' "$work/units"; }
systemctl() { :; }
backup_schedule_systemctl() {
  printf '%s\n' "$*" >> "$work/systemctl"
  case "$1" in
    show)
      [ "${query_fail:-0}" = 0 ] || return 1
      if [ -f "$work/units/remnawave-installer-backup.timer" ]; then
        printf 'UnitFileState=%s\nActiveState=%s\nLoadState=loaded\n' "$(cat "$work/enabled")" "$(cat "$work/active")"
      else printf 'UnitFileState=\nActiveState=inactive\nLoadState=not-found\n'; fi
      ;;
    enable)
      [ "${fail_enable:-0}" = 0 ] || return 1
      printf 'enabled\n' > "$work/enabled"
      [ "${2:-}" != --now ] || printf 'active\n' > "$work/active"
      ;;
    disable)
      printf 'disabled\n' > "$work/enabled"
      [ "${2:-}" != --now ] || printf 'inactive\n' > "$work/active"
      ;;
    restart) [ "${fail_restart:-0}" = 0 ] || return 1; printf 'active\n' > "$work/active" ;;
    start) printf 'active\n' > "$work/active" ;;
    stop) printf 'inactive\n' > "$work/active" ;;
  esac
  return 0
}
printf 'disabled\n' > "$work/enabled"
printf 'inactive\n' > "$work/active"
# Initial off with no installed unit succeeds and does not attempt disable.
configure_backup_schedule <<< off
! grep -q '^disable ' "$work/systemctl"
rm "$STATE_DIR/backup-schedule.conf"
fail_enable=1
if configure_backup_schedule <<< $'daily\n04:15\n2\n10'; then exit 1; fi
[ ! -e "$STATE_DIR/backup-schedule.conf" ]
[ ! -e "$STATE_DIR/backup-runner.sh" ]
[ ! -e "$work/units/remnawave-installer-backup.timer" ]
[ ! -e "$work/units/remnawave-installer-backup.service" ]
grep -q 'previous configuration and timer state restored' "$work/warnings"
fail_enable=0
configure_backup_schedule <<< $'daily\n25:00\n04:15\n2\n10'
grep -q '^OnCalendar=\*-\*-\* 04:15:00$' "$work/units/remnawave-installer-backup.timer"
grep -q '^ExecStart=/bin/bash .*backup-runner.sh --scheduled-backup$' "$work/units/remnawave-installer-backup.service"
grep -q '^keep=2$' "$STATE_DIR/backup-schedule.conf"
[ -s "$STATE_DIR/backup-runner.sh" ]
bash -n "$STATE_DIR/backup-runner.sh"
# Runtime snapshot must not serialize session credentials or unrelated functions.
SECRET_SENTINEL='must-not-appear-in-runner'
PANEL_TOKEN="$SECRET_SENTINEL"
backup_write_runner > "$work/runner.sh"
! grep -q "$SECRET_SENTINEL\|PANEL_TOKEN\|configure_backup_schedule" "$work/runner.sh"
# Execute the generated backup implementation with only privilege/flock mocked.
# Git Bash has neither Linux root nor flock; archive creation remains real.
sed 's/^need_root || exit.*$/need_root() { :; }; need_root/' "$work/runner.sh" > "$work/test-runner.sh"
export -f flock
bash "$work/test-runner.sh" --scheduled-backup
# Reading the installer via a descriptor still allows generating a complete runner.
bash <(printf 'source %q\nbackup_write_runner\n' "$(dirname "$0")/../remnawave_installer.sh") > "$work/fd-runner.sh"
bash -n "$work/fd-runner.sh"
grep -q '^run_scheduled_backup$' "$work/fd-runner.sh"
# Failed edits must restore bytes, retention and timer enabled/active state.
cp "$STATE_DIR/backup-schedule.conf" "$work/old.conf"
cp "$STATE_DIR/backup-runner.sh" "$work/old.runner"
cp "$work/units/remnawave-installer-backup.timer" "$work/old.timer"
cp "$work/units/remnawave-installer-backup.service" "$work/old.service"
fail_restart=1
if configure_backup_schedule <<< $'weekly\n22:00\n1\n1'; then exit 1; fi
cmp "$STATE_DIR/backup-schedule.conf" "$work/old.conf"
cmp "$STATE_DIR/backup-runner.sh" "$work/old.runner"
cmp "$work/units/remnawave-installer-backup.timer" "$work/old.timer"
cmp "$work/units/remnawave-installer-backup.service" "$work/old.service"
[ "$(cat "$work/enabled")" = enabled ] && [ "$(cat "$work/active")" = active ]
fail_restart=0
query_fail=1
show_backup_schedule | grep -q 'enabled=unknown; active=unknown'
query_fail=0
configure_backup_schedule <<< $'weekly\n23:59\n0\n0'
grep -q '^OnCalendar=Mon \*-\*-\* 23:59:00$' "$work/units/remnawave-installer-backup.timer"
configure_backup_schedule <<< off
grep -q '^disable --now remnawave-installer-backup.timer$' "$work/systemctl"
run_scheduled_backup
approve=0
before="$(cat "$STATE_DIR/backup-schedule.conf")"
if configure_backup_schedule <<< $'daily\n01:00\n1\n1'; then exit 1; fi
[ "$before" = "$(cat "$STATE_DIR/backup-schedule.conf")" ]
printf 'Backup management tests passed\n'
