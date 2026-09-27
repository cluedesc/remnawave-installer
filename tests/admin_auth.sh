#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/remnawave_installer.sh"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
LOG_DIR="$test_dir"
LOG_FILE="$test_dir/installer.log"
exec 3>&1
exec > "$test_dir/output"
requests="$test_dir/requests"
: > "$requests"
read_input() { local value; IFS= read -r value || return 130; printf '%s' "$value"; }
read_secret_input() { read_input; }
load_panel_auth_state() { :; }
remember_panel_auth() { saved_token="$2"; saved_username="${3:-}"; }
clear_panel_auth_token() { PANEL_AUTH_TOKEN=""; }
test_register_allowed=true
registration_fail=false
login_malformed=false
curl() {
  local output="" url="" data="" header=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      --data) data="$2"; shift 2 ;;
      -H) header="$header $2"; shift 2 ;;
      -X|-w) shift 2 ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$url" >> "$requests"
  case "$url" in
    */auth/status) printf '{"response":{"isRegisterAllowed":%s}}' "$test_register_allowed" ;;
    */auth/register)
      if [ "$registration_fail" = true ]; then
        printf '{"message":"private-secret-error"}' > "$output"; printf '400'; return
      fi
      [ "$(printf '%s' "$data" | jq -r .username)" = testadmin ] || return 1
      [ "$(printf '%s' "$data" | jq -r .password)" = 'GoodPassword12345678901234' ] || return 1
      printf '{"response":{"accessToken":"good-token"}}' > "$output"; printf '201' ;;
    */auth/login)
      if [ "$login_malformed" = true ]; then
        printf 'invalid response private-secret-error' > "$output"; printf '200'; return
      fi
      if [ "$(printf '%s' "$data" | jq -r .password)" = 'correct-private-password' ]; then
        printf '{"response":{"accessToken":"good-token"}}' > "$output"; printf '200'
      else
        printf '{"message":"private-secret-error"}' > "$output"; printf '401'
      fi ;;
    */config-profiles)
      : > "$output"
      if [[ "$header" == *'Authorization: Bearer good-token'* ]]; then printf '200'; else printf '401'; fi ;;
    *) return 1 ;;
  esac
}

# Invalid menu input and short password retry without asking the username twice.
create_panel_admin 'https://panel.example' > "$test_dir/admin-output" <<'INPUT'
bad
1
testadmin
short-private-password
GoodPassword12345678901234
INPUT
[ "$PANEL_ADMIN_USERNAME" = testadmin ]
[ "$saved_token" = good-token ]
[ "$(grep -c '/auth/register' "$requests")" -eq 1 ]
[ "$(grep -o 'Admin username' "$test_dir/admin-output" | wc -l)" -eq 1 ]

# Back from password revisits username; Back from username revisits mode.
create_panel_admin 'https://panel.example' <<'INPUT'
1
oldadmin
/back
/back
1
testadmin
GoodPassword12345678901234
INPUT
[ "$PANEL_ADMIN_USERNAME" = testadmin ]

test_register_allowed=false
create_panel_admin 'https://panel.example' < /dev/null
[ -z "$PANEL_ADMIN_USERNAME" ]
test_register_allowed=true
create_panel_admin 'https://panel.example' <<< '0'
[ "$(grep -c '/auth/register' "$requests")" -eq 2 ]
registration_fail=true
create_panel_admin 'https://panel.example' <<'INPUT'
1
testadmin
GoodPassword12345678901234
0
INPUT
registration_fail=false

PANEL_AUTH_TOKEN=bad-saved-token
PANEL_AUTH_USERNAME=testadmin
PANEL_AUTH_PASSWORD=bad-private-password
get_panel_api_token 'https://panel.example' result <<'INPUT'
y
y
bad
1
bad-private-token
2
testadmin
bad-private-password
2

correct-private-password
INPUT
[ "$result" = good-token ]
[ "$saved_username" = testadmin ]
PANEL_AUTH_TOKEN=""
PANEL_AUTH_USERNAME=""
PANEL_AUTH_PASSWORD=""
status=0
get_panel_api_token 'https://panel.example' result <<< '0' || status=$?
[ "$status" -eq 131 ]
for input in '' '1' $'2\ntestadmin'; do
  status=0
  get_panel_api_token 'https://panel.example' result <<< "$input" || status=$?
  [ "$status" -eq 130 ]
done
status=0
create_panel_admin 'https://panel.example' < /dev/null || status=$?
[ "$status" -eq 130 ]
login_malformed=true
result=stale
status=0
login_panel_and_get_token 'https://panel.example' testadmin anything result || status=$?
[ "$status" -eq 1 ] && [ -z "$result" ]
exec >&3
! grep -E 'short-private-password|GoodPassword12345678901234|bad-private-password|correct-private-password|bad-private-token|private-secret-error' "$LOG_FILE" "$test_dir/admin-output" "$test_dir/output"
printf 'Admin/auth retry tests passed\n' >&3
