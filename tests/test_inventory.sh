#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/inventory.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

bash -n "$SCRIPT"
[[ "$($SCRIPT --version)" == "inventory.sh 1.0.0" ]] || fail "version output"
$SCRIPT --help >/dev/null

if $SCRIPT --unknown >/dev/null 2>&1; then
    fail "unknown option accepted"
fi

output="$($SCRIPT)"

expected_keys=(
    inventory_schema
    inventory_version
    generated_utc
    os_id
    os_version
    architecture
    privilege_class
    init_style
    command_bash
    command_git
    command_ssh
    command_sshd
    command_sudo
    sshd_config_state
)

for key in "${expected_keys[@]}"; do
    count="$(grep -c "^${key}=" <<<"$output")"
    [[ "$count" -eq 1 ]] || fail "missing or duplicate key: $key"
done

line_count="$(wc -l <<<"$output")"
[[ "$line_count" -eq "${#expected_keys[@]}" ]] || fail "unexpected output fields"

if grep -Evq '^([a-z0-9_]+)=([A-Za-z0-9._:+-]+)$' <<<"$output"; then
    fail "invalid output format"
fi

if grep -Eiq '(^|_)(hostname|address|ip|port|user|account|key|fingerprint|repository)=' <<<"$output"; then
    fail "sensitive field name present"
fi

printf 'PASS: inventory contract\n'
