#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
STATE_DIR="$tmp/state"
PANEL_DIR="$tmp/panel"
BACKUP_ROOT="$tmp/backups"
mkdir -p "$PANEL_DIR" "$BACKUP_ROOT"
load_panel_state() { PANEL_DOMAIN=panel.example.test; SUBSCRIPTION_DOMAIN=sub.example.test; }
docker() { :; }
probe_fail=0
http_code=200
http_exit=0
diagnostic_run() {
  case "$1" in
    docker)
      if [ "$2" = ps ]; then
        [ "$probe_fail" = 0 ] || return 1
        printf 'remnawave|running|Up 1 hour (healthy)|remnawave/backend:3.4.4\nremnawave-db|exited|Exited (1)|postgres:17\nremnawave-redis|running|Up 1 hour|redis:7\n'
      else return 0; fi ;;
    curl) printf '%s' "$http_code"; return "$http_exit" ;;
    getent) printf '203.0.113.1 STREAM panel.example.test\n' ;;
    ss) printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n' ;;
    df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfake 100 95 5 95%% /\n' ;;
    *) return 1 ;;
  esac
}
diagnostic_snapshot
[[ "$(diagnostic_container remnawave)" = 'running / healthy' ]] || fail 'healthy state'
[[ "$(diagnostic_container remnawave-redis)" = 'running / health not reported' ]] || fail 'running must not imply healthy'
[[ "$(diagnostic_container remnawave-db)" = exited ]] || fail 'stopped state'
[[ "$(diagnostic_container remnanode)" = absent ]] || fail 'absent state'
probe_fail=1
diagnostic_snapshot
[[ "$(diagnostic_container remnanode)" = 'unknown (Docker unknown)' ]] || fail 'daemon failure must not imply absent'
probe_fail=0
[[ -z "$(diagnostic_domain 'evil.test/path?token=secret')" ]] || fail 'unsafe domain'
http_exit=60
[[ "$(diagnostic_http https://example.test)" = 000 ]] || fail 'TLS failure must override status'
http_exit=0
show_dashboard > "$tmp/dashboard"
grep -q '3.4.4 (image tag' "$tmp/dashboard" || fail 'installed image tag'
mkdir -p "$STATE_DIR"
printf 'archive\n' > "$BACKUP_ROOT/remnawave-backup-20260101000000-test.tar.gz"
printf 'status=success\ntimestamp=1767225600\narchive=%s\n' "$BACKUP_ROOT/remnawave-backup-20260101000000-test.tar.gz" > "$STATE_DIR/last-backup.status"
diagnostic_latest_backup > "$tmp/latest"
grep -q 'verified when created' "$tmp/latest" || fail 'verified backup date missing'
rm "$BACKUP_ROOT/remnawave-backup-20260101000000-test.tar.gz"
diagnostic_latest_backup > "$tmp/latest"
grep -q 'archive is missing' "$tmp/latest" || fail 'missing archive shown as usable'
WEBSERVER=none
show_dashboard > "$tmp/dashboard"
grep -q '127.0.0.1:3000 (local access)' "$tmp/dashboard" || fail 'local-only URL wrong'
unset WEBSERVER
diagnose_installation > "$tmp/diagnostics"
grep -q 'TCP port 443: listening' "$tmp/diagnostics" || fail 'listening port'
grep -q 'free disk space' "$tmp/diagnostics" || fail 'disk hint'
grep -q 'remnawave-db needs attention' "$tmp/diagnostics" || fail 'stopped hint'
printf 'TOKEN=SUPER_SECRET\n' > "$PANEL_DIR/.env"
export_diagnostic_report > "$tmp/export"
report=$(find "$STATE_DIR/reports" -type f | head -1)
[ -n "$report" ] || fail 'missing report'
! grep -q 'SUPER_SECRET' "$report" || fail 'secret disclosure'
case "$(uname -s)" in
  MINGW*|MSYS*) printf 'POSIX permission check skipped on Windows filesystem.\n' ;;
  *) [[ "$(stat -c %a "$report")" = 600 ]] || fail 'report permissions' ;;
esac
printf 'Diagnostic tests passed.\n'
