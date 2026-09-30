#!/usr/bin/env bash

# Assertions intentionally compare literal shell source from the runbook.
# shellcheck disable=SC2016

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly RUNBOOK="$ROOT/docs/legacy-source-toolchain-runbook.md"
readonly README="$ROOT/README.md"

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
    local file="$1" expected="$2" label="$3"
    grep -Fq -- "$expected" "$file" || fail_test "$label"
}

[[ -f "$RUNBOOK" ]] || fail_test "runbook is missing"
assert_contains "$README" '(docs/legacy-source-toolchain-runbook.md)' \
    "README does not link to the runbook"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
plan_block="$scratch/plan.sh"
install_block="$scratch/install.sh"

sed -n '/^# RUNBOOK_PLAN_START$/,/^# RUNBOOK_PLAN_END$/p' "$RUNBOOK" > "$plan_block"
sed -n '/^# RUNBOOK_INSTALL_START$/,/^# RUNBOOK_INSTALL_END$/p' "$RUNBOOK" > "$install_block"
[[ -s "$plan_block" ]] || fail_test "plan block was not extracted"
[[ -s "$install_block" ]] || fail_test "install block was not extracted"
bash -n "$plan_block" "$install_block"
shellcheck --shell=bash "$plan_block" "$install_block"

if grep -Eq '\[[^]]+\]\([^)]+\)' "$plan_block" "$install_block"; then
    fail_test "Markdown link syntax found in a shell example"
fi
if grep -Fq -- 'git -C' "$plan_block" "$install_block"; then
    fail_test "shell example uses git -C, which is unavailable in Git 1.8.3"
fi

assert_contains "$plan_block" 'set -euo pipefail' "plan block lacks strict mode"
assert_contains "$plan_block" 'umask 077' "plan block lacks restrictive umask"
assert_contains "$plan_block" '[[ "$(id -u)" -eq 0 ]]' "plan block lacks root check"
assert_contains "$plan_block" '${STUB_ROOT:?' "missing STUB_ROOT does not fail closed"
assert_contains "$plan_block" '${STUB_REVISION:?' "missing revision does not fail closed"
assert_contains "$plan_block" '${BOOTSTRAP_SHA256:?' "missing checksum does not fail closed"
assert_contains "$plan_block" '[[ ! -L "$STUB_ROOT" ]]' "checkout symlink is not refused"
assert_contains "$plan_block" '[[ ! -L "$STUB_ROOT/.git" ]]' ".git symlink is not refused"
assert_contains "$plan_block" '[[ "$origin_urls" == "$EXPECTED_ORIGIN" ]]' \
    "unexpected origin does not fail closed"
assert_contains "$plan_block" 'status --porcelain=v1 --untracked-files=all' \
    "dirty checkout is not checked"
assert_contains "$plan_block" 'fetch --no-tags --prune origin' \
    "origin/main fetch is not tag-free"
assert_contains "$plan_block" '[[ "$fetched_revision" == "$STUB_REVISION" ]]' \
    "advanced remote main does not fail closed"
assert_contains "$plan_block" 'checkout --detach "$STUB_REVISION"' \
    "reviewed revision is not checked out detached"
assert_contains "$plan_block" '[[ "$actual_sha256" == "$BOOTSTRAP_SHA256" ]]' \
    "checksum mismatch does not fail closed"
assert_contains "$plan_block" 'GIT_CONFIG_NOSYSTEM=1' \
    "system Git configuration is not disabled"
assert_contains "$plan_block" 'GIT_CONFIG_GLOBAL=/dev/null' \
    "global Git configuration is not disabled"
assert_contains "$plan_block" 'unsupported local Git configuration' \
    "unexpected local Git configuration is not refused"
assert_contains "$plan_block" 'checkout contains an executable Git hook' \
    "executable Git hooks are not refused"
assert_contains "$plan_block" './bootstrap-source-toolchain.sh plan' \
    "plan command is missing"
if grep -Fq -- './bootstrap-source-toolchain.sh install' "$plan_block"; then
    fail_test "plan block also performs installation"
fi

assert_contains "$install_block" '${INSTALL_AUTHORIZED:-}' \
    "install block lacks separate authorization check"
assert_contains "$install_block" 'source_build=available-after-explicit-authorization' \
    "eligible source-build result is missing"
assert_contains "$install_block" 'source_build=not-needed-existing-installation-ready' \
    "eligible ready-state result is missing"
assert_contains "$install_block" './bootstrap-source-toolchain.sh install --authorize-source-build' \
    "authorized install command is missing"
if grep -Fq -- './bootstrap-source-toolchain.sh plan' "$install_block"; then
    fail_test "install block also runs the plan"
fi
assert_contains "$install_block" '/usr/local/bin/git --version' \
    "Git version verification is missing"
assert_contains "$install_block" '/usr/local/bin/git --exec-path' \
    "Git exec-path verification is missing"
assert_contains "$install_block" '/opt/suxus/bash/5.2.37/bin/bash --version' \
    "Bash version verification is missing"
assert_contains "$RUNBOOK" 'SOURCE_TOOLCHAIN_READY' "success marker is missing"

if grep -Ein 'BEGIN [A-Z ]*PRIVATE KEY|hostname[[:space:]]*\(|([0-9]{1,3}[.]){3}[0-9]{1,3}' \
    "$RUNBOOK" "$README"; then
    fail_test "host or sensitive infrastructure material detected"
fi

# Exercise the published plan block against an entirely local synthetic remote.
# The executable test copy substitutes only the expected public origin, while
# static assertions continue to protect the public URL in the documented block.
fake_bin="$scratch/bin"
fixture_work="$scratch/fixture-work"
fixture_remote="$scratch/fixture-remote.git"
public_origin='https://github.com/suxus/stub.git'
mkdir "$fake_bin"
cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -u ]] || exit 2
printf '0\n'
EOF
chmod 0755 "$fake_bin/id"

git init -q --bare "$fixture_remote"
git init -q "$fixture_work"
git -C "$fixture_work" config user.name 'Runbook Fixture'
git -C "$fixture_work" config user.email 'runbook-fixture@example.invalid'
cat > "$fixture_work/bootstrap-source-toolchain.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == plan ]] || exit 2
printf 'source_build=available-after-explicit-authorization\n'
: > "${PLAN_SENTINEL:?}"
EOF
chmod 0755 "$fixture_work/bootstrap-source-toolchain.sh"
git -C "$fixture_work" add bootstrap-source-toolchain.sh
git -C "$fixture_work" commit -q -m 'synthetic reviewed baseline'
git -C "$fixture_work" branch -M main
git -C "$fixture_work" remote add origin "$fixture_remote"
git -C "$fixture_work" push -q -u origin main
git -C "$fixture_remote" symbolic-ref HEAD refs/heads/main

reviewed_revision="$(git -C "$fixture_work" rev-parse HEAD)"
reviewed_checksum="$(sha256sum "$fixture_work/bootstrap-source-toolchain.sh" | awk '{print $1}')"
runtime_origin="file://$fixture_remote"
sed "s|$public_origin|$runtime_origin|" "$plan_block" > "$scratch/executable-plan.sh"
plan_block="$scratch/executable-plan.sh"

run_plan() {
    local checkout="$1" revision="$2" checksum="$3" sentinel="$4"
    env \
        GIT_CONFIG_NOSYSTEM=1 \
        PATH="$fake_bin:$PATH" \
        STUB_ROOT="$checkout" \
        STUB_REVISION="$revision" \
        BOOTSTRAP_SHA256="$checksum" \
        PLAN_SENTINEL="$sentinel" \
        bash "$plan_block"
}

missing_sentinel="$scratch/missing-sentinel"
expect_failure env \
    -u STUB_ROOT -u STUB_REVISION -u BOOTSTRAP_SHA256 \
    GIT_CONFIG_NOSYSTEM=1 \
    PATH="$fake_bin:$PATH" \
    PLAN_SENTINEL="$missing_sentinel" \
    bash "$plan_block"
[[ ! -e "$missing_sentinel" ]] || fail_test "missing inputs executed the plan"

success_checkout="$scratch/success-checkout"
success_sentinel="$scratch/success-sentinel"
run_plan "$success_checkout" "$reviewed_revision" "$reviewed_checksum" \
    "$success_sentinel" >/dev/null
[[ -f "$success_sentinel" ]] || fail_test "valid reviewed plan was not executed"
[[ "$(git -C "$success_checkout" rev-parse HEAD)" == "$reviewed_revision" ]] || \
    fail_test "valid checkout did not remain at the reviewed revision"

checksum_checkout="$scratch/checksum-checkout"
checksum_sentinel="$scratch/checksum-sentinel"
expect_failure run_plan "$checksum_checkout" "$reviewed_revision" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    "$checksum_sentinel"
[[ ! -e "$checksum_sentinel" ]] || fail_test "checksum mismatch executed the plan"

dirty_checkout="$scratch/dirty-checkout"
git clone -q "$fixture_remote" "$dirty_checkout"
git -C "$dirty_checkout" remote set-url origin "$runtime_origin"
printf 'dirty\n' > "$dirty_checkout/untracked"
expect_failure run_plan "$dirty_checkout" "$reviewed_revision" "$reviewed_checksum" \
    "$scratch/dirty-sentinel"
[[ ! -e "$scratch/dirty-sentinel" ]] || fail_test "dirty checkout executed the plan"

wrong_origin_checkout="$scratch/wrong-origin-checkout"
git clone -q "$fixture_remote" "$wrong_origin_checkout"
expect_failure run_plan "$wrong_origin_checkout" "$reviewed_revision" \
    "$reviewed_checksum" "$scratch/wrong-origin-sentinel"
[[ ! -e "$scratch/wrong-origin-sentinel" ]] || \
    fail_test "unexpected origin executed the plan"

symlink_target="$scratch/symlink-target"
git clone -q "$fixture_remote" "$symlink_target"
git -C "$symlink_target" remote set-url origin "$runtime_origin"
ln -s "$symlink_target" "$scratch/checkout-symlink"
expect_failure run_plan "$scratch/checkout-symlink" "$reviewed_revision" \
    "$reviewed_checksum" "$scratch/checkout-symlink-sentinel"
[[ ! -e "$scratch/checkout-symlink-sentinel" ]] || \
    fail_test "checkout symlink executed the plan"

git_symlink_checkout="$scratch/git-symlink-checkout"
git clone -q "$fixture_remote" "$git_symlink_checkout"
git -C "$git_symlink_checkout" remote set-url origin "$runtime_origin"
mv "$git_symlink_checkout/.git" "$scratch/git-metadata"
ln -s "$scratch/git-metadata" "$git_symlink_checkout/.git"
expect_failure run_plan "$git_symlink_checkout" "$reviewed_revision" \
    "$reviewed_checksum" "$scratch/git-symlink-sentinel"
[[ ! -e "$scratch/git-symlink-sentinel" ]] || \
    fail_test ".git symlink executed the plan"

printf 'advanced\n' > "$fixture_work/reviewed-change"
git -C "$fixture_work" add reviewed-change
git -C "$fixture_work" commit -q -m 'synthetic advanced main'
git -C "$fixture_work" push -q origin main
advanced_checkout="$scratch/advanced-checkout"
expect_failure run_plan "$advanced_checkout" "$reviewed_revision" \
    "$reviewed_checksum" "$scratch/advanced-sentinel"
[[ ! -e "$scratch/advanced-sentinel" ]] || fail_test "advanced main executed the plan"

printf 'PASS: legacy source-toolchain runbook contracts\n'
