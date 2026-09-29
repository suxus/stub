#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/acquire.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    [[ -n "$TEST_ROOT" && "$TEST_ROOT" == /tmp/* && -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "command unexpectedly succeeded: $*"; fi; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3"; }

bash -n "$SCRIPT"
[[ "$($SCRIPT --version)" == "acquire.sh 2.0.0" ]] || fail "version output"
$SCRIPT --help >/dev/null
expect_failure "$SCRIPT" prepare --repository example/project --key-path "$TEST_ROOT/keys/repository"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository invalid --key-path "$TEST_ROOT/keys/repository"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository example/project --key-path relative/key

key_path="$TEST_ROOT/keys/repository"
prepare_output="$($SCRIPT prepare --authorize-acquire --repository example/project --key-path "$key_path")"
[[ -f "$key_path" && -f "$key_path.pub" ]] || fail "keypair not created"
[[ "$(stat -c '%a' "$key_path")" == "600" && "$(stat -c '%a' "$key_path.pub")" == "644" ]] || fail "key modes"
assert_contains "$prepare_output" 'Repository: example/project' "repository output"
assert_contains "$prepare_output" 'Repository deploy-key settings: https://github.com/example/project/settings/keys' "settings link"
assert_contains "$prepare_output" 'Fingerprint: SHA256:' "fingerprint output"
assert_contains "$prepare_output" 'Public key: ssh-ed25519 ' "public-key output"
assert_contains "$prepare_output" 'Allow write access' "write-access warning"
assert_contains "$prepare_output" 'read_only: true' "authoritative configuration check"
assert_contains "$prepare_output" 'Generic title example:' "generic title guidance"

key_hash="$(sha256sum "$key_path" | awk '{print $1}')"
$SCRIPT prepare --authorize-acquire --repository example/project --key-path "$key_path" >/dev/null
[[ "$(sha256sum "$key_path" | awk '{print $1}')" == "$key_hash" ]] || fail "existing key changed"

half_key="$TEST_ROOT/half/repository"
mkdir -m 0700 "$TEST_ROOT/half"
cp "$key_path.pub" "$half_key.pub"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository example/project --key-path "$half_key"

mismatch="$TEST_ROOT/mismatch/repository"
mkdir -m 0700 "$TEST_ROOT/mismatch"
cp "$key_path" "$mismatch"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/other"
cp "$TEST_ROOT/other.pub" "$mismatch.pub"
chmod 0600 "$mismatch"; chmod 0644 "$mismatch.pub"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository example/project --key-path "$mismatch"

source_repo="$TEST_ROOT/source"
bare_repo="$TEST_ROOT/remote.git"
mkdir -m 0700 "$source_repo"
git -C "$source_repo" init --quiet -b main
git -C "$source_repo" config user.name test
git -C "$source_repo" config user.email test@example.invalid
printf 'reviewed fixture\n' > "$source_repo/fixture.txt"
git -C "$source_repo" add fixture.txt
git -C "$source_repo" commit --quiet -m fixture
revision="$(git -C "$source_repo" rev-parse HEAD)"
git clone --quiet --bare "$source_repo" "$bare_repo"

mock_bin="$TEST_ROOT/mock-bin"
mkdir -m 0700 "$mock_bin"
cat > "$mock_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-G" ]] && exec /usr/bin/ssh "$@"
case "$*" in
    *git-upload-pack*)
        [[ "${FAKE_FETCH_MODE:-ok}" == ok ]] || { printf 'repository unavailable\n' >&2; exit 255; }
        exec git-upload-pack "$FAKE_REMOTE"
        ;;
    *git-receive-pack*)
        case "${FAKE_PUSH_MODE:-read_only}" in
            read_only)
                printf '%s\n' 'ERROR: The key you are authenticating with has been marked as read only.' >&2
                exit 1
                ;;
            write_success) exec git-receive-pack "$FAKE_REMOTE" ;;
            network) printf '%s\n' 'ssh: connect to host github.com: Network is unreachable' >&2; exit 255 ;;
            auth) printf '%s\n' 'git@github.com: Permission denied (publickey).' >&2; exit 255 ;;
            changed) printf '%s\n' 'ERROR: deploy key cannot write' >&2; exit 1 ;;
        esac
        ;;
    *) printf 'unexpected mock ssh invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$mock_bin/ssh"

destination="$TEST_ROOT/checkouts/project"
success_output="$(PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_PUSH_MODE=read_only \
    "$SCRIPT" checkout --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision")"
[[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || fail "checkout revision"
[[ "$(git -C "$destination" remote get-url origin)" == "git@github.com:example/project.git" ]] || fail "checkout origin"
[[ -z "$(git -C "$destination" status --porcelain)" ]] || fail "checkout cleanliness"
assert_contains "$success_output" 'GitHub may record this rejected dry-run push in audit data' "audit warning"
assert_contains "$success_output" 'Effective capability: read-only' "read-only capability result"

PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_PUSH_MODE=read_only \
    "$SCRIPT" verify --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision" >/dev/null
[[ "$(sha256sum "$key_path" | awk '{print $1}')" == "$key_hash" ]] || fail "verify changed key"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_PUSH_MODE=read_only \
    "$SCRIPT" verify --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$TEST_ROOT/checkouts/missing" --revision "$revision"

for failure_mode in write_success network auth changed; do
    failed_destination="$TEST_ROOT/checkouts/fail-$failure_mode"
    expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_PUSH_MODE="$failure_mode" \
        "$SCRIPT" checkout --authorize-acquire --repository example/project --key-path "$key_path" \
        --destination "$failed_destination" --revision "$revision"
    [[ ! -e "$failed_destination" ]] || fail "checkout published before successful probe: $failure_mode"
    if find "$TEST_ROOT/checkouts" -maxdepth 1 -type d -name '.acquire-*' -print -quit | grep -q .; then
        fail "temporary directory remained after $failure_mode"
    fi
done
fetch_failure="$TEST_ROOT/checkouts/fetch-failure"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_FETCH_MODE=network \
    "$SCRIPT" checkout --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$fetch_failure" --revision "$revision"
[[ ! -e "$fetch_failure" ]] || fail "checkout published after repository fetch failure"

printf 'drift\n' >> "$destination/fixture.txt"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" FAKE_PUSH_MODE=read_only \
    "$SCRIPT" verify --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision"
git -C "$destination" restore fixture.txt

conflict="$TEST_ROOT/checkouts/conflict"
mkdir "$conflict"; printf 'preserve\n' > "$conflict/marker"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" checkout --authorize-acquire --repository example/project --key-path "$key_path" \
    --destination "$conflict" --revision "$revision"
grep -Fq preserve "$conflict/marker" || fail "conflicting destination changed"

# Function-level classification covers refs that unexpectedly exist before or
# after the probe without requiring any remote ref mutation.
# shellcheck source=../acquire.sh
source "$SCRIPT"
# acquire.sh intentionally defines its own fail helper when sourced.
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
trap cleanup EXIT
(
    REVISION="$revision"
    operation="$TEST_ROOT/probe-unit-success"; mkdir "$operation"
    remote_ref_absent() { return 0; }
    git_with_ssh() { printf '%s\n' "$GITHUB_READ_ONLY_MESSAGE" >&2; return 1; }
    verify_read_only_capability ignored ignored "$operation" >/dev/null
)
if (
    REVISION="$revision"; operation="$TEST_ROOT/probe-unit-pre"; mkdir "$operation"
    remote_ref_absent() { return 1; }; git_with_ssh() { return 1; }
    verify_read_only_capability ignored ignored "$operation" >/dev/null 2>&1
); then fail "pre-existing probe ref accepted"; fi
if (
    REVISION="$revision"; calls=0
    operation="$TEST_ROOT/probe-unit-post"; mkdir "$operation"
    remote_ref_absent() { calls=$((calls + 1)); [[ "$calls" -eq 1 ]]; }
    git_with_ssh() { printf '%s\n' "$GITHUB_READ_ONLY_MESSAGE" >&2; return 1; }
    verify_read_only_capability ignored ignored "$operation" >/dev/null 2>&1
); then fail "post-probe ref accepted"; fi

# Pinned bootstrap contract from suxus/scripts f5568ad3d1a024df835e7ddf56f437a5876edd02.
REPOSITORY="suxus/scripts"
[[ "$(repository_alias "$REPOSITORY")" == "github-suxus-scripts" ]] || fail "bootstrap alias contract"
[[ "$(canonical_alias_origin)" == "git@github-suxus-scripts:suxus/scripts.git" ]] || fail "bootstrap origin contract"
REPOSITORY=""

# Explicit adoption is offline-tested through the same SSH transport mock.
ssh_config="$TEST_ROOT/ssh_config"
known_hosts="$TEST_ROOT/known_hosts"
printf '%s ssh-ed25519 %s\n' github.com "$GITHUB_ED25519_KEY" > "$known_hosts"
printf 'Host github-example-project\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n    UserKnownHostsFile %s\n    StrictHostKeyChecking yes\n' "$key_path" "$known_hosts" > "$ssh_config"
PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" adopt-origin --authorize-origin-adoption --repository example/project \
    --key-path "$key_path" --destination "$destination" --revision "$revision" \
    --expected-old-origin git@github.com:example/project.git \
    --new-origin git@github-example-project:example/project.git \
    --ssh-config "$ssh_config" >/dev/null
[[ "$(git -C "$destination" remote get-url origin)" == "git@github-example-project:example/project.git" ]] || fail "adopted origin"
[[ "$(git -C "$destination" config --get core.sshCommand)" == "ssh -F $ssh_config" ]] || fail "adopted SSH config"
PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" adopt-origin --authorize-origin-adoption --repository example/project \
    --key-path "$key_path" --destination "$destination" --revision "$revision" \
    --expected-old-origin git@github.com:example/project.git \
    --new-origin git@github-example-project:example/project.git \
    --ssh-config "$ssh_config" >/dev/null

# Prerequisite plans are tested without writes by sourcing the functions and
# overriding only read-only discovery inputs inside subshells.
os_rhel="$TEST_ROOT/os-rhel"; printf 'ID=almalinux\nID_LIKE="rhel fedora"\n' > "$os_rhel"
os_debian="$TEST_ROOT/os-debian"; printf 'ID=ubuntu\nID_LIKE=debian\n' > "$os_debian"
os_ambiguous="$TEST_ROOT/os-ambiguous"; printf 'ID=custom\nID_LIKE="rhel debian"\n' > "$os_ambiguous"
os_unknown="$TEST_ROOT/os-unknown"; printf 'ID=custom\nID_LIKE=unknown\n' > "$os_unknown"

plan_case() {
    local test_family="$1" test_manager="$2" test_missing="$3" output
    output="$(
        os_release_path() { [[ "$test_family" == rhel ]] && printf '%s' "$os_rhel" || printf '%s' "$os_debian"; }
        ca_trust_usable() { [[ " $test_missing " != *' ca-trust '* ]]; }
        command() {
            if [[ "${1:-}" == -v ]]; then
                case "$2" in
                    dnf|yum|apt-get) [[ "$2" == "$test_manager" ]] ;;
                    git|ssh|ssh-keygen) [[ " $test_missing " != *" $2 "* ]] ;;
                    *) builtin command "$@" ;;
                esac
            else builtin command "$@"; fi
        }
        build_prerequisite_plan
    )" || fail "plan failed for $test_family/$test_manager/$test_missing"
    assert_contains "$output" "Package manager: $test_manager" "manager plan: $test_manager"
    printf '%s' "$output"
}

out="$(plan_case rhel dnf 'git')"; assert_contains "$out" 'Packages: git' "dnf git plan"
out="$(plan_case rhel yum 'ssh')"; assert_contains "$out" 'Packages: openssh-clients' "yum openssh plan"
out="$(plan_case rhel dnf 'ssh-keygen')"; assert_contains "$out" 'Packages: openssh-clients' "ssh-keygen plan"
out="$(plan_case debian apt-get 'ca-trust')"; assert_contains "$out" 'Packages: ca-certificates' "CA trust plan"
out="$(plan_case debian apt-get 'ssh-keygen ca-trust')"; assert_contains "$out" 'Packages: openssh-client ca-certificates' "apt plan"
out="$(plan_case rhel dnf 'git ssh ssh-keygen ca-trust')"; assert_contains "$out" 'Packages: git openssh-clients ca-certificates' "combined plan"
out="$(plan_case debian apt-get '')"; assert_contains "$out" 'Packages: none' "all-present plan"

if (
    os_release_path() { printf '%s' "$os_ambiguous"; }
    command() { [[ "${1:-}" == -v ]] && return 0; builtin command "$@"; }
    ca_trust_usable() { return 0; }
    build_prerequisite_plan >/dev/null 2>&1
); then fail "ambiguous OS accepted"; fi
if (
    os_release_path() { printf '%s' "$os_unknown"; }
    command() { [[ "${1:-}" == -v ]] && return 0; builtin command "$@"; }
    ca_trust_usable() { return 0; }
    build_prerequisite_plan >/dev/null 2>&1
); then fail "unknown OS accepted"; fi
if (
    os_release_path() { printf '%s' "$os_rhel"; }
    command() { if [[ "${1:-}" == -v && ( "$2" == dnf || "$2" == yum ) ]]; then return 1; fi; builtin command "$@"; }
    ca_trust_usable() { return 0; }
    build_prerequisite_plan >/dev/null 2>&1
); then fail "missing package manager accepted"; fi

# Authorized installation: exact packages, repeat safety, package error, and
# independent post-install verification.
(
    present=""; ca_present=0; install_calls=0; logged=""
    os_release_path() { printf '%s' "$os_rhel"; }
    id() { [[ "${1:-}" == -u ]] && printf '0\n' || command id "$@"; }
    ca_trust_usable() { [[ "$ca_present" -eq 1 ]]; }
    command() {
        if [[ "${1:-}" == -v ]]; then
            case "$2" in dnf) return 0 ;; yum|apt-get) return 1 ;; git|ssh|ssh-keygen) [[ " $present " == *" $2 "* ]] ;; *) builtin command "$@" ;; esac
        else builtin command "$@"; fi
    }
    dnf() {
        install_calls=$((install_calls + 1)); logged="$*"
        present='git ssh ssh-keygen'; ca_present=1
    }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null
    [[ "$install_calls" -eq 1 && "$logged" == 'install -y -- git openssh-clients ca-certificates' ]] || exit 1
    install_prerequisites >/dev/null
    [[ "$install_calls" -eq 1 ]] || exit 1
) || fail "authorized prerequisite installation/idempotence"
(
    present='git'; logged=""
    os_release_path() { printf '%s' "$os_rhel"; }
    id() { printf '0\n'; }
    ca_trust_usable() { return 0; }
    command() {
        if [[ "${1:-}" == -v ]]; then
            case "$2" in yum) return 0 ;; dnf|apt-get) return 1 ;; git|ssh|ssh-keygen) [[ " $present " == *" $2 "* ]] ;; *) builtin command "$@" ;; esac
        else builtin command "$@"; fi
    }
    yum() { logged="$*"; present='git ssh ssh-keygen'; }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null
    [[ "$logged" == 'install -y -- openssh-clients' ]]
) || fail "yum installation contract"
(
    present='ssh ssh-keygen'; logged=""; ca_present=0
    os_release_path() { printf '%s' "$os_debian"; }
    id() { printf '0\n'; }
    ca_trust_usable() { [[ "$ca_present" -eq 1 ]]; }
    command() {
        if [[ "${1:-}" == -v ]]; then
            case "$2" in apt-get) return 0 ;; dnf|yum) return 1 ;; git|ssh|ssh-keygen) [[ " $present " == *" $2 "* ]] ;; *) builtin command "$@" ;; esac
        else builtin command "$@"; fi
    }
    apt-get() { logged="$*"; present='git ssh ssh-keygen'; ca_present=1; }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null
    [[ "$logged" == 'install --yes --no-upgrade -- git ca-certificates' ]]
) || fail "apt-get installation contract"
if (
    id() { printf '1000\n'; }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null 2>&1
); then fail "unprivileged installation accepted"; fi
if (
    os_release_path() { printf '%s' "$os_debian"; }
    id() { printf '0\n'; }
    ca_trust_usable() { return 1; }
    command() { if [[ "${1:-}" == -v ]]; then [[ "$2" == apt-get ]]; else builtin command "$@"; fi; }
    apt-get() { return 1; }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null 2>&1
); then fail "package failure accepted"; fi
if (
    os_release_path() { printf '%s' "$os_rhel"; }
    id() { printf '0\n'; }
    ca_trust_usable() { return 1; }
    command() { if [[ "${1:-}" == -v ]]; then [[ "$2" == dnf ]]; else builtin command "$@"; fi; }
    dnf() { return 0; }
    AUTHORIZED_PREREQUISITE_INSTALL=1
    install_prerequisites >/dev/null 2>&1
); then fail "post-install verification failure accepted"; fi

# The real CLI detect/plan paths must not alter the inspected fixture tree.
readonly_fixture="$TEST_ROOT/read-only-fixture"; mkdir "$readonly_fixture"; printf 'stable\n' > "$readonly_fixture/value"
before="$(find "$readonly_fixture" -printf '%P %s %T@\n' | sort)"
$SCRIPT prerequisites-detect >/dev/null
$SCRIPT prerequisites-plan >/dev/null
after="$(find "$readonly_fixture" -printf '%P %s %T@\n' | sort)"
[[ "$before" == "$after" ]] || fail "detect/plan modified fixture state"

grep -Fq 'Never use' "$ROOT/README.md" || fail "staging prohibition documentation"
grep -Fq 'curl | bash' "$ROOT/README.md" || fail "curl-pipe-shell documentation"
grep -Fq 'Independently verify its SHA-256' "$ROOT/README.md" || fail "staging checksum documentation"
grep -Fq 'Package-manager rollback is not claimed' "$ROOT/README.md" || fail "rollback limitation documentation"

if find "$TEST_ROOT" -type d -name '.acquire-*' -print -quit | grep -q .; then fail "temporary directory remained"; fi

printf 'PASS: acquire security, prerequisite, and bootstrap contracts\n'
