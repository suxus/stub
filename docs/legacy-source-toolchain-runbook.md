# Legacy source-toolchain runbook

This public runbook describes a fail-closed operator procedure for obtaining an
exact reviewed revision of `suxus/stub`, verifying the bootstrap script against
an independently supplied checksum, running only its plan, and—after a separate
authorization—running its narrowly scoped installation mode.

It is not a deployment procedure. It contains no SSH workflow, host inventory,
management route, or environment-specific value. Perform the procedure only on
the intended legacy system through its separately approved local operator
process.

## Required independent inputs

Before starting, obtain all three values through an approved channel that is
independent of the checkout being verified:

- `STUB_ROOT`: an absolute, unused destination or an existing dedicated Stub
  checkout;
- `STUB_REVISION`: the full 40-character commit SHA that was reviewed;
- `BOOTSTRAP_SHA256`: the independently reviewed SHA-256 checksum of
  `bootstrap-source-toolchain.sh` at that revision.

Do not derive the expected checksum only from the checkout that it is meant to
verify. Do not use a branch name, tag, abbreviated SHA, or current remote state
as a substitute for the separately approved revision.

The public baseline current when this runbook was written is Stub commit
`d051de882b704eb42e158cbfce4983e13469a1da`, with bootstrap-script SHA-256
`f7faa3243fdac8f879546259c1b09e1960d690cea509441c9e8607c415c290ea`.
These values are an example, not standing authorization. Every future run must
use a freshly reviewed revision and checksum supplied through the independent
approval channel.

## Acquire the reviewed revision and run only the plan

Enter a root shell through the approved local operator process, export the
three required values, and run the block below as a unit. It deliberately does
not contain example assignments: an unset value must stop before any checkout
or network action.

For a new destination, the block creates the directory and initializes the
checkout. If `STUB_ROOT` already exists, it must already be a clean, dedicated
checkout with the exact public `origin`; the block never initializes,
overwrites, cleans, resets, or repairs an existing path. Review and remove a
failed new initialization manually before reusing that path.

```bash
# RUNBOOK_PLAN_START
set -euo pipefail
umask 077

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

repo_git() {
    (
        cd -- "$STUB_ROOT"
        git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
    )
}

[[ "$(id -u)" -eq 0 ]] || fail "run this procedure as root"

: "${STUB_ROOT:?set STUB_ROOT to the approved absolute checkout path}"
: "${STUB_REVISION:?set STUB_REVISION to the approved full commit SHA}"
: "${BOOTSTRAP_SHA256:?set BOOTSTRAP_SHA256 to the approved SHA-256}"

readonly EXPECTED_ORIGIN='https://github.com/suxus/stub.git'
readonly STUB_ROOT STUB_REVISION BOOTSTRAP_SHA256

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

[[ "$STUB_ROOT" == /* && "$STUB_ROOT" != / ]] || \
    fail "STUB_ROOT must be an absolute non-root path"
[[ "$STUB_ROOT" != *$'\n'* ]] || fail "STUB_ROOT must not contain a newline"
[[ "$STUB_REVISION" =~ ^[0-9a-f]{40}$ ]] || \
    fail "STUB_REVISION must be a full lowercase commit SHA"
[[ "$BOOTSTRAP_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
    fail "BOOTSTRAP_SHA256 must be a lowercase SHA-256"
[[ ! -L "$STUB_ROOT" ]] || fail "STUB_ROOT must not be a symlink"

if [[ ! -e "$STUB_ROOT" ]]; then
    mkdir -- "$STUB_ROOT"
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false init -q "$STUB_ROOT"
    repo_git remote add origin "$EXPECTED_ORIGIN"
else
    [[ -d "$STUB_ROOT" ]] || fail "existing STUB_ROOT must be a directory"
fi

[[ ! -L "$STUB_ROOT/.git" ]] || fail ".git must not be a symlink"
[[ -d "$STUB_ROOT/.git" ]] || fail "STUB_ROOT is not a dedicated Git checkout"

stub_root_physical="$(cd -- "$STUB_ROOT" && pwd -P)"
git_top="$(repo_git rev-parse --show-toplevel 2>/dev/null)" || \
    fail "STUB_ROOT is not a Git checkout"
git_top_physical="$(cd -- "$git_top" && pwd -P)"
[[ "$git_top_physical" == "$stub_root_physical" ]] || \
    fail "STUB_ROOT is not the checkout root"

while IFS= read -r config_key; do
    case "$config_key" in
        core.repositoryformatversion|core.filemode|core.bare|\
        core.logallrefupdates|remote.origin.url|remote.origin.fetch|\
        branch.*.remote|branch.*.merge)
            ;;
        *)
            fail "unsupported local Git configuration: $config_key"
            ;;
    esac
done < <(repo_git config --local --name-only --list)

executable_hook="$(find "$STUB_ROOT/.git/hooks" -type f -perm /111 ! -name '*.sample' -print -quit 2>/dev/null || true)"
[[ -z "$executable_hook" ]] || fail "checkout contains an executable Git hook"

origin_urls="$(repo_git config --get-all remote.origin.url || true)"
[[ "$origin_urls" == "$EXPECTED_ORIGIN" ]] || \
    fail "origin must be exactly $EXPECTED_ORIGIN"

before_status="$(repo_git status --porcelain=v1 --untracked-files=all)"
[[ -z "$before_status" ]] || fail "checkout must be clean before fetch"

repo_git fetch --no-tags --prune origin \
    '+refs/heads/main:refs/remotes/origin/main'
fetched_revision="$(repo_git rev-parse --verify 'FETCH_HEAD^{commit}')"
[[ "$fetched_revision" == "$STUB_REVISION" ]] || \
    fail "remote main differs from the separately approved revision"

repo_git checkout --detach "$STUB_REVISION"
head_revision="$(repo_git rev-parse --verify HEAD)"
[[ "$head_revision" == "$STUB_REVISION" ]] || \
    fail "detached HEAD does not equal the approved revision"

after_status="$(repo_git status --porcelain=v1 --untracked-files=all)"
[[ -z "$after_status" ]] || fail "checkout must remain clean after checkout"

bootstrap="$STUB_ROOT/bootstrap-source-toolchain.sh"
[[ -f "$bootstrap" && ! -L "$bootstrap" ]] || \
    fail "bootstrap-source-toolchain.sh must be a regular non-symlink file"
actual_sha256="$(sha256sum -- "$bootstrap" | awk '{print $1}')"
[[ "$actual_sha256" == "$BOOTSTRAP_SHA256" ]] || \
    fail "bootstrap-source-toolchain.sh checksum mismatch"

cd -- "$STUB_ROOT"
./bootstrap-source-toolchain.sh plan
printf '%s\n' "PLAN ONLY: review the complete output; installation was not started"
# RUNBOOK_PLAN_END
```

The fetch deliberately reads only `origin/main`, without tags. If remote
`main` has advanced beyond the separately reviewed revision, the comparison
with `FETCH_HEAD` stops the procedure. Do not change the requested revision to
make the check pass. Review and approve the new revision and its independently
obtained checksum first, then start again with those new approved inputs.

The plan may let yum read or refresh its normal repository metadata while it
queries available Git versions, but it performs no package transaction and
does not build or publish software. Preserve and review its complete output.
The final line printed by this wrapper confirms only that the plan command
finished; it is not installation authorization.

## Decision and separate installation authorization

Stop after the plan. Installation is a package/source-build mutation and needs
separate, explicit authorization based on the reviewed plan output.

Only either of these exact plan results is eligible for the idempotent
install/verify command:

- `source_build=available-after-explicit-authorization`
- `source_build=not-needed-existing-installation-ready`

Every other result is a stop condition. Do not force or bypass a refusal, edit
the script, change paths manually, or attempt an ad hoc repair. Investigate and
obtain a newly reviewed procedure if remediation is required.

After separate authorization, export `INSTALL_AUTHORIZED=yes` and set
`APPROVED_PLAN_RESULT` to the exact eligible line from the reviewed plan. Keep
the same independently supplied `STUB_ROOT`, `STUB_REVISION`, and
`BOOTSTRAP_SHA256`. Then run this separate block:

```bash
# RUNBOOK_INSTALL_START
set -euo pipefail
umask 077

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

repo_git() {
    (
        cd -- "$STUB_ROOT"
        git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
    )
}

[[ "$(id -u)" -eq 0 ]] || fail "run this procedure as root"

: "${STUB_ROOT:?set STUB_ROOT to the approved absolute checkout path}"
: "${STUB_REVISION:?set STUB_REVISION to the approved full commit SHA}"
: "${BOOTSTRAP_SHA256:?set BOOTSTRAP_SHA256 to the approved SHA-256}"
: "${APPROVED_PLAN_RESULT:?set APPROVED_PLAN_RESULT from the reviewed plan}"
[[ "${INSTALL_AUTHORIZED:-}" == yes ]] || \
    fail "installation has not received separate explicit authorization"

case "$APPROVED_PLAN_RESULT" in
    source_build=available-after-explicit-authorization|\
    source_build=not-needed-existing-installation-ready)
        ;;
    *)
        fail "the reviewed plan result does not permit installation"
        ;;
esac

readonly EXPECTED_ORIGIN='https://github.com/suxus/stub.git'
readonly STUB_ROOT STUB_REVISION BOOTSTRAP_SHA256 APPROVED_PLAN_RESULT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

[[ "$STUB_ROOT" == /* && "$STUB_ROOT" != / ]] || \
    fail "STUB_ROOT must be an absolute non-root path"
[[ "$STUB_ROOT" != *$'\n'* ]] || fail "STUB_ROOT must not contain a newline"
[[ "$STUB_REVISION" =~ ^[0-9a-f]{40}$ ]] || \
    fail "STUB_REVISION must be a full lowercase commit SHA"
[[ "$BOOTSTRAP_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
    fail "BOOTSTRAP_SHA256 must be a lowercase SHA-256"
[[ ! -L "$STUB_ROOT" ]] || fail "STUB_ROOT must not be a symlink"
[[ ! -L "$STUB_ROOT/.git" ]] || fail ".git must not be a symlink"
[[ -d "$STUB_ROOT/.git" ]] || fail "STUB_ROOT is not a dedicated Git checkout"

stub_root_physical="$(cd -- "$STUB_ROOT" && pwd -P)"
git_top="$(repo_git rev-parse --show-toplevel 2>/dev/null)" || \
    fail "STUB_ROOT is not a Git checkout"
git_top_physical="$(cd -- "$git_top" && pwd -P)"
[[ "$git_top_physical" == "$stub_root_physical" ]] || \
    fail "STUB_ROOT is not the checkout root"

while IFS= read -r config_key; do
    case "$config_key" in
        core.repositoryformatversion|core.filemode|core.bare|\
        core.logallrefupdates|remote.origin.url|remote.origin.fetch|\
        branch.*.remote|branch.*.merge)
            ;;
        *)
            fail "unsupported local Git configuration: $config_key"
            ;;
    esac
done < <(repo_git config --local --name-only --list)

executable_hook="$(find "$STUB_ROOT/.git/hooks" -type f -perm /111 ! -name '*.sample' -print -quit 2>/dev/null || true)"
[[ -z "$executable_hook" ]] || fail "checkout contains an executable Git hook"

origin_urls="$(repo_git config --get-all remote.origin.url || true)"
[[ "$origin_urls" == "$EXPECTED_ORIGIN" ]] || \
    fail "origin must be exactly $EXPECTED_ORIGIN"
if repo_git symbolic-ref -q HEAD >/dev/null; then
    fail "checkout must remain detached at the approved revision"
fi
head_revision="$(repo_git rev-parse --verify HEAD)"
[[ "$head_revision" == "$STUB_REVISION" ]] || \
    fail "HEAD differs from the approved revision"
install_status="$(repo_git status --porcelain=v1 --untracked-files=all)"
[[ -z "$install_status" ]] || fail "checkout must be clean before installation"

bootstrap="$STUB_ROOT/bootstrap-source-toolchain.sh"
[[ -f "$bootstrap" && ! -L "$bootstrap" ]] || \
    fail "bootstrap-source-toolchain.sh must be a regular non-symlink file"
actual_sha256="$(sha256sum -- "$bootstrap" | awk '{print $1}')"
[[ "$actual_sha256" == "$BOOTSTRAP_SHA256" ]] || \
    fail "bootstrap-source-toolchain.sh checksum mismatch"

cd -- "$STUB_ROOT"
./bootstrap-source-toolchain.sh install --authorize-source-build
/usr/local/bin/git --version
/usr/local/bin/git --exec-path
/opt/suxus/bash/5.2.37/bin/bash --version
# RUNBOOK_INSTALL_END
```

Success requires the unambiguous `SOURCE_TOOLCHAIN_READY` marker from the
install command, followed by successful version checks. `/usr/local/bin/git`
must report Git 2.43.7 and an exec path under `/opt/suxus/git/2.43.7`; the
parallel Bash command must report Bash 5.2.37. Absence of the success marker,
an unexpected version or path, or any nonzero command exit means the procedure
did not complete successfully.

Do not replace `/bin/bash`, modify the reviewed installation paths, or treat a
partial result as success. The bootstrap script's own checks remain
authoritative and fail closed if platform, repository, package, build,
preservation, or final-verification conditions are not satisfied.
