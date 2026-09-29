#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/acquire.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    [[ -n "$TEST_ROOT" && "$TEST_ROOT" == /tmp/* && -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

bash -n "$SCRIPT"
[[ "$($SCRIPT --version)" == "acquire.sh 1.0.0" ]] || fail "version output"
$SCRIPT --help >/dev/null
expect_failure "$SCRIPT" prepare --repository example/project --key-path "$TEST_ROOT/keys/repository"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository invalid --key-path "$TEST_ROOT/keys/repository"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository example/project --key-path relative/key

key_path="$TEST_ROOT/keys/repository"
prepare_output="$($SCRIPT prepare --authorize-acquire --repository example/project --key-path "$key_path")"
[[ -f "$key_path" && -f "$key_path.pub" ]] || fail "keypair not created"
[[ "$(stat -c '%a' "$key_path")" == "600" ]] || fail "private-key mode"
[[ "$(stat -c '%a' "$key_path.pub")" == "644" ]] || fail "public-key mode"
grep -Fq 'Repository: example/project' <<<"$prepare_output" || fail "repository output"
grep -Fq 'Fingerprint: SHA256:' <<<"$prepare_output" || fail "fingerprint output"
grep -Fq 'Public key: ssh-ed25519 ' <<<"$prepare_output" || fail "public-key output"

key_hash="$(sha256sum "$key_path" | awk '{print $1}')"
$SCRIPT prepare --authorize-acquire --repository example/project --key-path "$key_path" >/dev/null
[[ "$(sha256sum "$key_path" | awk '{print $1}')" == "$key_hash" ]] || fail "existing key changed"

half_key="$TEST_ROOT/half/repository"
mkdir -m 0700 "$TEST_ROOT/half"
cp "$key_path.pub" "$half_key.pub"
expect_failure "$SCRIPT" prepare --authorize-acquire --repository example/project --key-path "$half_key"

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
exec git-upload-pack "$FAKE_REMOTE"
EOF
chmod 0755 "$mock_bin/ssh"

destination="$TEST_ROOT/checkouts/project"
PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" checkout --authorize-acquire \
    --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision" >/dev/null

[[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] || fail "checkout revision"
[[ "$(git -C "$destination" remote get-url origin)" == "git@github.com:example/project.git" ]] || fail "checkout origin"
[[ -z "$(git -C "$destination" status --porcelain)" ]] || fail "checkout cleanliness"

PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" checkout --authorize-acquire \
    --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision" >/dev/null

printf 'drift\n' >> "$destination/fixture.txt"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" checkout --authorize-acquire \
    --repository example/project --key-path "$key_path" \
    --destination "$destination" --revision "$revision"

conflict="$TEST_ROOT/checkouts/conflict"
mkdir "$conflict"
printf 'preserve\n' > "$conflict/marker"
expect_failure env PATH="$mock_bin:$PATH" FAKE_REMOTE="$bare_repo" \
    "$SCRIPT" checkout --authorize-acquire \
    --repository example/project --key-path "$key_path" \
    --destination "$conflict" --revision "$revision"
grep -Fq preserve "$conflict/marker" || fail "conflicting destination changed"

if find "$TEST_ROOT" -type d -name '.acquire.*' -print -quit | grep -q .; then
    fail "temporary directory remained"
fi

printf 'PASS: acquire contract\n'
