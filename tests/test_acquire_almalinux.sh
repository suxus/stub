#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SCRIPT="$ROOT/acquire.sh"
readonly SCENARIO="${1:-}"

fail() {
    printf 'FAIL [%s]: %s\n' "$SCENARIO" "$*" >&2
    exit 1
}

assert_almalinux_8_10() {
    local id version
    id="$(awk -F= '$1 == "ID" {gsub(/\"/, "", $2); print $2}' /etc/os-release)"
    version="$(awk -F= '$1 == "VERSION_ID" {gsub(/\"/, "", $2); print $2}' /etc/os-release)"
    [[ "$id" == "almalinux" && "$version" == "8.10" ]] ||
        fail "expected AlmaLinux 8.10, got $id $version"
}

assert_all_present() {
    local command_name output
    for command_name in git ssh ssh-keygen; do
        command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
    done
    output="$($SCRIPT prerequisites-detect)"
    grep -Fxq 'git=present' <<< "$output" || fail "git post-verification"
    grep -Fxq 'ssh=present' <<< "$output" || fail "ssh post-verification"
    grep -Fxq 'ssh-keygen=present' <<< "$output" || fail "ssh-keygen post-verification"
    grep -Fxq 'ca-trust=present' <<< "$output" || fail "CA trust post-verification"
}

install_baseline() {
    dnf install -y -- git openssh-clients ca-certificates
    assert_all_present
}

remove_command_package() {
    local command_name="$1" command_path package_name
    command_path="$(command -v "$command_name")" || fail "$command_name unavailable before removal"
    package_name="$(rpm -qf "$command_path")" || fail "cannot resolve package for $command_path"
    rpm -e --nodeps "$package_name"
    hash -r
    command -v "$command_name" >/dev/null 2>&1 && fail "$command_name remained after removing $package_name"
    return 0
}

remove_git_packages() {
    rpm -e --nodeps git git-core
    hash -r
    command -v git >/dev/null 2>&1 && fail "git remained after removing git and git-core"
}

remove_ssh_packages_for_keygen_test() {
    rpm -e --nodeps openssh-clients openssh
    hash -r
    command -v ssh >/dev/null 2>&1 && fail "ssh remained after removing OpenSSH packages"
    command -v ssh-keygen >/dev/null 2>&1 && fail "ssh-keygen remained after removing OpenSSH packages"
}

run_install() {
    "$SCRIPT" prerequisites-install --authorize-prerequisite-install
    assert_all_present
}

snapshot_package_state() {
    find /var/cache/dnf /var/lib/dnf /etc/yum.repos.d -xdev \
        -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum | awk '{print $1}'
}

assert_almalinux_8_10
[[ -x "$SCRIPT" ]] || fail "acquire.sh is not executable"

case "$SCENARIO" in
    fresh)
        "$SCRIPT" prerequisites-detect
        "$SCRIPT" prerequisites-plan
        run_install
        ;;
    git-missing)
        install_baseline
        remove_git_packages
        "$SCRIPT" prerequisites-plan | grep -Fq 'Packages: git' || fail "git package plan"
        run_install
        ;;
    ssh-missing)
        install_baseline
        saved="$(mktemp)"
        cp -- "$(command -v ssh-keygen)" "$saved"
        remove_command_package ssh
        install -m 0755 -- "$saved" /usr/local/bin/ssh-keygen
        "$SCRIPT" prerequisites-plan | grep -Fq 'Packages: openssh-clients' || fail "ssh package plan"
        run_install
        rm -f -- /usr/local/bin/ssh-keygen "$saved"
        command -v ssh-keygen >/dev/null 2>&1 || fail "package ssh-keygen missing after shim removal"
        ;;
    ssh-keygen-missing)
        install_baseline
        saved="$(mktemp)"
        cp -- "$(command -v ssh)" "$saved"
        remove_ssh_packages_for_keygen_test
        install -m 0755 -- "$saved" /usr/local/bin/ssh
        "$SCRIPT" prerequisites-plan | grep -Fq 'Packages: openssh-clients' || fail "ssh-keygen package plan"
        run_install
        rm -f -- /usr/local/bin/ssh "$saved"
        command -v ssh >/dev/null 2>&1 || fail "package ssh missing after shim removal"
        ;;
    ca-certificates-missing)
        install_baseline
        dnf reinstall -y --setopt=keepcache=True -- ca-certificates
        find /var/cache/dnf -type f -name 'ca-certificates*.rpm' -print -quit | grep -q . ||
            fail "cached ca-certificates RPM unavailable for recovery test"
        rpm -e --nodeps ca-certificates
        "$SCRIPT" prerequisites-plan | grep -Fq 'Packages: ca-certificates' || fail "CA package plan"
        run_install
        ;;
    all-present)
        install_baseline
        "$SCRIPT" prerequisites-detect
        "$SCRIPT" prerequisites-plan | grep -Fq 'Packages: none' || fail "all-present plan"
        ;;
    repository-error)
        install_baseline
        remove_git_packages
        mkdir -p /tmp/original-repos
        shopt -s nullglob
        repo_files=(/etc/yum.repos.d/*.repo)
        ((${#repo_files[@]})) || fail "no repository definitions found"
        mv -- "${repo_files[@]}" /tmp/original-repos/
        shopt -u nullglob
        printf '[unreachable]\nname=unreachable\nbaseurl=file:///nonexistent-repository\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/unreachable.repo
        dnf clean all
        if "$SCRIPT" prerequisites-install --authorize-prerequisite-install; then
            fail "repository failure was accepted"
        fi
        command -v git >/dev/null 2>&1 && fail "git unexpectedly appeared after repository failure"
        ;;
    repeated-install)
        install_baseline
        remove_git_packages
        run_install
        before="$(rpm -qa | sort | sha256sum | awk '{print $1}')"
        "$SCRIPT" prerequisites-install --authorize-prerequisite-install | grep -Fq 'prerequisites already present' ||
            fail "repeat execution did not take the no-change path"
        after="$(rpm -qa | sort | sha256sum | awk '{print $1}')"
        [[ "$before" == "$after" ]] || fail "repeat execution changed installed packages"
        ;;
    detect-plan-readonly)
        before="$(snapshot_package_state)"
        "$SCRIPT" prerequisites-detect
        "$SCRIPT" prerequisites-plan
        after="$(snapshot_package_state)"
        [[ "$before" == "$after" ]] || fail "detect or plan changed package/cache state"
        ;;
    authorized-install)
        run_install
        ;;
    acquire-offline-contract)
        install_baseline
        "$ROOT/tests/test_acquire.sh"
        ;;
    post-install-verification)
        if command -v git >/dev/null 2>&1; then
            remove_git_packages
        fi
        mock_bin="$(mktemp -d)"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_bin/dnf"
        chmod 0755 "$mock_bin/dnf"
        if PATH="$mock_bin:$PATH" "$SCRIPT" prerequisites-install --authorize-prerequisite-install; then
            fail "post-install verification failure was accepted"
        fi
        command -v git >/dev/null 2>&1 && fail "mock installation unexpectedly supplied git"
        ;;
    *) fail "unknown scenario" ;;
esac

printf 'PASS: AlmaLinux 8.10 scenario %s\n' "$SCENARIO"
