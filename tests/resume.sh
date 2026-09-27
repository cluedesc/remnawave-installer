#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PANEL_DIR="$tmp/panel"; STATE_DIR="$tmp/state"; PANEL_STATE_FILE="$STATE_DIR/panel.env"; PANEL_AUTH_STATE_FILE="$STATE_DIR/auth.env"
mkdir -p "$PANEL_DIR"
printf 'APP_SECRET=original\n' > "$PANEL_DIR/.env"
touch "$PANEL_DIR/docker-compose.yml" "$PANEL_DIR/docker-compose.subscription.yml"
save_panel_state panel.example caddy owner@example.com sub.example
save_panel_draft draft.example nginx retry@example.com sub.example
case "$(uname -s)" in MINGW*|MSYS*) ;; *) [[ $(stat -c %a "${PANEL_STATE_FILE}.draft") == 600 ]];; esac
load_panel_draft
[[ "$PANEL_DOMAIN" == draft.example ]]
validate_panel_v3() { return 0; }
check_panel_url() { printf '%s\n' "$2" >> "$tmp/checks"; }
check_subscription_page_url() { return 0; }
start_panel_stack() { touch "$tmp/started"; }
curl() { printf '{"response":{"isRegisterAllowed":false}}'; }
confirm() { echo 'unexpected prompt' >&2; return 1; }
create_panel_admin() { touch "$tmp/admin"; }
setup_subscription_page_for_panel() { touch "$tmp/subscription"; }
print_panel_summary() { touch "$tmp/summary"; }
resume_panel_setup
[[ ! -e "$tmp/started" && ! -e "$tmp/admin" && ! -e "$tmp/subscription" && -e "$tmp/summary" ]]
[[ $(grep -c '^caddy$' "$tmp/checks") == 2 ]]
rm "$PANEL_DIR/.env"
if resume_panel_setup; then echo 'accepted missing original env' >&2; exit 1; fi
printf 'Resume tests passed.\n'

# Navigation at the first prompt exits to the caller.
(
  ask_validated() { return 131; }
  if panel_setup_preferences; then exit 1; else [[ $? == 131 ]]; fi
)
# Invalid filesystem objects must not recurse into install forever.
(
  PANEL_DIR="$tmp/invalid"; mkdir -p "$PANEL_DIR/.env"
  if install_panel; then exit 1; fi
  rmdir "$PANEL_DIR/.env"
  if ln -s "$tmp/nonexistent" "$PANEL_DIR/.env" 2>/dev/null; then
    if install_panel; then exit 1; fi
  else
    printf 'Dangling symlink check unavailable on this filesystem.\n'
  fi
)
# Conditional callers must not mask a failed package prerequisite.
(
  source "$(dirname "$0")/../remnawave_installer.sh"
  run_cmd_stream() { return 19; }
  install_docker() { touch "$tmp/docker-after-apt-failure"; }
  if install_prerequisites; then exit 1; fi
  [[ ! -e "$tmp/docker-after-apt-failure" ]]
)
printf 'Navigation, invalid paths and package failure tests passed.\n'

# A broken existing subscription is reported without registering a new token.
(
  PANEL_DIR="$tmp/sub-unready"; mkdir -p "$PANEL_DIR"
  touch "$PANEL_DIR/.env" "$PANEL_DIR/docker-compose.yml" "$PANEL_DIR/docker-compose.subscription.yml"
  check_subscription_page_url() { return 1; }
  if resume_panel_setup; then exit 1; fi
  [[ ! -e "$tmp/subscription" ]]
)
printf 'Existing subscription failure test passed.\n'
