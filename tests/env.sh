#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../remnawave_installer.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Reproduce the upstream template ending in POSTGRES_DB without a newline.
printf 'APP_SECRET=change_me\nDATABASE_URL="old"\nPOSTGRES_DB=postgres' > "$tmp/panel.env"
set_env_value "$tmp/panel.env" EXTRA 'one/two&three\four'
grep -Fxq 'POSTGRES_DB=postgres' "$tmp/panel.env" || fail 'last value corrupted'
grep -Fxq 'EXTRA=one/two&three\four' "$tmp/panel.env" || fail 'appended value corrupted'
set_env_value "$tmp/panel.env" EXTRA 'changed/with&escapes\'
grep -Fxq 'EXTRA=changed/with&escapes\' "$tmp/panel.env" || fail 'replacement escaping'
[[ $(grep -c '^EXTRA=' "$tmp/panel.env") == 1 ]] || fail 'duplicate key'

configure_panel_env "$tmp/panel.env" panel.example.test sub.example.test
value() { sed -n "s/^$1=//p" "$tmp/panel.env"; }
[[ $(value APP_SECRET) =~ ^[a-f0-9]{128}$ ]] || fail 'missing v3 app secret'
[[ $(value WEBHOOK_SECRET_HEADER) =~ ^[a-f0-9]{64}$ ]] || fail 'webhook secret length'
[[ $(value POSTGRES_PASSWORD) =~ ^[a-f0-9]{48}$ ]] || fail 'database password'
[[ $(value DATABASE_URL) == "\"postgresql://postgres:$(value POSTGRES_PASSWORD)@remnawave-db:5432/postgres\"" ]] || fail 'database URL/password mismatch'
[[ $(value POSTGRES_DB) == postgres ]] || fail 'database name changed'
[[ $(value PANEL_DOMAIN) == panel.example.test ]] || fail 'panel domain'
[[ $(value SUB_PUBLIC_DOMAIN) == sub.example.test ]] || fail 'subscription domain'
if grep -q '^JWT_' "$tmp/panel.env"; then fail 'legacy JWT variables generated'; fi

# A randomness failure must not leave partially replaced secrets.
cp "$tmp/panel.env" "$tmp/before.env"
random_hex() { return 1; }
if configure_panel_env "$tmp/panel.env" panel.example.test sub.example.test; then fail 'randomness failure ignored'; fi
cmp "$tmp/panel.env" "$tmp/before.env" || fail 'modified env after generation failure'
printf 'Environment tests passed.\n'
