#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"

clear_wait_line() { :; }
ok() { :; }
warn() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
HTTP_CHECK_TIMEOUT=1
curl_code=200
curl_exit=0
docker_exit=0
curl() {
  printf '%s\n' "$@" > "$tmp/curl-args"
  printf '%s' "$curl_code"
  return "$curl_exit"
}
docker() {
  printf '%s\n' "$@" > "$tmp/docker-args"
  return "$docker_exit"
}

assert_wait_output() {
  local status
  wait_for_http_status test https://example.test ready 1 0 status
  [[ "$status" == 200 ]] || fail 'success must propagate caller-local status'
  curl_code=503
  if wait_for_http_status test https://example.test ready 1 0 status; then
    fail '503 passed readiness'
  fi
  [[ "$status" == 503 ]] || fail 'timeout must propagate final status'
}
assert_wait_output
curl_code=200
[[ "$(http_status_code https://example.test)" == 200 ]] || fail 'HTTP 200'
if grep -Eq '^(-k|--insecure)$' "$tmp/curl-args"; then fail 'TLS validation disabled'; fi
curl_exit=60
[[ "$(http_status_code https://example.test)" == 000 ]] || fail 'TLS error must fail even with a status'
curl_exit=0
curl_code=404
if check_panel_url example.test none 1 0; then fail 'local panel 404 accepted'; fi
grep -Fxq 'X-Forwarded-Proto: https' "$tmp/curl-args" || fail 'local forwarding header absent'
if check_panel_url example.test caddy 1 0; then fail 'public panel 404 accepted'; fi
grep -Fxq 'https://example.test/api/auth/status' "$tmp/curl-args" || fail 'panel API not checked'
curl_code=200
check_panel_url example.test caddy 1 0 || fail 'healthy panel failed'
docker_exit=1
if check_subscription_page_url example.test caddy 1 0; then fail 'dead subscription passed with public root 200'; fi
docker_exit=0
check_subscription_page_url '' none 1 0 || fail 'local container health failed'
grep -Fxq 'http://127.0.0.1:3010/internal/health' "$tmp/docker-args" || fail 'internal service health omitted'
check_subscription_page_url example.test nginx 1 0 || fail 'healthy subscription failed'
curl_exit=60
if check_subscription_page_url example.test nginx 1 0; then fail 'subscription TLS failure accepted'; fi
printf 'HTTP readiness tests passed.\n'
