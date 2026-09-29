#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="1.0.0"
readonly GITHUB_HOST="github.com"
readonly GITHUB_ED25519_KEY="AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
readonly GITHUB_ED25519_FINGERPRINT="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

MODE=""
REPOSITORY=""
KEY_PATH=""
DESTINATION=""
REVISION=""
AUTHORIZED=0
TEMP_PARENT=""
TEMP_PATH=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  acquire.sh prepare --authorize-acquire --repository OWNER/REPOSITORY \
    --key-path /ABSOLUTE/PRIVATE/KEY/PATH

  acquire.sh checkout --authorize-acquire --repository OWNER/REPOSITORY \
    --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
    --destination /ABSOLUTE/CHECKOUT/PATH \
    --revision FULL_40_CHARACTER_COMMIT

prepare creates or validates one ED25519 keypair and prints only its public
material. It performs no network access. checkout contacts only github.com,
pins GitHub's ED25519 host key, and acquires exactly the requested commit.
Neither mode replaces existing keys or checkouts.
EOF
}

cleanup_temp() {
    if [[ -z "$TEMP_PATH" ]]; then
        return
    fi
    if [[ -n "$TEMP_PARENT" && "$TEMP_PATH" == "$TEMP_PARENT"/.acquire-* &&
        "$TEMP_PATH" != "$TEMP_PARENT" && -d "$TEMP_PATH" ]]; then
        rm -rf -- "$TEMP_PATH"
    else
        printf 'WARNING: refused unsafe temporary cleanup: %s\n' "$TEMP_PATH" >&2
    fi
    TEMP_PATH=""
    TEMP_PARENT=""
}

trap cleanup_temp EXIT

set_once() {
    local name="$1" current="$2" value="$3"
    [[ -z "$current" ]] || fail "$name was supplied more than once"
    [[ -n "$value" ]] || fail "$name requires a value"
    printf '%s' "$value"
}

validate_repository() {
    local repository="$1"
    [[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        fail "invalid repository; expected OWNER/REPOSITORY"
    [[ "$repository" != *..* && "$repository" != */. && "$repository" != ./* ]] ||
        fail "invalid repository"
}

normalize_path() {
    local label="$1" path="$2" normalized
    [[ "$path" == /* && "$path" != "/" ]] || fail "$label must be an absolute non-root path"
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "$label contains unsupported characters"
    normalized="$(realpath -m -- "$path")"
    [[ "$normalized" == "$path" ]] || fail "$label must already be normalized: $normalized"
    printf '%s' "$normalized"
}

assert_no_symlink_components() {
    local path="$1" current="/" part
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ "$current" == "/" ]]; then
            current="/$part"
        else
            current="$current/$part"
        fi
        [[ ! -L "$current" ]] || fail "symlink path component refused: $current"
        if [[ -e "$current" && "$current" != "$path" && ! -d "$current" ]]; then
            fail "non-directory path component refused: $current"
        fi
    done
}

ensure_directory_chain() {
    local path="$1" new_mode="$2" current="/" part owner mode_value
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ "$current" == "/" ]]; then
            current="/$part"
        else
            current="$current/$part"
        fi
        [[ ! -L "$current" ]] || fail "symlink directory refused: $current"
        if [[ -e "$current" ]]; then
            [[ -d "$current" ]] || fail "directory required: $current"
        else
            mkdir -m "$new_mode" -- "$current"
        fi
    done

    owner="$(stat -c '%u' -- "$path")"
    [[ "$owner" == "$(id -u)" ]] || fail "directory is not owned by the executing identity: $path"
    mode_value=$((8#$(stat -c '%a' -- "$path")))
    (( (mode_value & 8#22) == 0 )) || fail "directory is group/world writable: $path"
}

key_pair_state() {
    local private_key="$1" public_key="$1.pub" expected_public actual_public owner

    if [[ ! -e "$private_key" && ! -L "$private_key" &&
        ! -e "$public_key" && ! -L "$public_key" ]]; then
        printf 'missing'
        return
    fi
    [[ -f "$private_key" && ! -L "$private_key" ]] || fail "unsafe private-key path"
    [[ -f "$public_key" && ! -L "$public_key" ]] || fail "unsafe public-key path"
    owner="$(id -u)"
    [[ "$(stat -c '%u' -- "$private_key")" == "$owner" ]] || fail "private key has an unexpected owner"
    [[ "$(stat -c '%u' -- "$public_key")" == "$owner" ]] || fail "public key has an unexpected owner"
    [[ "$(stat -c '%a' -- "$private_key")" == "600" ]] || fail "private-key mode must be 0600"
    [[ "$(stat -c '%a' -- "$public_key")" == "644" ]] || fail "public-key mode must be 0644"
    [[ "$(awk '{print $1}' "$public_key")" == "ssh-ed25519" ]] || fail "public key is not ED25519"
    expected_public="$(ssh-keygen -y -P '' -f "$private_key" 2>/dev/null | awk '{print $1 " " $2}')" ||
        fail "private key is invalid or passphrase-protected"
    actual_public="$(awk '{print $1 " " $2}' "$public_key")"
    [[ "$expected_public" == "$actual_public" ]] || fail "public and private key do not match"
    printf 'present'
}

print_public_key() {
    local fingerprint
    fingerprint="$(ssh-keygen -lf "$KEY_PATH.pub" -E sha256 | awk '{print $2}')"
    printf 'Repository: %s\n' "$REPOSITORY"
    printf 'Fingerprint: %s\n' "$fingerprint"
    printf 'Public key: %s\n' "$(<"$KEY_PATH.pub")"
    printf 'Register this key on exactly that repository with write access disabled.\n'
}

safe_git() {
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_TERMINAL_PROMPT=0 \
        command git "$@"
}

prepare_key() {
    local parent state generated_inode
    parent="$(dirname -- "$KEY_PATH")"
    [[ "$parent" != "/" ]] || fail "key path must use a private subdirectory"
    assert_no_symlink_components "$KEY_PATH"
    assert_no_symlink_components "$KEY_PATH.pub"
    ensure_directory_chain "$parent" 0700
    state="$(key_pair_state "$KEY_PATH")"

    if [[ "$state" == "missing" ]]; then
        TEMP_PARENT="$parent"
        TEMP_PATH="$(mktemp -d "$parent/.acquire-key.XXXXXX")"
        ssh-keygen -q -t ed25519 -N '' -C "repository-acquire:$REPOSITORY" -f "$TEMP_PATH/key"
        chmod 0600 "$TEMP_PATH/key"
        chmod 0644 "$TEMP_PATH/key.pub"
        generated_inode="$(stat -c '%d:%i' -- "$TEMP_PATH/key")"
        ln -- "$TEMP_PATH/key" "$KEY_PATH" || fail "private-key destination appeared concurrently"
        if ! ln -- "$TEMP_PATH/key.pub" "$KEY_PATH.pub"; then
            if [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" &&
                "$(stat -c '%d:%i' -- "$KEY_PATH")" == "$generated_inode" ]]; then
                rm -f -- "$KEY_PATH"
            fi
            fail "public-key destination appeared concurrently"
        fi
        cleanup_temp
        state="$(key_pair_state "$KEY_PATH")"
    fi

    [[ "$state" == "present" ]] || fail "key preparation failed"
    printf 'acquire.sh %s: key ready\n' "$VERSION"
    print_public_key
}

validate_existing_checkout() {
    local expected_remote="git@$GITHUB_HOST:$REPOSITORY.git" actual_remote actual_revision
    [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || fail "unsafe existing checkout path"
    [[ -d "$DESTINATION/.git" && ! -L "$DESTINATION/.git" ]] || fail "existing destination is not a safe Git checkout"
    actual_remote="$(safe_git -C "$DESTINATION" remote get-url origin 2>/dev/null || true)"
    [[ "$actual_remote" == "$expected_remote" ]] || fail "existing checkout has an unexpected origin"
    actual_revision="$(safe_git -C "$DESTINATION" rev-parse HEAD 2>/dev/null || true)"
    [[ "$actual_revision" == "$REVISION" ]] || fail "existing checkout is not at the requested revision"
    [[ -z "$(safe_git -C "$DESTINATION" status --porcelain)" ]] || fail "existing checkout is not clean"
    printf 'acquire.sh %s: checkout already matches\n' "$VERSION"
    printf 'Repository: %s\nRevision: %s\nDestination: %s\n' "$REPOSITORY" "$REVISION" "$DESTINATION"
}

checkout_repository() {
    local state destination_parent operation checkout known_hosts remote ssh_binary ssh_command fetched
    state="$(key_pair_state "$KEY_PATH")"
    [[ "$state" == "present" ]] || fail "prepare and register the repository key first"

    assert_no_symlink_components "$DESTINATION"
    if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
        validate_existing_checkout
        return
    fi

    destination_parent="$(dirname -- "$DESTINATION")"
    [[ "$destination_parent" != "/" ]] || fail "destination must use a dedicated parent directory"
    ensure_directory_chain "$destination_parent" 0755
    [[ "$DESTINATION" != "$KEY_PATH" && "$DESTINATION" != "$KEY_PATH.pub" ]] ||
        fail "destination overlaps the key path"
    [[ "$DESTINATION" != "$(dirname -- "$KEY_PATH")"/* ]] || fail "destination may not contain the key"

    TEMP_PARENT="$destination_parent"
    TEMP_PATH="$(mktemp -d "$destination_parent/.acquire-repository.XXXXXX")"
    operation="$TEMP_PATH"
    checkout="$operation/checkout"
    known_hosts="$operation/known_hosts"
    printf '%s ssh-ed25519 %s\n' "$GITHUB_HOST" "$GITHUB_ED25519_KEY" > "$known_hosts"
    chmod 0600 "$known_hosts"

    safe_git init --quiet "$checkout"
    remote="git@$GITHUB_HOST:$REPOSITORY.git"
    safe_git -C "$checkout" remote add origin "$remote"
    ssh_binary="$(command -v ssh)"
    printf -v ssh_command '%q -F /dev/null -i %q -o BatchMode=yes -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10' "$ssh_binary" "$KEY_PATH" "$known_hosts"

    printf 'Outbound target: %s:22\n' "$GITHUB_HOST"
    GIT_SSH_VARIANT=ssh GIT_SSH_COMMAND="$ssh_command" \
        safe_git -C "$checkout" fetch --quiet --depth=1 origin "$REVISION"
    fetched="$(safe_git -C "$checkout" rev-parse FETCH_HEAD)"
    [[ "$fetched" == "$REVISION" ]] || fail "fetched revision does not match the requested commit"
    safe_git -c advice.detachedHead=false -C "$checkout" checkout --quiet --detach "$REVISION"
    [[ "$(safe_git -C "$checkout" rev-parse HEAD)" == "$REVISION" ]] || fail "checkout revision verification failed"
    [[ -z "$(safe_git -C "$checkout" status --porcelain)" ]] || fail "new checkout is unexpectedly dirty"

    mv -T -n -- "$checkout" "$DESTINATION"
    [[ ! -e "$checkout" ]] || fail "destination appeared concurrently; refusing replacement"
    cleanup_temp

    printf 'acquire.sh %s: checkout ready\n' "$VERSION"
    printf 'Repository: %s\nRevision: %s\nDestination: %s\n' "$REPOSITORY" "$REVISION" "$DESTINATION"
    printf 'GitHub host-key fingerprint: %s\n' "$GITHUB_ED25519_FINGERPRINT"
}

parse_args() {
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --version) printf 'acquire.sh %s\n' "$VERSION"; exit 0 ;;
        prepare|checkout) MODE="$1"; shift ;;
        *) usage >&2; exit 2 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --authorize-acquire)
                [[ "$AUTHORIZED" -eq 0 ]] || fail "--authorize-acquire was supplied more than once"
                AUTHORIZED=1
                shift
                ;;
            --repository)
                [[ $# -ge 2 ]] || fail "--repository requires a value"
                REPOSITORY="$(set_once --repository "$REPOSITORY" "$2")"
                shift 2
                ;;
            --key-path)
                [[ $# -ge 2 ]] || fail "--key-path requires a value"
                KEY_PATH="$(set_once --key-path "$KEY_PATH" "$2")"
                shift 2
                ;;
            --destination)
                [[ $# -ge 2 ]] || fail "--destination requires a value"
                DESTINATION="$(set_once --destination "$DESTINATION" "$2")"
                shift 2
                ;;
            --revision)
                [[ $# -ge 2 ]] || fail "--revision requires a value"
                REVISION="$(set_once --revision "$REVISION" "$2")"
                shift 2
                ;;
            *) fail "unknown argument: $1" ;;
        esac
    done
}

main() {
    local command
    parse_args "$@"
    [[ "$AUTHORIZED" -eq 1 ]] || fail "$MODE requires --authorize-acquire"
    [[ -n "$REPOSITORY" ]] || fail "--repository is required"
    [[ -n "$KEY_PATH" ]] || fail "--key-path is required"
    validate_repository "$REPOSITORY"

    for command in awk chmod dirname id ln mkdir mktemp realpath rm ssh-keygen stat; do
        command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
    done
    KEY_PATH="$(normalize_path --key-path "$KEY_PATH")"
    [[ "$KEY_PATH" != *.pub ]] || fail "--key-path must name the private key, not a .pub file"

    case "$MODE" in
        prepare)
            [[ -z "$DESTINATION" && -z "$REVISION" ]] || fail "prepare does not accept checkout options"
            prepare_key
            ;;
        checkout)
            command -v git >/dev/null 2>&1 || fail "required command is unavailable: git"
            command -v ssh >/dev/null 2>&1 || fail "required command is unavailable: ssh"
            [[ -n "$DESTINATION" ]] || fail "checkout requires --destination"
            [[ -n "$REVISION" ]] || fail "checkout requires --revision"
            [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a lowercase 40-character commit SHA"
            DESTINATION="$(normalize_path --destination "$DESTINATION")"
            checkout_repository
            ;;
    esac
}

main "$@"
