#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PANEL_DIR="$tmp/panel"; STATE_DIR="$tmp/state"; PANEL_STATE_FILE="$STATE_DIR/panel.env"; PANEL_AUTH_STATE_FILE="$STATE_DIR/auth.env"
PANEL_CADDY_FILE="$tmp/Caddyfile"; PANEL_NGINX_FILE="$tmp/nginx.conf"
mkdir -p "$PANEL_DIR"
printf 'APP_SECRET=original-secret\nPOSTGRES_PASSWORD=original-password\nFRONT_END_DOMAIN=old.example\n' > "$PANEL_DIR/.env"
printf 'unrelated.example { reverse_proxy localhost:9999 }\n' > "$PANEL_CADDY_FILE"
save_panel_state old.example caddy old@example.com sub.example
cp "$PANEL_DIR/.env" "$tmp/original-env"
cp "$PANEL_CADDY_FILE" "$tmp/original-proxy"
check_panel_proxy_choice none || { echo 'unrelated Caddy sites block local-only setup' >&2; exit 1; }
systemctl() { [[ "$1" != is-active ]]; }
start_panel_stack() { return 0; }
configure_panel_reverse_proxy() { printf 'replacement\n' > "$PANEL_CADDY_FILE"; }
check_panel_url() { [[ "$mode" == success ]]; }
remember_panel_auth() { printf '%s' "$1" > "$PANEL_AUTH_STATE_FILE"; }
mode=failure
if apply_panel_https new.example caddy new@example.com sub.example; then echo 'failed public check accepted' >&2; exit 1; fi
cmp "$PANEL_DIR/.env" "$tmp/original-env"
cmp "$PANEL_CADDY_FILE" "$tmp/original-proxy"
load_panel_state
[[ "$PANEL_DOMAIN" == old.example ]]
mode=success
apply_panel_https new.example caddy new@example.com sub.example
load_panel_state
[[ "$PANEL_DOMAIN" == new.example ]]
grep -Fxq 'APP_SECRET=original-secret' "$PANEL_DIR/.env"
grep -Fxq 'POSTGRES_PASSWORD=original-password' "$PANEL_DIR/.env"
grep -Fxq 'FRONT_END_DOMAIN=new.example' "$PANEL_DIR/.env"
[[ $(cat "$PANEL_AUTH_STATE_FILE") == https://new.example ]]
printf 'other site\n' > "$PANEL_NGINX_FILE"
if check_panel_proxy_choice caddy; then echo 'implicit proxy switch accepted' >&2; exit 1; fi
printf 'HTTPS rollback tests passed.\n'

(
  mode=failure
  rm "$PANEL_NGINX_FILE"
  start_panel_stack() { return 1; }
  if apply_panel_https another.example caddy new@example.com sub.example > "$tmp/rollback-output"; then exit 1; fi
  grep -q 'rollback needs attention' "$tmp/rollback-output"
)

# A failed Caddy read must not publish a partial file losing unrelated sites.
(
  source "$(dirname "$0")/../remnawave_installer.sh"
  PANEL_CADDY_FILE="$tmp/Caddy-awk-failure"
  printf 'unrelated.example { reverse_proxy localhost:9999 }\n' > "$PANEL_CADDY_FILE"
  cp "$PANEL_CADDY_FILE" "$tmp/caddy-before-awk"
  install_caddy() { return 0; }
  mkdir() { return 0; }
  chown() { return 0; }
  chmod() { return 0; }
  touch() { return 0; }
  awk() { return 7; }
  run_cmd_stream() { echo 'unexpected Caddy validation' >&2; exit 1; }
  if configure_caddy_panel new.example owner@example.com; then exit 1; fi
  cmp "$PANEL_CADDY_FILE" "$tmp/caddy-before-awk"
)
printf 'Caddy partial-read preservation test passed.\n'
