#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="2.0.0"
readonly GITHUB_HOST="github.com"
readonly GITHUB_ED25519_KEY="AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
readonly GITHUB_ED25519_FINGERPRINT="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
readonly GITHUB_READ_ONLY_MESSAGE="ERROR: The key you are authenticating with has been marked as read only."

MODE=""
REPOSITORY=""
KEY_PATH=""
DESTINATION=""
REVISION=""
EXPECTED_OLD_ORIGIN=""
NEW_ORIGIN=""
SSH_CONFIG=""
AUTHORIZED_ACQUIRE=0
AUTHORIZED_PREREQUISITE_INSTALL=0
AUTHORIZED_ORIGIN_ADOPTION=0
TEMP_PARENT=""
TEMP_PATH=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  acquire.sh prerequisites-detect
  acquire.sh prerequisites-plan
  acquire.sh prerequisites-install --authorize-prerequisite-install
  acquire.sh prepare --authorize-acquire --repository OWNER/REPOSITORY \
    --key-path /ABSOLUTE/PRIVATE/KEY/PATH
  acquire.sh checkout --authorize-acquire --repository OWNER/REPOSITORY \
    --key-path /ABSOLUTE/PRIVATE/KEY/PATH --destination /ABSOLUTE/CHECKOUT/PATH \
    --revision FULL_40_CHARACTER_COMMIT
  acquire.sh verify --authorize-acquire --repository OWNER/REPOSITORY \
    --key-path /ABSOLUTE/PRIVATE/KEY/PATH --destination /ABSOLUTE/CHECKOUT/PATH \
    --revision FULL_40_CHARACTER_COMMIT
  acquire.sh adopt-origin --authorize-origin-adoption \
    --repository OWNER/REPOSITORY --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
    --destination /ABSOLUTE/CHECKOUT/PATH \
    --revision FULL_40_CHARACTER_COMMIT \
    --expected-old-origin git@github.com:OWNER/REPOSITORY.git \
    --new-origin git@github-owner-repository:OWNER/REPOSITORY.git \
    --ssh-config /ABSOLUTE/SSH/CONFIG

Detect and plan are strictly read-only. Prerequisite installation is a separate,
explicitly authorized operation. prepare creates or validates one ED25519 keypair
without network access. checkout and verify contact only github.com, fetch the
exact revision in temporary state, and require GitHub's explicit read-only-key
rejection of a dry-run push. No mode performs a real push.
EOF
}

cleanup_temp() {
    [[ -n "$TEMP_PATH" ]] || return
    if [[ -n "$TEMP_PARENT" && "$TEMP_PATH" == "$TEMP_PARENT"/.acquire-* &&
        "$TEMP_PATH" != "$TEMP_PARENT" && -d "$TEMP_PATH" ]]; then
        rm -rf -- "$TEMP_PATH"
    else
        printf 'WARNING: refused unsafe temporary cleanup: %s\n' "$TEMP_PATH" >&2
    fi
    TEMP_PATH=""
    TEMP_PARENT=""
}

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
    [[ "$repository" != *..* && "$repository" != */. && "$repository" != ./* ]] || fail "invalid repository"
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
        [[ "$current" == "/" ]] && current="/$part" || current="$current/$part"
        [[ ! -L "$current" ]] || fail "symlink path component refused: $current"
        [[ ! -e "$current" || "$current" == "$path" || -d "$current" ]] ||
            fail "non-directory path component refused: $current"
    done
}

ensure_directory_chain() {
    local path="$1" new_mode="$2" current="/" part owner mode_value
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$current" == "/" ]] && current="/$part" || current="$current/$part"
        [[ ! -L "$current" ]] || fail "symlink directory refused: $current"
        if [[ -e "$current" ]]; then [[ -d "$current" ]] || fail "directory required: $current"; else mkdir -m "$new_mode" -- "$current"; fi
    done
    owner="$(stat -c '%u' -- "$path")"
    [[ "$owner" == "$(id -u)" ]] || fail "directory is not owned by the executing identity: $path"
    mode_value=$((8#$(stat -c '%a' -- "$path")))
    (( (mode_value & 8#22) == 0 )) || fail "directory is group/world writable: $path"
}

safe_git() {
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_TERMINAL_PROMPT=0 \
        command git \
        -c core.hooksPath=/dev/null \
        -c core.fsmonitor=false \
        -c credential.helper= \
        -c protocol.ext.allow=never \
        "$@"
}

os_release_path() { printf '%s' /etc/os-release; }
ca_bundle_candidates() {
    printf '%s' /etc/ssl/certs/ca-certificates.crt:/etc/pki/tls/certs/ca-bundle.crt:/etc/ssl/ca-bundle.pem
}

ca_trust_usable() {
    local candidate candidates
    local -a ca_paths=()
    candidates="$(ca_bundle_candidates)"
    IFS=':' read -r -a ca_paths <<< "$candidates"
    for candidate in "${ca_paths[@]}"; do
        if [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]] &&
            awk '$0 == "-----BEGIN CERTIFICATE-----" {found=1; exit} END {exit !found}' "$candidate"; then
            return 0
        fi
    done
    return 1
}

prerequisite_state() {
    local command_name
    for command_name in git ssh ssh-keygen; do
        command -v "$command_name" >/dev/null 2>&1 && printf '%s=present\n' "$command_name" || printf '%s=missing\n' "$command_name"
    done
    ca_trust_usable && printf 'ca-trust=present\n' || printf 'ca-trust=missing\n'
}
missing_prerequisites() { prerequisite_state | awk -F= '$2 == "missing" {print $1}'; }
assert_prerequisites() {
    local missing
    missing="$(missing_prerequisites)"
    [[ -z "$missing" ]] || fail "missing prerequisites: $(tr '\n' ' ' <<< "$missing" | sed 's/[[:space:]]*$//')"
}

read_os_field() {
    local field="$1" path line value=""
    path="$(os_release_path)"
    [[ -r "$path" && -f "$path" ]] || fail "OS release metadata is unavailable"
    while IFS= read -r line; do
        case "$line" in
            "$field"=*) value="${line#*=}"; value="${value#\"}"; value="${value%\"}"; printf '%s' "${value,,}"; return ;;
        esac
    done < "$path"
}

detect_os_family() {
    local id id_like token rhel=0 debian=0
    id="$(read_os_field ID)" || return 1
    id_like="$(read_os_field ID_LIKE)" || return 1
    for token in $id $id_like; do
        case "$token" in
            almalinux|rhel|centos|rocky|fedora) rhel=1 ;;
            debian|ubuntu) debian=1 ;;
        esac
    done
    if [[ "$rhel" -eq 1 && "$debian" -eq 0 ]]; then printf 'rhel';
    elif [[ "$debian" -eq 1 && "$rhel" -eq 0 ]]; then printf 'debian';
    elif [[ "$rhel" -eq 1 && "$debian" -eq 1 ]]; then fail "ambiguous OS family";
    else fail "unsupported OS family"; fi
}

select_package_manager() {
    local family="$1"
    case "$family" in
        rhel)
            if command -v dnf >/dev/null 2>&1; then printf 'dnf';
            elif command -v yum >/dev/null 2>&1; then printf 'yum';
            else fail "no supported RHEL-family package manager is available"; fi ;;
        debian) command -v apt-get >/dev/null 2>&1 || fail "apt-get is unavailable for the Debian-family system"; printf 'apt-get' ;;
        *) fail "unsupported OS family: $family" ;;
    esac
}

build_prerequisite_plan() {
    local family manager item package
    local -a missing=() packages=()
    family="$(detect_os_family)" || return 1
    while IFS= read -r item; do [[ -n "$item" ]] && missing+=("$item"); done < <(missing_prerequisites)
    manager="$(select_package_manager "$family")" || return 1
    for item in "${missing[@]}"; do
        case "$item" in
            git) package="git" ;;
            ssh|ssh-keygen) [[ "$family" == "rhel" ]] && package="openssh-clients" || package="openssh-client" ;;
            ca-trust) package="ca-certificates" ;;
            *) fail "no package mapping exists for prerequisite: $item" ;;
        esac
        [[ " ${packages[*]} " == *" $package "* ]] || packages+=("$package")
    done
    printf 'OS family: %s\nPackage manager: %s\n' "$family" "$manager"
    printf 'Missing prerequisites:'; ((${#missing[@]})) && printf ' %s' "${missing[@]}" || printf ' none'
    printf '\nPackages:'; ((${#packages[@]})) && printf ' %s' "${packages[@]}" || printf ' none'
    printf '\nNetwork: configured distribution package repositories (installation only)\n'
    printf 'Host changes: package database/cache, listed package files, CA trust, and package hooks (installation only)\n'
}

install_prerequisites() {
    local plan family manager package_text
    local -a packages=()
    [[ "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 1 ]] || fail "prerequisites-install requires --authorize-prerequisite-install"
    [[ "$(id -u)" -eq 0 ]] || fail "prerequisite installation requires root privileges"
    plan="$(build_prerequisite_plan)" || fail "unable to build prerequisite installation plan"
    printf '%s\n' "$plan"
    family="$(awk -F': ' '$1 == "OS family" {print $2}' <<< "$plan")"
    manager="$(awk -F': ' '$1 == "Package manager" {print $2}' <<< "$plan")"
    package_text="$(awk -F': ' '$1 == "Packages" {print $2}' <<< "$plan")"
    [[ -n "$family" && -n "$manager" && -n "$package_text" ]] || fail "prerequisite plan is incomplete"
    if [[ "$package_text" == "none" ]]; then assert_prerequisites; printf 'acquire.sh %s: prerequisites already present\n' "$VERSION"; return; fi
    read -r -a packages <<< "$package_text"
    printf 'Authorized installation starting. No distribution upgrade, general upgrade, or autoremove will run.\n'
    case "$manager" in
        dnf|yum) "$manager" install -y -- "${packages[@]}" ;;
        apt-get) apt-get install --yes --no-upgrade -- "${packages[@]}" ;;
        *) fail "unsupported package manager: $manager" ;;
    esac
    assert_prerequisites
    printf 'acquire.sh %s: prerequisite installation verified\n' "$VERSION"
}

key_pair_state() {
    local private_key="$1" public_key="$1.pub" expected_public actual_public owner
    if [[ ! -e "$private_key" && ! -L "$private_key" && ! -e "$public_key" && ! -L "$public_key" ]]; then printf 'missing'; return; fi
    [[ -f "$private_key" && ! -L "$private_key" ]] || fail "unsafe private-key path"
    [[ -f "$public_key" && ! -L "$public_key" ]] || fail "unsafe public-key path"
    owner="$(id -u)"
    [[ "$(stat -c '%u' -- "$private_key")" == "$owner" && "$(stat -c '%u' -- "$public_key")" == "$owner" ]] || fail "key has an unexpected owner"
    [[ "$(stat -c '%a' -- "$private_key")" == "600" ]] || fail "private-key mode must be 0600"
    [[ "$(stat -c '%a' -- "$public_key")" == "644" ]] || fail "public-key mode must be 0644"
    [[ "$(awk '{print $1}' "$public_key")" == "ssh-ed25519" ]] || fail "public key is not ED25519"
    expected_public="$(ssh-keygen -y -P '' -f "$private_key" 2>/dev/null | awk '{print $1 " " $2}')" || fail "private key is invalid or passphrase-protected"
    actual_public="$(awk '{print $1 " " $2}' "$public_key")"
    [[ "$expected_public" == "$actual_public" ]] || fail "public and private key do not match"
    printf 'present'
}

print_public_key() {
    local fingerprint
    fingerprint="$(ssh-keygen -lf "$KEY_PATH.pub" -E sha256 | awk '{print $2}')"
    printf 'Repository: %s\nRepository deploy-key settings: https://github.com/%s/settings/keys\n' "$REPOSITORY" "$REPOSITORY"
    printf 'Fingerprint: %s\nPublic key: %s\n' "$fingerprint" "$(<"$KEY_PATH.pub")"
    printf 'Inspect and follow the repository existing deploy-key title convention.\n'
    printf 'Generic title example: HOST - %s - read-only acquire\n' "$REPOSITORY"
    printf 'Keep "Allow write access" disabled. Verify read_only: true in the GitHub UI or API.\n'
    printf 'Changing or omitting the public-key comment does not change the cryptographic key identity.\n'
    printf 'Deploy keys are immutable: never silently rotate or replace an existing key.\n'
}

prepare_key() {
    local parent state generated_inode
    parent="$(dirname -- "$KEY_PATH")"; [[ "$parent" != "/" ]] || fail "key path must use a private subdirectory"
    assert_no_symlink_components "$KEY_PATH"; assert_no_symlink_components "$KEY_PATH.pub"; ensure_directory_chain "$parent" 0700
    state="$(key_pair_state "$KEY_PATH")"
    if [[ "$state" == "missing" ]]; then
        TEMP_PARENT="$parent"; TEMP_PATH="$(mktemp -d "$parent/.acquire-key.XXXXXX")"
        ssh-keygen -q -t ed25519 -N '' -C "repository-acquire:$REPOSITORY" -f "$TEMP_PATH/key"
        chmod 0600 "$TEMP_PATH/key"; chmod 0644 "$TEMP_PATH/key.pub"; generated_inode="$(stat -c '%d:%i' -- "$TEMP_PATH/key")"
        ln -- "$TEMP_PATH/key" "$KEY_PATH" || fail "private-key destination appeared concurrently"
        if ! ln -- "$TEMP_PATH/key.pub" "$KEY_PATH.pub"; then
            [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" && "$(stat -c '%d:%i' -- "$KEY_PATH")" == "$generated_inode" ]] && rm -f -- "$KEY_PATH"
            fail "public-key destination appeared concurrently"
        fi
        cleanup_temp; state="$(key_pair_state "$KEY_PATH")"
    fi
    [[ "$state" == "present" ]] || fail "key preparation failed"
    printf 'acquire.sh %s: key ready\n' "$VERSION"; print_public_key
}

direct_origin() { printf 'git@%s:%s.git' "$GITHUB_HOST" "$REPOSITORY"; }
repository_alias() {
    local normalized="${1,,}"
    normalized="${normalized//\//-}"
    normalized="${normalized//[^a-z0-9.-]/-}"
    printf 'github-%s' "$normalized"
}
canonical_alias_origin() { printf 'git@%s:%s.git' "$(repository_alias "$REPOSITORY")" "$REPOSITORY"; }

validate_existing_checkout() {
    local actual_remote actual_revision actual_root direct alias
    direct="$(direct_origin)"; alias="$(canonical_alias_origin)"
    [[ -d "$DESTINATION" && ! -L "$DESTINATION" && -d "$DESTINATION/.git" && ! -L "$DESTINATION/.git" ]] || fail "existing destination is not a safe Git checkout"
    [[ -f "$DESTINATION/.git/config" && ! -L "$DESTINATION/.git/config" &&
        -f "$DESTINATION/.git/HEAD" && ! -L "$DESTINATION/.git/HEAD" ]] ||
        fail "existing checkout has unsafe Git metadata"
    [[ ! -e "$DESTINATION/.git/objects/info/alternates" && ! -L "$DESTINATION/.git/objects/info/alternates" ]] ||
        fail "existing checkout uses external object alternates"
    [[ ! -e "$DESTINATION/.git/info/grafts" && ! -L "$DESTINATION/.git/info/grafts" ]] ||
        fail "existing checkout uses replacement grafts"
    actual_root="$(safe_git -C "$DESTINATION" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ "$actual_root" == "$DESTINATION" ]] || fail "existing checkout redirects its work tree"
    actual_remote="$(safe_git -C "$DESTINATION" config --local --no-includes --get remote.origin.url 2>/dev/null || true)"
    [[ "$actual_remote" == "$direct" || "$actual_remote" == "$alias" ]] || fail "existing checkout has an unexpected origin"
    actual_revision="$(safe_git -C "$DESTINATION" rev-parse HEAD 2>/dev/null || true)"
    [[ "$actual_revision" == "$REVISION" ]] || fail "existing checkout is not at the requested revision"
    [[ -z "$(safe_git -C "$DESTINATION" status --porcelain --untracked-files=all)" ]] || fail "existing checkout is not clean"
    safe_git -C "$DESTINATION" fsck --no-progress >/dev/null || fail "existing checkout failed git fsck"
}

build_ssh_command() {
    local known_hosts="$1" ssh_binary
    ssh_binary="$(command -v ssh)"
    printf '%q -F /dev/null -i %q -o BatchMode=yes -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=10' "$ssh_binary" "$KEY_PATH" "$known_hosts"
}
git_with_ssh() { local ssh_command="$1"; shift; GIT_SSH_VARIANT=ssh GIT_SSH_COMMAND="$ssh_command" safe_git "$@"; }

remote_ref_absent() {
    local checkout="$1" ssh_command="$2" probe_ref="$3" output rc
    if output="$(git_with_ssh "$ssh_command" -C "$checkout" ls-remote --exit-code origin "$probe_ref" 2>&1)"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) return 1 ;;
        2) [[ -z "$output" ]] || fail "unexpected output while confirming absent probe ref"; return 0 ;;
        *) fail "unable to verify remote probe-ref absence" ;;
    esac
}

verify_read_only_capability() {
    local checkout="$1" ssh_command="$2" operation="$3" probe_ref probe_log push_rc
    probe_ref="refs/heads/acquire-readonly-probe-${REVISION:0:12}-$$-${RANDOM}"; probe_log="$operation/probe.log"
    remote_ref_absent "$checkout" "$ssh_command" "$probe_ref" || fail "unique capability probe ref unexpectedly exists before the probe"
    printf 'Read-only capability probe: GitHub may record this rejected dry-run push in audit data.\n'
    if git_with_ssh "$ssh_command" -C "$checkout" push --dry-run origin "$REVISION:$probe_ref" >"$probe_log" 2>&1; then push_rc=0; else push_rc=$?; fi
    remote_ref_absent "$checkout" "$ssh_command" "$probe_ref" || fail "SECURITY FAILURE: probe ref exists after dry-run capability test"
    [[ "$push_rc" -ne 0 ]] || fail "SECURITY FAILURE: repository key is write-capable"
    grep -Fqx "$GITHUB_READ_ONLY_MESSAGE" "$probe_log" || fail "INCONCLUSIVE: GitHub did not return the exact read-only-key rejection"
    printf 'Effective capability: read-only (GitHub explicit rejection verified)\n'
}

start_repository_operation() { TEMP_PARENT="$1"; TEMP_PATH="$(mktemp -d "$1/.acquire-$2.XXXXXX")"; }

prepare_remote_checkout() {
    local operation="$1" checkout known_hosts ssh_command fetched
    checkout="$operation/checkout"; known_hosts="$operation/known_hosts"
    printf '%s ssh-ed25519 %s\n' "$GITHUB_HOST" "$GITHUB_ED25519_KEY" > "$known_hosts"; chmod 0600 "$known_hosts"
    safe_git init --quiet "$checkout"; safe_git -C "$checkout" remote add origin "$(direct_origin)"; ssh_command="$(build_ssh_command "$known_hosts")"
    printf 'Outbound target: %s:22\n' "$GITHUB_HOST"
    git_with_ssh "$ssh_command" -C "$checkout" fetch --quiet --depth=1 origin "$REVISION"
    fetched="$(safe_git -C "$checkout" rev-parse FETCH_HEAD)"; [[ "$fetched" == "$REVISION" ]] || fail "fetched revision does not match the requested commit"
    safe_git -c advice.detachedHead=false -C "$checkout" checkout --quiet --detach "$REVISION"
    [[ "$(safe_git -C "$checkout" rev-parse HEAD)" == "$REVISION" ]] || fail "checkout revision verification failed"
    [[ -z "$(safe_git -C "$checkout" status --porcelain --untracked-files=all)" ]] || fail "temporary checkout is unexpectedly dirty"
    verify_read_only_capability "$checkout" "$ssh_command" "$operation"
}

checkout_repository() {
    local state destination_parent operation checkout
    assert_prerequisites; state="$(key_pair_state "$KEY_PATH")"; [[ "$state" == "present" ]] || fail "prepare and register the repository key first"
    assert_no_symlink_components "$DESTINATION"; destination_parent="$(dirname -- "$DESTINATION")"
    [[ "$destination_parent" != "/" ]] || fail "destination must use a dedicated parent directory"; ensure_directory_chain "$destination_parent" 0755
    if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
        validate_existing_checkout; start_repository_operation "$destination_parent" verify; operation="$TEMP_PATH"; prepare_remote_checkout "$operation"; cleanup_temp; validate_existing_checkout
        printf 'acquire.sh %s: existing checkout and read-only key verified\n' "$VERSION"
        printf 'Repository: %s\nRevision: %s\nDestination: %s\n' "$REPOSITORY" "$REVISION" "$DESTINATION"; return
    fi
    [[ "$MODE" != "verify" ]] || fail "verify requires an existing exact checkout"
    [[ "$DESTINATION" != "$KEY_PATH" && "$DESTINATION" != "$KEY_PATH.pub" ]] || fail "destination overlaps the key path"
    [[ "$DESTINATION" != "$(dirname -- "$KEY_PATH")"/* ]] || fail "destination may not contain the key"
    start_repository_operation "$destination_parent" repository; operation="$TEMP_PATH"; prepare_remote_checkout "$operation"; checkout="$operation/checkout"
    mv -T -n -- "$checkout" "$DESTINATION"; [[ ! -e "$checkout" ]] || fail "destination appeared concurrently; refusing replacement"
    cleanup_temp; validate_existing_checkout
    printf 'acquire.sh %s: checkout ready after read-only capability verification\n' "$VERSION"
    printf 'Repository: %s\nRevision: %s\nDestination: %s\nGitHub host-key fingerprint: %s\n' "$REPOSITORY" "$REVISION" "$DESTINATION" "$GITHUB_ED25519_FINGERPRINT"
}

adopt_origin() {
    local actual_origin expected_direct expected_alias expected_command old_command="" had_command=0
    local effective alias hostname user identities strict identity known_hosts destination_parent operation checkout fetched already_adopted=0 probe_ssh_command
    [[ "$AUTHORIZED_ORIGIN_ADOPTION" -eq 1 ]] || fail "adopt-origin requires --authorize-origin-adoption"
    expected_direct="$(direct_origin)"; expected_alias="$(canonical_alias_origin)"
    [[ "$EXPECTED_OLD_ORIGIN" == "$expected_direct" ]] || fail "expected old origin is not the canonical direct origin"
    [[ "$NEW_ORIGIN" == "$expected_alias" ]] || fail "new origin is not the canonical bootstrap alias origin"
    assert_prerequisites
    [[ "$(key_pair_state "$KEY_PATH")" == "present" ]] || fail "existing repository key is not valid"
    validate_existing_checkout
    actual_origin="$(safe_git -C "$DESTINATION" config --local --no-includes --get remote.origin.url)"
    expected_command="ssh -F $SSH_CONFIG"
    probe_ssh_command="$expected_command -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o CheckHostIP=no -o ConnectTimeout=10"
    [[ -f "$SSH_CONFIG" && ! -L "$SSH_CONFIG" ]] || fail "SSH config is missing or unsafe"
    alias="$(repository_alias "$REPOSITORY")"
    effective="$(ssh -G -F "$SSH_CONFIG" "$alias" 2>/dev/null)" || fail "cannot evaluate exact SSH config"
    hostname="$(awk '$1 == "hostname" {print $2; exit}' <<< "$effective")"
    user="$(awk '$1 == "user" {print $2; exit}' <<< "$effective")"
    identities="$(awk '$1 == "identitiesonly" {print $2; exit}' <<< "$effective")"
    strict="$(awk '$1 == "stricthostkeychecking" {print $2; exit}' <<< "$effective")"
    identity="$(awk '$1 == "identityfile" {print $2; exit}' <<< "$effective")"
    known_hosts="$(awk '$1 == "userknownhostsfile" {print $2; exit}' <<< "$effective")"
    [[ "$hostname" == "$GITHUB_HOST" && "$user" == "git" && "$identities" == "yes" &&
        ( "$strict" == "true" || "$strict" == "yes" ) && "$identity" == "$KEY_PATH" ]] ||
        fail "SSH alias does not enforce the exact GitHub host, user, key, and strict verification"
    [[ "$known_hosts" == /* && -f "$known_hosts" && ! -L "$known_hosts" ]] ||
        fail "SSH alias known_hosts path is missing or unsafe"
    grep -Fxq "$GITHUB_HOST ssh-ed25519 $GITHUB_ED25519_KEY" "$known_hosts" ||
        fail "SSH alias does not pin GitHub's exact ED25519 host key"
    if [[ "$actual_origin" == "$NEW_ORIGIN" ]]; then
        [[ "$(safe_git -C "$DESTINATION" config --local --no-includes --get core.sshCommand 2>/dev/null || true)" == "$expected_command" ]] || fail "adopted checkout has an unexpected core.sshCommand"
        already_adopted=1
    else
        [[ "$actual_origin" == "$EXPECTED_OLD_ORIGIN" ]] || fail "checkout origin does not match expected old origin"
    fi
    destination_parent="$(dirname -- "$DESTINATION")"
    start_repository_operation "$destination_parent" adopt
    operation="$TEMP_PATH"; checkout="$operation/checkout"
    safe_git init --quiet "$checkout"; safe_git -C "$checkout" remote add origin "$NEW_ORIGIN"
    GIT_SSH_VARIANT=ssh GIT_SSH_COMMAND="$probe_ssh_command" safe_git -C "$checkout" fetch --quiet --depth=1 origin "$REVISION"
    fetched="$(safe_git -C "$checkout" rev-parse FETCH_HEAD)"
    [[ "$fetched" == "$REVISION" ]] || fail "alias fetched revision does not match the requested commit"
    safe_git -c advice.detachedHead=false -C "$checkout" checkout --quiet --detach "$REVISION"
    verify_read_only_capability "$checkout" "$probe_ssh_command" "$operation"
    cleanup_temp
    if [[ "$already_adopted" -eq 1 ]]; then
        validate_existing_checkout
        printf 'acquire.sh %s: origin adoption and read-only capability already match\n' "$VERSION"
        return
    fi
    old_command="$(safe_git -C "$DESTINATION" config --local --no-includes --get core.sshCommand 2>/dev/null || true)"; [[ -z "$old_command" ]] || had_command=1
    safe_git -C "$DESTINATION" config core.sshCommand "$expected_command"
    if ! safe_git -C "$DESTINATION" remote set-url origin "$NEW_ORIGIN"; then
        if [[ "$had_command" -eq 1 ]]; then safe_git -C "$DESTINATION" config core.sshCommand "$old_command" || true; else safe_git -C "$DESTINATION" config --unset core.sshCommand || true; fi
        fail "origin adoption failed; core.sshCommand was restored"
    fi
    if [[ "$(safe_git -C "$DESTINATION" remote get-url origin 2>/dev/null || true)" != "$NEW_ORIGIN" ||
        "$(safe_git -C "$DESTINATION" config --local --no-includes --get core.sshCommand 2>/dev/null || true)" != "$expected_command" ]] ||
        ! (validate_existing_checkout); then
        safe_git -C "$DESTINATION" remote set-url origin "$EXPECTED_OLD_ORIGIN" || true
        if [[ "$had_command" -eq 1 ]]; then
            safe_git -C "$DESTINATION" config core.sshCommand "$old_command" || true
        else
            safe_git -C "$DESTINATION" config --unset core.sshCommand || true
        fi
        fail "origin adoption verification failed; prior local Git configuration was restored"
    fi
    printf 'acquire.sh %s: origin adopted explicitly\nOld origin: %s\nNew origin: %s\nSSH config: %s\n' "$VERSION" "$EXPECTED_OLD_ORIGIN" "$NEW_ORIGIN" "$SSH_CONFIG"
}

parse_args() {
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    case "$1" in
        --help|-h) usage; exit 0 ;; --version) printf 'acquire.sh %s\n' "$VERSION"; exit 0 ;;
        prerequisites-detect|prerequisites-plan|prerequisites-install|prepare|checkout|verify|adopt-origin) MODE="$1"; shift ;;
        *) usage >&2; exit 2 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --authorize-acquire) [[ "$AUTHORIZED_ACQUIRE" -eq 0 ]] || fail "--authorize-acquire was supplied more than once"; AUTHORIZED_ACQUIRE=1; shift ;;
            --authorize-prerequisite-install) [[ "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 0 ]] || fail "--authorize-prerequisite-install was supplied more than once"; AUTHORIZED_PREREQUISITE_INSTALL=1; shift ;;
            --authorize-origin-adoption) [[ "$AUTHORIZED_ORIGIN_ADOPTION" -eq 0 ]] || fail "--authorize-origin-adoption was supplied more than once"; AUTHORIZED_ORIGIN_ADOPTION=1; shift ;;
            --repository) [[ $# -ge 2 ]] || fail "--repository requires a value"; REPOSITORY="$(set_once --repository "$REPOSITORY" "$2")"; shift 2 ;;
            --key-path) [[ $# -ge 2 ]] || fail "--key-path requires a value"; KEY_PATH="$(set_once --key-path "$KEY_PATH" "$2")"; shift 2 ;;
            --destination) [[ $# -ge 2 ]] || fail "--destination requires a value"; DESTINATION="$(set_once --destination "$DESTINATION" "$2")"; shift 2 ;;
            --revision) [[ $# -ge 2 ]] || fail "--revision requires a value"; REVISION="$(set_once --revision "$REVISION" "$2")"; shift 2 ;;
            --expected-old-origin) [[ $# -ge 2 ]] || fail "--expected-old-origin requires a value"; EXPECTED_OLD_ORIGIN="$(set_once --expected-old-origin "$EXPECTED_OLD_ORIGIN" "$2")"; shift 2 ;;
            --new-origin) [[ $# -ge 2 ]] || fail "--new-origin requires a value"; NEW_ORIGIN="$(set_once --new-origin "$NEW_ORIGIN" "$2")"; shift 2 ;;
            --ssh-config) [[ $# -ge 2 ]] || fail "--ssh-config requires a value"; SSH_CONFIG="$(set_once --ssh-config "$SSH_CONFIG" "$2")"; shift 2 ;;
            *) fail "unknown argument: $1" ;;
        esac
    done
}

require_basic_commands() {
    local command_name
    for command_name in awk chmod dirname grep id ln mkdir mktemp mv realpath rm sed stat tr; do command -v "$command_name" >/dev/null 2>&1 || fail "required command is unavailable: $command_name"; done
}

main() {
    trap cleanup_temp EXIT
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_PARAMETERS \
        GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PROXY_COMMAND GIT_REPLACE_REF_BASE \
        GIT_SSH GIT_SSH_COMMAND GIT_WORK_TREE
    parse_args "$@"; require_basic_commands
    case "$MODE" in
        prerequisites-detect)
            [[ "$AUTHORIZED_ACQUIRE" -eq 0 && "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 0 && "$AUTHORIZED_ORIGIN_ADOPTION" -eq 0 && -z "$REPOSITORY$KEY_PATH$DESTINATION$REVISION$EXPECTED_OLD_ORIGIN$NEW_ORIGIN$SSH_CONFIG" ]] || fail "prerequisites-detect accepts no options"
            printf 'acquire.sh %s prerequisite detection\n' "$VERSION"; prerequisite_state; detect_os_family >/dev/null ;;
        prerequisites-plan)
            [[ "$AUTHORIZED_ACQUIRE" -eq 0 && "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 0 && "$AUTHORIZED_ORIGIN_ADOPTION" -eq 0 && -z "$REPOSITORY$KEY_PATH$DESTINATION$REVISION$EXPECTED_OLD_ORIGIN$NEW_ORIGIN$SSH_CONFIG" ]] || fail "prerequisites-plan accepts no options"
            printf 'acquire.sh %s prerequisite plan\n' "$VERSION"; build_prerequisite_plan ;;
        prerequisites-install)
            [[ "$AUTHORIZED_ACQUIRE" -eq 0 && "$AUTHORIZED_ORIGIN_ADOPTION" -eq 0 && -z "$REPOSITORY$KEY_PATH$DESTINATION$REVISION$EXPECTED_OLD_ORIGIN$NEW_ORIGIN$SSH_CONFIG" ]] || fail "prerequisites-install accepts only its dedicated authorization flag"
            install_prerequisites ;;
        prepare|checkout|verify)
            [[ "$AUTHORIZED_ACQUIRE" -eq 1 ]] || fail "$MODE requires --authorize-acquire"
            [[ "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 0 && "$AUTHORIZED_ORIGIN_ADOPTION" -eq 0 ]] || fail "$MODE does not accept another mode authorization"
            [[ -n "$REPOSITORY" && -n "$KEY_PATH" ]] || fail "--repository and --key-path are required"
            [[ -z "$EXPECTED_OLD_ORIGIN$NEW_ORIGIN$SSH_CONFIG" ]] || fail "$MODE does not accept origin-adoption options"
            validate_repository "$REPOSITORY"; KEY_PATH="$(normalize_path --key-path "$KEY_PATH")"; [[ "$KEY_PATH" != *.pub ]] || fail "--key-path must name the private key, not a .pub file"
            if [[ "$MODE" == "prepare" ]]; then
                [[ -z "$DESTINATION$REVISION" ]] || fail "prepare does not accept checkout options"; command -v ssh-keygen >/dev/null 2>&1 || fail "required command is unavailable: ssh-keygen"; prepare_key
            else
                [[ -n "$DESTINATION" && -n "$REVISION" ]] || fail "$MODE requires --destination and --revision"; [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a lowercase 40-character commit SHA"
                DESTINATION="$(normalize_path --destination "$DESTINATION")"; checkout_repository
            fi ;;
        adopt-origin)
            [[ "$AUTHORIZED_ACQUIRE" -eq 0 && "$AUTHORIZED_PREREQUISITE_INSTALL" -eq 0 ]] || fail "adopt-origin accepts only its dedicated authorization flag"
            [[ -n "$REPOSITORY$KEY_PATH$DESTINATION$REVISION$EXPECTED_OLD_ORIGIN$NEW_ORIGIN$SSH_CONFIG" ]] || fail "adopt-origin requires repository, key path, destination, revision, both origins, and SSH config"
            validate_repository "$REPOSITORY"
            [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a lowercase 40-character commit SHA"
            KEY_PATH="$(normalize_path --key-path "$KEY_PATH")"
            DESTINATION="$(normalize_path --destination "$DESTINATION")"; SSH_CONFIG="$(normalize_path --ssh-config "$SSH_CONFIG")"; adopt_origin ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
