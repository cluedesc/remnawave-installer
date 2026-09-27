#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/remnawave_installer.sh"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
LOG_DIR="$test_dir"
LOG_FILE="$test_dir/installer.log"
request_log="$test_dir/requests"
keygen_mode=success

# Fake only the transport; exercise actual JSON parsing, validation and out variables.
curl() {
  local output="" method="" url="" authenticated=false header
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      -X) method="$2"; shift 2 ;;
      -H)
        header="$2"
        if [ "$header" = 'Authorization: Bearer test-access-token' ]; then authenticated=true; fi
        shift 2 ;;
      -w|--data) shift 2 ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  printf '%s %s %s\n' "$method" "$url" "$authenticated" >> "$request_log"
  case "$url" in
    */api/auth/login)
      printf '%s' '{"response":{"accessToken":"test-access-token"}}' > "$output"
      printf '200' ;;
    */api/nodes)
      [ "$authenticated" = true ] || return 1
      printf '%s' '{"response":{"uuid":"test-node-uuid"}}' > "$output"
      printf '201' ;;
    */api/keygen)
      [ "$authenticated" = true ] || return 1
      case "$keygen_mode" in
        success) printf '%s' '{"response":{"secretKey":"test-node-secret"}}' > "$output"; printf '200' ;;
        denied) printf '%s' '{"message":"private-error-detail"}' > "$output"; printf '403' ;;
        invalid) printf '%s' '{"response":{"secretKey":null}}' > "$output"; printf '200' ;;
        network) return 7 ;;
      esac ;;
    *) return 1 ;;
  esac
}

test_login() {
  local api_token
  login_panel_and_get_token 'https://panel.example' admin password api_token
  [ "$api_token" = test-access-token ]
}

test_login
secret_key=stale
node_uuid=stale
create_remnawave_node_api 'https://panel.example' test-access-token profile inbound node.example node 2222 secret_key node_uuid
[ "$secret_key" = test-node-secret ]
[ "$node_uuid" = test-node-uuid ]
grep -Fx 'GET https://panel.example/api/keygen true' "$request_log" >/dev/null

for keygen_mode in denied invalid network; do
  secret_key=stale
  node_uuid=stale
  create_remnawave_node_api 'https://panel.example' test-access-token profile inbound node.example node 2222 secret_key node_uuid > "$test_dir/output"
  [ -z "$secret_key" ]
  [ "$node_uuid" = test-node-uuid ]
  grep -F 'Enter it manually' "$test_dir/output" >/dev/null
done
! grep -E 'test-node-secret|private-error-detail' "$LOG_FILE" "$test_dir/output"
printf 'API tests passed\n'
