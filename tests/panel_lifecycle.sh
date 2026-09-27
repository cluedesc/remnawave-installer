#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
PANEL_DIR="$tmp/panel"
mkdir "$PANEL_DIR"
printf 'preserved compose\n' > "$PANEL_DIR/docker-compose.yml"
printf 'preserved override\n' > "$PANEL_DIR/docker-compose.subscription.yml"
printf 'APP_SECRET=preserved-secret\n' > "$PANEL_DIR/.env"
events="$tmp/events"
: > "$events"
image='remnawave/backend:3'
secret='test-secret'
backup_exit=0
pull_exit=0
health_exit=0
section() { :; }
step() { :; }
warn() { :; }
note() { :; }
ok() { :; }
confirm() { return 0; }
backup_panel() { printf 'backup\n' >> "$events"; return "$backup_exit"; }
backup_all() { backup_panel; }
run_cmd_stream() { shift; "$@"; }
docker() {
  if [[ "$*" == *'config --format json' ]]; then
    jq -n --arg image "$image" --arg secret "$secret" '{services:{remnawave:{image:$image,environment:{APP_SECRET:$secret}}}}'
    return
  fi
  printf 'docker %s\n' "$*" >> "$events"
  if [[ " $* " == *' pull '* ]]; then return "$pull_exit"; fi
}
wait_for_panel_database() { printf 'database ready\n' >> "$events"; }
wait_for_compose_service_ready() {
  printf 'ready %s\n' "$1" >> "$events"
  if [[ "$1" == remnawave ]]; then return "$health_exit"; fi
}
check_subscription_page_url() { printf 'subscription health\n' >> "$events"; }

validate_panel_v3 || fail 'v3 rejected'
image='ghcr.io/remnawave/backend:3.4.4'
validate_panel_v3 || fail 'v3 patch rejected'
for image in remnawave/backend:2 remnawave/backend:latest remnawave/backend:4; do
  if validate_panel_v3; then fail "unsupported image accepted: $image"; fi
done
image='remnawave/backend:3'
for secret in '' change_me; do
  if validate_panel_v3; then fail 'unconfigured secret accepted'; fi
done
secret='test-secret'

backup_exit=1
if update_panel; then fail 'update continued after backup failure'; fi
[[ $(cat "$events") == backup ]] || fail 'Docker mutated before complete backup'
backup_exit=0
: > "$events"
pull_exit=1
if reinstall_panel_keep_config; then fail 'failed pull reported success'; fi
if grep -Eq ' up | down |stop|restart' "$events"; then fail 'pull failure disrupted stack'; fi
pull_exit=0
: > "$events"
health_exit=1
if start_panel_stack; then fail 'unhealthy backend reported success'; fi
if grep -q 'subscription health\| up -d$\|restart' "$events"; then fail 'dependents started or backend restarted before healthy'; fi
health_exit=0
: > "$events"
reinstall_panel_keep_config || fail 'reinstall failed'
[[ $(head -n1 "$events") == backup ]] || fail 'reinstall omitted backup'
grep -q -- '--force-recreate remnawave$' "$events" || fail 'backend not recreated'
grep -q 'subscription health' "$events" || fail 'subscription readiness omitted'
[[ $(cat "$PANEL_DIR/docker-compose.yml") == 'preserved compose' ]] || fail 'compose overwritten'
[[ $(cat "$PANEL_DIR/docker-compose.subscription.yml") == 'preserved override' ]] || fail 'override overwritten'
[[ $(cat "$PANEL_DIR/.env") == 'APP_SECRET=preserved-secret' ]] || fail 'secret overwritten'
printf 'Panel lifecycle tests passed.\n'
