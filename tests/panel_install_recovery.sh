#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
PANEL_DIR="$tmp/panel"
LOG_DIR="$tmp/logs"
mkdir "$LOG_DIR"
LOG_FILE="$LOG_DIR/test.log"
mode=success
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_cmd() {
  local output="${@: -1}"
  printf 'downloaded template\n' > "$output"
  if [[ "$output" == */.env && "$mode" == download_failure ]]; then return 7; fi
  if [[ "$output" == */.env && "$mode" == interrupted ]]; then kill -s INT "$BASHPID"; fi
}
configure_panel_env() { printf 'APP_SECRET=preserved-secret\n' > "$1"; }
validate_panel_v3() {
  [[ -f "$PANEL_DIR/.env" && -f "$PANEL_DIR/docker-compose.yml" ]] || return 1
  grep -Fxq 'APP_SECRET=preserved-secret' "$PANEL_DIR/.env" || return 1
  if [[ "$mode" == invalid ]]; then return 1; fi
  if [[ "$mode" == publish_conflict ]]; then
    printf 'other installation\n' > "${PANEL_DIR%/*}/docker-compose.yml"
  fi
}

mode=download_failure
if prepare_new_panel_files panel.example sub.example; then fail 'failed download accepted'; fi
[[ ! -e "$PANEL_DIR/.env" && ! -e "$PANEL_DIR/docker-compose.yml" ]] || fail 'partial files published'
[[ -z $(find "$PANEL_DIR" -mindepth 1 -print -quit) ]] || fail 'staging files remain'
mode=interrupted
if prepare_new_panel_files panel.example sub.example; then fail 'interruption accepted'; else status=$?; fi
[[ "$status" == 130 ]] || fail 'interrupt status lost'
[[ -z $(find "$PANEL_DIR" -mindepth 1 -print -quit) ]] || fail 'interrupted staging files remain'
mode=invalid
if prepare_new_panel_files panel.example sub.example; then fail 'invalid configuration accepted'; fi
[[ -z $(find "$PANEL_DIR" -mindepth 1 -print -quit) ]] || fail 'invalid files published'
mode=success
prepare_new_panel_files panel.example sub.example
grep -Fxq 'APP_SECRET=preserved-secret' "$PANEL_DIR/.env" || fail 'retry did not succeed'
if prepare_new_panel_files panel.example sub.example; then fail 'existing files overwritten'; fi
grep -Fxq 'APP_SECRET=preserved-secret' "$PANEL_DIR/.env" || fail 'existing secret changed'

# An incomplete older attempt must not be reported as successful or continue to Node.
PANEL_DIR="$tmp/partial"
mkdir "$PANEL_DIR"
printf 'saved compose\n' > "$PANEL_DIR/docker-compose.yml"
if install_panel; then fail 'incomplete installation accepted'; fi
grep -Fxq 'saved compose' "$PANEL_DIR/docker-compose.yml" || fail 'existing compose changed'
[[ ! -e "$PANEL_DIR/.env" ]] || fail 'replacement secrets generated'
confirm() { return 0; }
install_node() { touch "$tmp/node-started"; }
run_menu_action install_panel_node
[[ ! -e "$tmp/node-started" ]] || fail 'continued to Node after incomplete Panel'
PANEL_DIR="$tmp/env-only"
mkdir "$PANEL_DIR"
printf 'original-secret\n' > "$PANEL_DIR/.env"
if install_panel; then fail 'env-only installation accepted'; fi
grep -Fxq 'original-secret' "$PANEL_DIR/.env" || fail 'original secret changed'

# If another writer creates a target during preparation, do not replace it.
PANEL_DIR="$tmp/conflict"
mode=publish_conflict
if prepare_new_panel_files panel.example sub.example; then fail 'publication conflict accepted'; fi
grep -Fxq 'other installation' "$PANEL_DIR/docker-compose.yml" || fail 'conflicting file overwritten'
[[ ! -e "$PANEL_DIR/.env" ]] || fail 'own partially published env was not rolled back'
[[ -z $(find "$PANEL_DIR" -name '.install.*' -print -quit) ]] || fail 'conflict staging remains'
printf 'Panel install recovery tests passed.\n'
