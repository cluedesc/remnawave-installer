#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
PANEL_DIR="$work/panel"
NODE_DIR="$work/node"
STATE_DIR="$work/state"
BACKUP_ROOT="$work/backups"
mkdir -p "$PANEL_DIR" "$NODE_DIR" "$STATE_DIR"
printf 'config\n' > "$PANEL_DIR/.env"
printf 'compose\n' > "$PANEL_DIR/docker-compose.yml"
printf 'override\n' > "$PANEL_DIR/docker-compose.subscription.yml"
printf 'state\n' > "$STATE_DIR/panel.env"
printf 'node\n' > "$NODE_DIR/docker-compose.yml"
log="$work/events"
: > "$log"
ok() { printf 'success %s\n' "$*" >> "$log"; }
warn() { :; }
confirm() { return 0; }
select_backup_archive() { printf -v "$1" '%s' "$selected"; }
# Git Bash lacks flock; validate the exact lock call without installing services.
flock() { [ "$*" = "-n 9" ]; }
backup_compose() {
  printf '%s\n' "$*" >> "$log"
  case "$*" in
    *ps\ --status\ running\ --services) [ "${database_running:-1}" = 0 ] || printf 'remnawave-db\n' ;;
    *up\ -d\ --no-deps\ remnawave-db) [ "${fail_start:-0}" = 0 ] ;;
    *stop\ remnawave-db) [ "${fail_stop:-0}" = 0 ] ;;
    *pg_isready*) [ "${fail_wait:-0}" = 0 ] ;;
    *pg_dump*) [ "${fail_dump:-0}" = 0 ] || return 1; printf 'PGDMPtest\n' ;;
    *pg_restore*--list*) echo 'Must validate independently of old DB' >&2; return 1 ;;
    *config\ --format\ json) printf '{"services":{"remnawave-db":{"image":"postgres:test"}}}\n' ;;
    *pg_restore*) cat >/dev/null; [ "${fail_restore:-0}" = 0 ] ;;
  esac
}
start_panel_stack() {
  printf 'staged-panel-start\n' >> "$log"
  [ "${fail_backend:-0}" = 0 ]
}
sleep() { :; }
docker() {
  printf 'docker %s\n' "$*" >> "$log"
  [ "$*" = 'run --rm -i --pull=never --network none --entrypoint pg_restore postgres:test --list' ] || return 1
  cat >/dev/null
  [ "${fail_validation:-0}" = 0 ]
}
jq() {
  [ "$(cat)" = '{"services":{"remnawave-db":{"image":"postgres:test"}}}' ] || return 1
  printf 'postgres:test\n'
}
tar() {
  if [ "${fail_archive:-0}" = 1 ] && [ "${1:-}" = -czf ]; then return 1; fi
  command tar "$@"
}
# Stopped stacks start only DB; all failure paths restore its stopped state.
database_running=0
for failure in fail_start fail_wait fail_dump fail_stop; do
  printf -v "$failure" 1
  : > "$log"
  if backup_all; then echo "Accepted $failure" >&2; exit 1; fi
  grep -q "$PANEL_DIR up -d --no-deps remnawave-db$" "$log"
  grep -q "$PANEL_DIR stop remnawave-db$" "$log"
  [ -z "$(find "$BACKUP_ROOT" -name '*.tar.gz' -print)" ]
  ! grep -q '^success ' "$log"
  printf -v "$failure" 0
done
: > "$log"
backup_all
grep -q "$PANEL_DIR stop remnawave-db$" "$log"
! grep -q 'staged-panel-start\|remnawave-redis' "$log"
rm -- "$BACKUP_ROOT"/*.tar.gz
# Running DB must not be started or stopped by a backup.
database_running=1
: > "$log"
fail_dump=1
if backup_all; then echo 'Failed dump accepted' >&2; exit 1; fi
! grep -q ' up -d\| stop remnawave-db$' "$log"
[ -z "$(find "$BACKUP_ROOT" -name '*.tar.gz' -print)" ]
! grep -q '^success ' "$log"
fail_dump=0
fail_archive=1
if backup_all; then echo 'Failed archive accepted' >&2; exit 1; fi
[ -z "$(find "$BACKUP_ROOT" -name '*.tar.gz' -print)" ]
! grep -q '^success ' "$log"
fail_archive=0
backup_all
selected="$(find "$BACKUP_ROOT" -name '*.tar.gz' -print)"
mkdir "$work/check"
tar -xzf "$selected" -C "$work/check"
[ -s "$work/check/database.dump" ]
tar -tzf "$work/check/files.tar.gz" > "$work/contents"
grep -Fxq "${PANEL_DIR#/}/docker-compose.subscription.yml" "$work/contents"
grep -Fxq "${STATE_DIR#/}/panel.env" "$work/contents"
printf 'changed\n' > "$PANEL_DIR/.env"
: > "$log"
restore_backup
[ "$(cat "$PANEL_DIR/.env")" = config ]
stop_line="$(grep -n "$PANEL_DIR stop" "$log" | cut -d: -f1)"
restore_line="$(grep -n -- '--clean --if-exists --create --exit-on-error' "$log" | cut -d: -f1)"
start_line="$(grep -n '^staged-panel-start$' "$log" | cut -d: -f1)"
[ "$stop_line" -lt "$restore_line" ] && [ "$restore_line" -lt "$start_line" ]
: > "$log"
fail_restore=1
if restore_backup; then echo 'Failed restore accepted' >&2; exit 1; fi
! grep -q '^staged-panel-start$' "$log"
! grep -q '^success ' "$log"
fail_restore=0
fail_backend=1
: > "$log"
if restore_backup; then echo 'Unhealthy backend accepted' >&2; exit 1; fi
grep -q '^staged-panel-start$' "$log"
! grep -q "$NODE_DIR up -d$" "$log"
! grep -q '^success ' "$log"
fail_backend=0
# Invalid dump is rejected before stopping services or changing configuration.
fail_restore=0
fail_validation=1
printf 'unchanged\n' > "$PANEL_DIR/.env"
: > "$log"
if restore_backup; then echo 'Invalid dump accepted' >&2; exit 1; fi
[ "$(cat "$PANEL_DIR/.env")" = unchanged ]
! grep -q ' stop$' "$log"
fail_validation=0
# Missing old installation: validation uses only staged configuration and image.
rm -rf -- "$PANEL_DIR"
: > "$log"
restore_backup
[ "$(cat "$PANEL_DIR/.env")" = config ]
! grep -q "$PANEL_DIR stop" "$log"
grep -q '^staged-panel-start$' "$log"
# An old config-only archive must fail before any service or file changes.
selected="$work/legacy.tar.gz"
tar -czf "$selected" -C "$work" panel
: > "$log"
if restore_backup; then echo 'Legacy archive accepted' >&2; exit 1; fi
[ ! -s "$log" ]
printf 'Backup/restore tests passed\n'