#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
prompt_line() { :; }; prompt_default() { :; }; warn() { :; }; micro() { :; }; note() { :; }
log_file_append() { :; }
read_input() { local line; IFS= read -r line || return 130; printf '%s' "$line"; }
read_secret_input() { read_input; }
check_status() {
  local expected="$1" status=0; shift
  "$@" >/dev/null || status=$?
  [[ "$status" == "$expected" ]] || fail "$*: expected $expected, got $status"
}
for command in /back /cancel; do
  expected=131; [[ "$command" != /cancel ]] || expected=130
  for helper in ask ask_required ask_secret ask_secret_required; do
    value=unchanged
    check_status "$expected" "$helper" Value value <<< "$command"
    [[ "$value" == unchanged ]] || fail 'navigation overwrote value'
  done
  check_status "$expected" ask_validated URL value validate_url Invalid <<< "$command"
  check_status "$expected" ask_choice Choice value 0 2 <<< "$command"
  check_status "$expected" ask_menu_choice value <<< "$command"
  check_status "$expected" ask_delete_confirmation value <<< "$command"
  check_status "$expected" confirm Proceed <<< "$command"
  # Even an if/! caller must not continue to mutate after cancellation.
  status=0
  ( OPERATION_ACTIVE=1; if ! confirm Proceed <<< "$command"; then :; fi; exit 99 ) >/dev/null || status=$?
  [[ "$status" == "$expected" ]] || fail 'active operation swallowed navigation'
done
value=''
ask_secret Secret value <<< ' /back ' >/dev/null
[[ "$value" == ' /back ' ]] || fail 'secret whitespace lost'
for url in https://panel.example http://localhost:3000 https://127.0.0.1:443/base/; do
  validate_url "$url" || fail "valid URL: $url"
done
for url in example.com ftp://example.com https://user:pass@example.com https://example.com:0 'https://example.com/a b' 'https://example.com?q=1' 'https://example.com/#foo' 'https://bad..example' 'https://example.com\evil'; do
  if validate_url "$url"; then fail "invalid URL accepted: $url"; fi
done
for email in a@example.com first.last+tag@example.co.uk "o'brien@example.com"; do
  validate_email "$email" || fail "valid email: $email"
done
validate_optional_email '' || fail 'optional empty email'
for email in '' a@localhost .a@example.com a..b@example.com a@@example.com 'a b@example.com'; do
  if validate_email "$email"; then fail "invalid email accepted: $email"; fi
done
# Re-enter URL after auth Back, committing outputs only after success.
get_panel_api_token() {
  local choice
  ask Auth choice || return $?
  [[ "$choice" != 0 ]] || return 131
  printf -v "$2" '%s' good-token
}
base=unchanged token=unchanged
ask_panel_auth base token <<< $'invalid\nhttps://old.example\n0\nhttps://new.example/\naccept' >/dev/null
[[ "$base" == https://new.example && "$token" == good-token ]] || fail 'auth Back URL change'
base=unchanged token=unchanged
check_status 130 ask_panel_auth base token <<< $'https://new.example\n/cancel'
[[ "$base" == unchanged && "$token" == unchanged ]] || fail 'partial auth outputs'
printf 'navigation tests passed\n'
