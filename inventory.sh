#!/usr/bin/env bash

set -u

VERSION="1.0.0"

usage() {
    cat <<'EOF'
Usage: inventory.sh [--help|--version]

Print a minimal, read-only local compatibility inventory to standard output.
The script performs no network access and writes no files.
EOF
}

clean_value() {
    local value="${1:-unknown}"

    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    value="${value//[^A-Za-z0-9._:+-]/_}"
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

emit() {
    printf '%s=%s\n' "$1" "$(clean_value "$2")"
}

read_os_value() {
    local key="$1"
    local line

    [[ -r /etc/os-release ]] || {
        printf 'unknown'
        return
    }

    while IFS= read -r line; do
        case "$line" in
            "$key"=*)
                printf '%s' "${line#*=}"
                return
                ;;
        esac
    done < /etc/os-release

    printf 'unknown'
}

command_state() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'present'
    else
        printf 'missing'
    fi
}

sshd_config_state() {
    local daemon

    daemon="$(command -v sshd 2>/dev/null || true)"
    if [[ -z "$daemon" ]]; then
        printf 'not_available'
    elif [[ "$(id -u)" -ne 0 ]]; then
        printf 'requires_privileged_read'
    elif "$daemon" -t >/dev/null 2>&1; then
        printf 'valid'
    else
        printf 'invalid_or_incomplete'
    fi
}

case "${1:-}" in
    "")
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    --version)
        printf 'inventory.sh %s\n' "$VERSION"
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ "$#" -gt 1 ]]; then
    usage >&2
    exit 2
fi

if [[ "$(id -u)" -eq 0 ]]; then
    privilege_class="privileged"
else
    privilege_class="unprivileged"
fi

if [[ -d /run/systemd/system ]]; then
    init_style="systemd"
else
    init_style="other_or_unknown"
fi

emit inventory_schema "1"
emit inventory_version "$VERSION"
emit generated_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
emit os_id "$(read_os_value ID)"
emit os_version "$(read_os_value VERSION_ID)"
emit architecture "$(uname -m 2>/dev/null || printf 'unknown')"
emit privilege_class "$privilege_class"
emit init_style "$init_style"
emit command_bash "$(command_state bash)"
emit command_git "$(command_state git)"
emit command_ssh "$(command_state ssh)"
emit command_sshd "$(command_state sshd)"
emit command_sudo "$(command_state sudo)"
emit sshd_config_state "$(sshd_config_state)"
