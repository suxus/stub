#!/usr/bin/env bash

# Test doubles are intentionally defined in subshells after sourcing the script.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SCRIPT="$ROOT/bootstrap-source-toolchain.sh"

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail_test "command unexpectedly succeeded: $*"
    fi
}

assert_contains() {
    local text="$1" expected="$2" label="$3"
    grep -Fq -- "$expected" <<< "$text" || fail_test "$label"
}

bash -n "$SCRIPT"
[[ "$(bash "$SCRIPT" --version)" == "bootstrap-source-toolchain.sh 1.0.0" ]] || fail_test "version output"
bash "$SCRIPT" --help >/dev/null

# shellcheck source=../bootstrap-source-toolchain.sh
source "$SCRIPT"

inventory_fixture() {
    local id="$1" version="$2" init="$3"
    printf '%s\n' \
        inventory_schema=1 \
        inventory_version=1.0.0 \
        generated_utc=2026-01-01T00:00:00Z \
        "os_id=$id" \
        "os_version=$version" \
        architecture=x86_64 \
        privilege_class=privileged \
        "init_style=$init" \
        command_bash=present \
        command_git=present \
        command_ssh=present \
        command_sshd=present \
        command_sudo=present \
        sshd_config_state=valid
}

(
    inventory_report() { inventory_fixture centos 7 systemd; }
    [[ "$(validate_platform)" == platform=centos-7-systemd ]] || exit 1
) || fail_test "CentOS 7 systemd acceptance"

for rejected in centos-6.9 ubuntu-7 centos-other; do
    case "$rejected" in
        centos-6.9) id=centos; version=6.9; init=systemd ;;
        ubuntu-7) id=ubuntu; version=7; init=systemd ;;
        centos-other) id=centos; version=7; init=other_or_unknown ;;
    esac
    if (
        inventory_report() { inventory_fixture "$id" "$version" "$init"; }
        validate_platform >/dev/null 2>&1
    ); then
        fail_test "unsupported platform accepted: $rejected"
    fi
done

if (
    inventory_report() { inventory_fixture centos 7 systemd | sed '/^os_version=/d'; }
    validate_platform >/dev/null 2>&1
); then fail_test "missing inventory field accepted"; fi
if (
    inventory_report() { inventory_fixture centos 7 systemd; printf 'os_id=centos\n'; }
    validate_platform >/dev/null 2>&1
); then fail_test "duplicate inventory field accepted"; fi

(
    yum_git_query() { printf 'Available Packages\ngit.x86_64 1.8.3.1-27.el7_9 updates\n'; }
    output_file="$(mktemp)"
    inspect_yum_git_versions > "$output_file"
    output="$(< "$output_file")"
    rm -- "$output_file"
    [[ "$YUM_GIT_SUITABLE" -eq 0 && "$YUM_GIT_MAX" == 1.8.3.1 ]] || exit 1
    assert_contains "$output" 'minimum_git_version=2.43.7' "minimum Git report"
) || fail_test "old yum Git classification"
(
    yum_git_query() { printf 'Available Packages\ngit.x86_64 1.8.3.1-27.el7_9 base\ngit.x86_64 2.44.1-1.el7 custom\n'; }
    inspect_yum_git_versions >/dev/null
    [[ "$YUM_GIT_SUITABLE" -eq 1 && "$YUM_GIT_MAX" == 2.44.1 ]]
) || fail_test "suitable yum Git classification"
if (
    yum_git_query() { return 1; }
    inspect_yum_git_versions >/dev/null 2>&1
); then fail_test "yum metadata failure accepted"; fi
if (
    yum_git_query() { printf 'Cannot retrieve repository metadata\ngit.x86_64 1.8.3.1-27.el7_9 cached\n'; }
    inspect_yum_git_versions >/dev/null 2>&1
); then fail_test "yum metadata warning accepted"; fi
if (
    yum_git_query() { printf 'git.x86_64 release-candidate repository\n'; }
    inspect_yum_git_versions >/dev/null 2>&1
); then fail_test "unparseable yum Git version accepted"; fi

make_git_mock() {
    local path="$1" prefix="$2"
    sed \
        -e "s|@PREFIX@|$prefix|g" \
        > "$path" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    --version) printf 'git version 2.43.7\n' ;;
    --exec-path) printf '@PREFIX@/libexec/git-core\n' ;;
    'config --get protocol.ext.allow'|'-c protocol.ext.allow=never config --get protocol.ext.allow') printf 'never\n' ;;
    *) exit 1 ;;
esac
EOF
    chmod 0755 "$path"
}

make_bash_mock() {
    local path="$1"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1" in' \
        '  -c) printf "5.2.37(1)-release" ;;' \
        '  -uc) printf "EMPTY_ARRAY_SUPPORTED" ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$path"
    chmod 0755 "$path"
}

state_root="$(mktemp -d)"
trap 'rm -rf -- "$state_root"' EXIT
(
    git_prefix() { printf '%s' "$state_root/fresh/git"; }
    bash_prefix() { printf '%s' "$state_root/fresh/bash"; }
    git_link() { printf '%s' "$state_root/fresh/bin/git"; }
    [[ "$(inspect_installation_state)" == installation_state=fresh ]]
) || fail_test "fresh installation state"

(
    case_root="$state_root/ready"
    mkdir -p "$case_root/git/bin" "$case_root/bash/bin" "$case_root/bin"
    make_git_mock "$case_root/git/bin/git" "$case_root/git"
    make_bash_mock "$case_root/bash/bin/bash"
    ln -s "$case_root/git/bin/git" "$case_root/bin/git"
    git_prefix() { printf '%s' "$case_root/git"; }
    bash_prefix() { printf '%s' "$case_root/bash"; }
    git_link() { printf '%s' "$case_root/bin/git"; }
    [[ "$(inspect_installation_state)" == installation_state=ready ]]
) || fail_test "correct existing installation idempotence"

for partial in git bash; do
    if (
        case_root="$state_root/partial-$partial"
        mkdir -p "$case_root/bin" "$case_root/$partial"
        git_prefix() { printf '%s' "$case_root/git"; }
        bash_prefix() { printf '%s' "$case_root/bash"; }
        git_link() { printf '%s' "$case_root/bin/git"; }
        inspect_installation_state >/dev/null 2>&1
    ); then fail_test "partial $partial installation accepted"; fi
done

if (
    case_root="$state_root/wrong-link"
    mkdir -p "$case_root/git/bin" "$case_root/bash/bin" "$case_root/bin"
    make_git_mock "$case_root/git/bin/git" "$case_root/git"
    make_bash_mock "$case_root/bash/bin/bash"
    ln -s /unexpected/git "$case_root/bin/git"
    git_prefix() { printf '%s' "$case_root/git"; }
    bash_prefix() { printf '%s' "$case_root/bash"; }
    git_link() { printf '%s' "$case_root/bin/git"; }
    inspect_installation_state >/dev/null 2>&1
); then fail_test "wrong existing Git link accepted"; fi

checksum_fixture="$state_root/checksum"
printf 'fixture\n' > "$checksum_fixture"
expected_checksum="$(sha256sum "$checksum_fixture" | awk '{print $1}')"
verify_sha256 "$expected_checksum" "$checksum_fixture" || fail_test "correct checksum refused"
expect_failure verify_sha256 0000000000000000000000000000000000000000000000000000000000000000 "$checksum_fixture"

archive_source="$state_root/archive-source"
mkdir -p "$archive_source/fixture-root"
printf 'source\n' > "$archive_source/fixture-root/file"
tar -czf "$state_root/fixture.tar.gz" -C "$archive_source" fixture-root
archive_checksum="$(sha256sum "$state_root/fixture.tar.gz" | awk '{print $1}')"
(
    BUILD_ROOT="$state_root/extract"
    mkdir "$BUILD_ROOT"
    download_file() { cp -- "$state_root/fixture.tar.gz" "$2"; }
    download_and_extract https://example.invalid/source "$archive_checksum" source.tar.gz fixture-root
    [[ "$(< "$BUILD_ROOT/fixture-root/file")" == source ]]
) || fail_test "mocked download/extraction behavior"

(
    logged=""
    missing_build_packages() { printf 'gcc\nmake\n'; }
    yum() { logged="$*"; }
    verify_build_prerequisites() { :; }
    output_file="$(mktemp)"
    install_build_prerequisites > "$output_file"
    output="$(< "$output_file")"
    rm -- "$output_file"
    assert_contains "$output" 'build_packages=gcc,make' "package plan output"
    [[ "$logged" == 'install -y -- gcc make' ]]
) || fail_test "mocked package installation behavior"
required_packages="$(required_build_packages)"
grep -Fxq libcurl-devel <<< "$required_packages" || fail_test "CentOS 7 libcurl-devel package mapping"
if grep -Fxq curl-devel <<< "$required_packages"; then fail_test "invalid CentOS 7 curl-devel package mapping"; fi

(
    steps=""
    require_root() { steps+=root,; }
    require_preflight_commands() { steps+=commands,; }
    validate_platform() { steps+=platform,; }
    inspect_yum_git_versions() { YUM_GIT_SUITABLE=0; steps+=yum,; }
    inspect_installation_state() { INSTALLATION_STATE=fresh; steps+=state,; }
    capture_system_baseline() { steps+=baseline,; }
    install_build_prerequisites() { steps+=packages,; }
    prepare_install_parents() { steps+=parents,; }
    build_git_stage() { steps+=git-build,; }
    build_bash_stage() { steps+=bash-build,; }
    publish_stages() { steps+=publish,; }
    verify_complete_state() { steps+=verify,; }
    AUTHORIZED_SOURCE_BUILD=1
    output_file="$(mktemp)"
    install_toolchain > "$output_file"
    output="$(< "$output_file")"
    rm -- "$output_file"
    assert_contains "$output" SOURCE_TOOLCHAIN_READY "success marker"
    [[ "$steps" == root,commands,platform,yum,state,baseline,packages,parents,git-build,bash-build,publish,verify, ]]
    [[ -d "$BUILD_ROOT" ]] && rm -rf -- "$BUILD_ROOT"
) || fail_test "mocked build orchestration"

if (
    require_root() { :; }
    require_preflight_commands() { :; }
    validate_platform() { :; }
    inspect_yum_git_versions() { YUM_GIT_SUITABLE=1; }
    inspect_installation_state() { INSTALLATION_STATE=fresh; }
    capture_system_baseline() { fail_test "mutation began after suitable yum Git"; }
    AUTHORIZED_SOURCE_BUILD=1
    install_toolchain >/dev/null 2>&1
); then fail_test "source build accepted despite suitable yum Git"; fi

(
    git_state=git-rpm
    bash_state=bash-rpm
    binary_state=system-bash
    rpm_package_state() { [[ "$1" == git ]] && printf '%s' "$git_state" || printf '%s' "$bash_state"; }
    system_bash_state() { printf '%s' "$binary_state"; }
    RPM_GIT_BEFORE=git-rpm
    RPM_BASH_BEFORE=bash-rpm
    SYSTEM_BASH_BEFORE=system-bash
    verify_system_baseline
    git_state=changed
    if (verify_system_baseline >/dev/null 2>&1); then exit 1; fi
) || fail_test "RPM/system Bash preservation verification"

cleanup_root="/tmp/suxus-source-toolchain.test-$$"
mkdir "$cleanup_root"
BUILD_ROOT="$cleanup_root"
RUN_SUCCEEDED=1
cleanup
[[ ! -e "$cleanup_root" ]] || fail_test "validated temporary cleanup"
stage_parent="$state_root/stages"
stage_path="$stage_parent/.2.43.7.stage.fixture"
mkdir -p "$stage_path"
safe_remove_stage "$stage_path" "$stage_parent" .2.43.7.stage
[[ ! -e "$stage_path" ]] || fail_test "validated stage cleanup"
refused_stage="$stage_parent/unowned"
mkdir "$refused_stage"
safe_remove_stage "$refused_stage" "$stage_parent" .2.43.7.stage 2>/dev/null
[[ -d "$refused_stage" ]] || fail_test "unsafe stage cleanup was accepted"
BUILD_ROOT="$state_root/refuse-cleanup"
mkdir "$BUILD_ROOT"
cleanup 2>/dev/null
[[ -d "$BUILD_ROOT" ]] || fail_test "unsafe temporary cleanup was accepted"
BUILD_ROOT=""

if grep -Ein 'EXPECTED_HOSTNAME|hostname[[:space:]]*\(|ws[0-9]+|/root/stub|([0-9]{1,3}[.]){3}[0-9]{1,3}' \
    "$SCRIPT" "$ROOT/README.md" "$ROOT/SECURITY.md"; then
    fail_test "host or infrastructure metadata detected"
fi

printf 'PASS: source-toolchain platform, yum, state, checksum, cleanup, and preservation contracts\n'
