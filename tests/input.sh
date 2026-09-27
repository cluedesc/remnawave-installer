#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
prompt_line() { :; }; prompt_default() { :; }; warn() { :; }; micro() { :; }; note() { :; }
log_file_append() { :; }
# Keep deterministic fixture reads independent of a developer's controlling tty.
read_input() { local line; IFS= read -r line || return 130; printf '%s' "$line"; }
read_secret_input() { read_input; }

test_inputs() {
  local value='' prompt='' var_name='' default_value=''
  ask 'Value' prompt <<< 'works'
  [[ "$prompt" == works ]] || fail 'ask shadows caller variable'
  ask_required 'Value' var_name <<< $'\nrequired'
  [[ "$var_name" == required ]] || fail 'required retry/assignment'
  ask_secret_required 'Secret' default_value <<< $'\n  hidden  '
  [[ "$default_value" == '  hidden  ' ]] || fail 'secret retry/preservation'
  ask_validated 'Port' value validate_port 'Invalid port.' <<< $'0\n65536\n999999999999999999999999999\n080'
  [[ "$value" == 080 ]] || fail 'validated retry'
  ask_choice 'Choice' value 1 10 1 <<< $'abc\n999999999999999999999999999\n0\n08'
  [[ "$value" == 8 ]] || fail 'choice decimal/retry'
  ask_choice 'Choice' value 0 2 0 <<< ''
  [[ "$value" == 0 ]] || fail 'valid zero default'
  ask_choice 'Choice' value 1 2 0 <<< $'\n2'
  [[ "$value" == 2 ]] || fail 'invalid zero default accepted'
  local status=0
  for helper in ask ask_required ask_secret ask_secret_required; do
    value=unchanged
    "$helper" 'Value' value </dev/null || status=$?
    [[ "$status" == 130 && "$value" == unchanged ]] || fail "$helper EOF"
  done
  status=0
  ask 'Value' value default </dev/null || status=$?
  [[ "$status" == 130 ]] || fail 'EOF accepted default'
  status=0
  ask_validated 'Port' value validate_port 'Invalid.' </dev/null || status=$?
  [[ "$status" == 130 ]] || fail 'validated EOF'
  status=0
  ask_choice 'Choice' value 1 2 1 </dev/null || status=$?
  [[ "$status" == 130 ]] || fail 'choice EOF'
  status=0
  confirm 'Proceed?' </dev/null || status=$?
  [[ "$status" == 130 ]] || fail 'confirm EOF'
}
test_inputs >/dev/null
for port in 1 08 00080 65535; do validate_port "$port" || fail "valid port $port"; done
for port in 0 65536 -1 foo 9999999999999999999999999999; do
  if validate_port "$port"; then fail 'invalid port accepted'; fi
done
validate_host 192.168.001.010 || fail 'IPv4 rejected'
validate_host panel.example.test || fail 'domain rejected'
for host in 999.1.1.1 https://example.test example..test -bad.test; do
  if validate_host "$host"; then fail 'invalid host accepted'; fi
done
printf 'input tests passed\n'
