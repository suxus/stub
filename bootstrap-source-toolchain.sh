#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="1.0.0"
readonly GIT_VERSION="2.43.7"
readonly MINIMUM_GIT_VERSION="$GIT_VERSION"
readonly GIT_SOURCE_URL="https://www.kernel.org/pub/software/scm/git/git-2.43.7.tar.gz"
readonly GIT_SOURCE_SHA256="b30055b0dac1aebcb6f332f1fddbc81e3ce43819920a23709d71b4f76763f1f4"
readonly BASH_SOURCE_VERSION="5.2.37"
readonly BASH_VERSION_EXPECTED="5.2.37(1)-release"
readonly BASH_SOURCE_URL="https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
readonly BASH_SOURCE_SHA256="9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"

MODE=""
AUTHORIZED_SOURCE_BUILD=0
BUILD_ROOT=""
GIT_STAGE_ROOT=""
BASH_STAGE_ROOT=""
GIT_PUBLISHED=0
BASH_PUBLISHED=0
LINK_PUBLISHED=0
RUN_SUCCEEDED=0
RUN_MARKER="source-toolchain-$$-${RANDOM}"
INSTALLATION_STATE=""
YUM_GIT_VERSIONS=""
YUM_GIT_MAX=""
YUM_GIT_SUITABLE=0
RPM_GIT_BEFORE=""
RPM_BASH_BEFORE=""
SYSTEM_BASH_BEFORE=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  bootstrap-source-toolchain.sh plan
  bootstrap-source-toolchain.sh install --authorize-source-build
  bootstrap-source-toolchain.sh --help
  bootstrap-source-toolchain.sh --version

Validate a CentOS 7 systemd host and inspect the configured yum repositories.
If yum offers Git 2.43.7 or newer, source installation is refused. Otherwise,
the separately authorized install mode builds pinned Git 2.43.7 and Bash 5.2.37
under /opt/suxus without replacing the distribution packages or /bin/bash.
EOF
}

script_root() {
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
}

git_prefix() { printf '%s' /opt/suxus/git/2.43.7; }
bash_prefix() { printf '%s' /opt/suxus/bash/5.2.37; }
git_link() { printf '%s' /usr/local/bin/git; }
inventory_script() { printf '%s/inventory.sh' "$(script_root)"; }
acquire_script() { printf '%s/acquire.sh' "$(script_root)"; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || fail "this script must run as root"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_preflight_commands() {
    local command_name
    for command_name in awk bash dirname grep id paste readlink rpm sed sort stat yum; do
        require_command "$command_name"
    done
}

inventory_report() {
    local script
    script="$(inventory_script)"
    [[ -f "$script" && -x "$script" && ! -L "$script" ]] || fail "inventory.sh is unavailable beside this script"
    "$script"
}

inventory_value() {
    local report="$1" key="$2" count value
    count="$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' <<< "$report")"
    [[ "$count" -eq 1 ]] || fail "inventory field is missing or duplicated: $key"
    value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' <<< "$report")"
    [[ "$value" =~ ^[A-Za-z0-9._:+-]+$ ]] || fail "inventory field has an invalid value: $key"
    printf '%s' "$value"
}

validate_platform() {
    local report os_id os_version init_style
    report="$(inventory_report)" || fail "inventory collection failed"
    os_id="$(inventory_value "$report" os_id)"
    os_version="$(inventory_value "$report" os_version)"
    init_style="$(inventory_value "$report" init_style)"
    [[ "$os_id" == centos ]] || fail "unsupported platform: os_id must be centos"
    [[ "$os_version" == 7 ]] || fail "unsupported platform: os_version must be 7"
    [[ "$init_style" == systemd ]] || fail "unsupported platform: init_style must be systemd"
    printf 'platform=centos-7-systemd\n'
}

yum_git_query() {
    LC_ALL=C yum --quiet --showduplicates list available git
}

normalize_yum_git_version() {
    local evr="$1"
    if [[ "$evr" =~ ^([0-9]+:)?([0-9]{1,6}([.][0-9]{1,6}){1,3})(-[A-Za-z0-9_.+~]+)?$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

version_at_least() {
    local candidate="$1" minimum="$2" index left right
    local -a candidate_parts=() minimum_parts=()
    IFS='.' read -r -a candidate_parts <<< "$candidate"
    IFS='.' read -r -a minimum_parts <<< "$minimum"
    for index in 0 1 2 3; do
        left="${candidate_parts[$index]:-0}"
        right="${minimum_parts[$index]:-0}"
        ((10#$left > 10#$right)) && return 0
        ((10#$left < 10#$right)) && return 1
    done
    return 0
}

inspect_yum_git_versions() {
    local output line name evr repository extra version seen=0
    local -a versions=()
    if ! output="$(yum_git_query 2>&1)"; then
        fail "yum repository metadata query failed"
    fi
    if grep -Eiq 'cannot (find|retrieve)|could not retrieve|failed to download|failure:|no more mirrors|repodata/.*(error|failed)' <<< "$output"; then
        fail "yum repository metadata query reported an error"
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r name evr repository extra <<< "$line"
        if [[ "$name" == git || "$name" == git.* ]]; then
            [[ -n "${evr:-}" && -n "${repository:-}" && -z "${extra:-}" ]] ||
                fail "yum returned an ambiguous Git package row"
            version="$(normalize_yum_git_version "$evr")" ||
                fail "yum returned an unparseable Git candidate version"
            versions+=("$version")
            seen=1
        fi
    done <<< "$output"
    [[ "$seen" -eq 1 ]] || fail "yum returned no Git candidate versions"

    YUM_GIT_VERSIONS="$(printf '%s\n' "${versions[@]}" | sort -u | paste -sd, -)"
    YUM_GIT_MAX="${versions[0]}"
    YUM_GIT_SUITABLE=0
    for version in "${versions[@]}"; do
        version_at_least "$version" "$YUM_GIT_MAX" && YUM_GIT_MAX="$version"
        version_at_least "$version" "$MINIMUM_GIT_VERSION" && YUM_GIT_SUITABLE=1
    done
    printf 'yum_git_versions=%s\nyum_git_max=%s\nminimum_git_version=%s\n' \
        "$YUM_GIT_VERSIONS" "$YUM_GIT_MAX" "$MINIMUM_GIT_VERSION"
}

path_present() {
    [[ -e "$1" || -L "$1" ]]
}

verify_git_security_features() {
    local binary="$1" output
    output="$(
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=protocol.ext.allow \
        GIT_CONFIG_VALUE_0=never \
            "$binary" config --get protocol.ext.allow
    )" || return 1
    [[ "$output" == never ]] || return 1
    output="$("$binary" -c protocol.ext.allow=never config --get protocol.ext.allow)" || return 1
    [[ "$output" == never ]]
}

verify_git_prefix() {
    local prefix binary
    prefix="$(git_prefix)"
    [[ -d "$prefix" && ! -L "$prefix" ]] || return 1
    binary="$prefix/bin/git"
    [[ -x "$binary" && ! -L "$binary" ]] || return 1
    [[ "$("$binary" --version)" == "git version $GIT_VERSION" ]] || return 1
    [[ "$("$binary" --exec-path)" == "$prefix/libexec/git-core" ]] || return 1
    verify_git_security_features "$binary"
}

verify_bash_prefix() {
    local prefix binary
    prefix="$(bash_prefix)"
    [[ -d "$prefix" && ! -L "$prefix" ]] || return 1
    binary="$prefix/bin/bash"
    [[ -x "$binary" && ! -L "$binary" ]] || return 1
    # shellcheck disable=SC2016
    [[ "$("$binary" -c 'printf "%s" "$BASH_VERSION"')" == "$BASH_VERSION_EXPECTED" ]] || return 1
    # shellcheck disable=SC2016
    [[ "$("$binary" -uc 'values=(); for value in "${values[@]}"; do :; done; printf "EMPTY_ARRAY_SUPPORTED"')" == \
        EMPTY_ARRAY_SUPPORTED ]]
}

verify_git_link() {
    local link target
    link="$(git_link)"
    target="$(git_prefix)/bin/git"
    [[ -L "$link" && "$(readlink -- "$link")" == "$target" ]]
}

inspect_installation_state() {
    local git_state=absent bash_state=absent link_state=absent
    path_present "$(git_prefix)" && git_state=present
    path_present "$(bash_prefix)" && bash_state=present
    path_present "$(git_link)" && link_state=present

    if [[ "$git_state$bash_state$link_state" == absentabsentabsent ]]; then
        INSTALLATION_STATE=fresh
    elif [[ "$git_state$bash_state$link_state" == presentpresentpresent ]]; then
        verify_git_prefix || fail "existing Git prefix is incomplete or unexpected"
        verify_bash_prefix || fail "existing Bash prefix is incomplete or unexpected"
        verify_git_link || fail "existing Git link is incomplete or unexpected"
        INSTALLATION_STATE=ready
    else
        fail "partial source-toolchain installation state detected"
    fi
    printf 'installation_state=%s\n' "$INSTALLATION_STATE"
}

rpm_package_state() {
    rpm -q -- "$1"
}

system_bash_state() {
    local binary=/bin/bash
    [[ -x "$binary" && ! -L "$binary" ]] || return 1
    # shellcheck disable=SC2016
    printf '%s|%s|%s' \
        "$(stat -Lc '%d:%i:%s:%a:%u:%g' -- "$binary")" \
        "$(sha256sum -- "$binary" | awk '{print $1}')" \
        "$("$binary" -c 'printf "%s" "$BASH_VERSION"')"
}

capture_system_baseline() {
    require_command sha256sum
    RPM_GIT_BEFORE="$(rpm_package_state git)" || fail "the existing Git RPM must be installed"
    RPM_BASH_BEFORE="$(rpm_package_state bash)" || fail "the existing Bash RPM must be installed"
    SYSTEM_BASH_BEFORE="$(system_bash_state)" || fail "unable to capture /bin/bash baseline"
}

verify_system_baseline() {
    [[ "$(rpm_package_state git)" == "$RPM_GIT_BEFORE" ]] || fail "the existing Git RPM changed"
    [[ "$(rpm_package_state bash)" == "$RPM_BASH_BEFORE" ]] || fail "the existing Bash RPM changed"
    [[ "$(system_bash_state)" == "$SYSTEM_BASH_BEFORE" ]] || fail "/bin/bash changed"
}

required_build_packages() {
    printf '%s\n' \
        gcc \
        make \
        libcurl-devel \
        expat-devel \
        openssl-devel \
        perl-ExtUtils-MakeMaker \
        zlib-devel \
        ncurses-devel
}

missing_build_packages() {
    local package command_name missing=""
    while IFS= read -r package; do
        rpm -q -- "$package" >/dev/null 2>&1 || missing+="$package"$'\n'
    done < <(required_build_packages)
    while IFS=':' read -r command_name package; do
        command -v "$command_name" >/dev/null 2>&1 || missing+="$package"$'\n'
    done <<'EOF'
curl:curl
tar:tar
sha256sum:coreutils
EOF
    [[ -z "$missing" ]] || printf '%s' "$missing" | sort -u
    return 0
}

verify_build_prerequisites() {
    local package command_name
    while IFS= read -r package; do
        rpm -q -- "$package" >/dev/null 2>&1 || fail "build package is still missing: $package"
    done < <(required_build_packages)
    for command_name in curl gcc make sha256sum tar; do
        require_command "$command_name"
    done
}

install_build_prerequisites() {
    local package_text
    local -a packages=()
    package_text="$(missing_build_packages)"
    if [[ -z "$package_text" ]]; then
        printf 'build_packages=already-present\n'
    else
        while IFS= read -r package; do
            [[ -n "$package" ]] && packages+=("$package")
        done <<< "$package_text"
        printf 'build_packages=%s\n' "$(IFS=,; printf '%s' "${packages[*]}")"
        yum install -y -- "${packages[@]}" || fail "yum build-package installation failed"
    fi
    verify_build_prerequisites
}

assert_trusted_directory() {
    local path="$1" current=/ part owner mode_value
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$current" == / ]] && current="/$part" || current="$current/$part"
        [[ ! -L "$current" ]] || fail "symlink directory component refused: $current"
        if [[ -e "$current" ]]; then
            [[ -d "$current" ]] || fail "directory required: $current"
        else
            mkdir -m 0755 -- "$current"
        fi
        owner="$(stat -c '%u' -- "$current")"
        mode_value=$((8#$(stat -c '%a' -- "$current")))
        [[ "$owner" -eq 0 ]] || fail "directory is not root-owned: $current"
        (( (mode_value & 8#22) == 0 )) || fail "directory is group/world writable: $current"
    done
}

prepare_install_parents() {
    assert_trusted_directory "$(dirname -- "$(git_prefix)")"
    assert_trusted_directory "$(dirname -- "$(bash_prefix)")"
    assert_trusted_directory "$(dirname -- "$(git_link)")"
}

verify_sha256() {
    local expected="$1" path="$2" actual
    actual="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]]
}

download_file() {
    local url="$1" destination="$2"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --output "$destination" "$url"
}

validate_archive() {
    local archive="$1" expected_root="$2" listing entry
    listing="$(tar -tzf "$archive")" || fail "unable to list source archive"
    [[ -n "$listing" ]] || fail "source archive is empty"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || fail "source archive contains an empty path"
        [[ "$entry" != /* && "$entry" != .. && "$entry" != ../* && "$entry" != */../* ]] ||
            fail "source archive contains an unsafe path"
        [[ "$entry" == "$expected_root" || "$entry" == "$expected_root/"* ]] ||
            fail "source archive contains an unexpected root"
    done <<< "$listing"
}

download_and_extract() {
    local url="$1" checksum="$2" archive_name="$3" source_root="$4" archive
    archive="$BUILD_ROOT/$archive_name"
    download_file "$url" "$archive" || fail "source download failed"
    verify_sha256 "$checksum" "$archive" || fail "source archive checksum mismatch"
    validate_archive "$archive" "$source_root"
    tar -xzf "$archive" -C "$BUILD_ROOT" || fail "source archive extraction failed"
}

verify_staged_git() {
    local binary="$1"
    [[ -x "$binary" && ! -L "$binary" ]] || return 1
    [[ "$("$binary" --version)" == "git version $GIT_VERSION" ]] || return 1
    [[ "$("$binary" --exec-path)" == "$(git_prefix)/libexec/git-core" ]] || return 1
    verify_git_security_features "$binary"
}

verify_staged_bash() {
    local binary="$1"
    [[ -x "$binary" && ! -L "$binary" ]] || return 1
    # shellcheck disable=SC2016
    [[ "$("$binary" -c 'printf "%s" "$BASH_VERSION"')" == "$BASH_VERSION_EXPECTED" ]] || return 1
    # shellcheck disable=SC2016
    [[ "$("$binary" -uc 'values=(); for value in "${values[@]}"; do :; done; printf "EMPTY_ARRAY_SUPPORTED"')" == \
        EMPTY_ARRAY_SUPPORTED ]]
}

build_git_stage() {
    local source_dir installed
    download_and_extract "$GIT_SOURCE_URL" "$GIT_SOURCE_SHA256" "git-$GIT_VERSION.tar.gz" "git-$GIT_VERSION"
    source_dir="$BUILD_ROOT/git-$GIT_VERSION"
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || fail "Git source directory is unavailable"
    make -C "$source_dir" -j2 prefix="$(git_prefix)" NO_GETTEXT=YesPlease all || fail "Git build failed"
    GIT_STAGE_ROOT="$(mktemp -d "$(dirname -- "$(git_prefix)")/.${GIT_VERSION}.stage.XXXXXX")"
    make -C "$source_dir" DESTDIR="$GIT_STAGE_ROOT" prefix="$(git_prefix)" NO_GETTEXT=YesPlease install ||
        fail "Git staged installation failed"
    installed="$GIT_STAGE_ROOT$(git_prefix)"
    verify_staged_git "$installed/bin/git" || fail "staged Git verification failed"
    printf '%s\n' "$RUN_MARKER" > "$installed/.suxus-source-toolchain-owner"
    chmod 0600 "$installed/.suxus-source-toolchain-owner"
}

build_bash_stage() {
    local source_dir installed
    download_and_extract "$BASH_SOURCE_URL" "$BASH_SOURCE_SHA256" \
        "bash-$BASH_SOURCE_VERSION.tar.gz" "bash-$BASH_SOURCE_VERSION"
    source_dir="$BUILD_ROOT/bash-$BASH_SOURCE_VERSION"
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || fail "Bash source directory is unavailable"
    (cd -- "$source_dir" && ./configure --prefix="$(bash_prefix)") || fail "Bash configure failed"
    make -C "$source_dir" -j2 || fail "Bash build failed"
    BASH_STAGE_ROOT="$(mktemp -d "$(dirname -- "$(bash_prefix)")/.${BASH_SOURCE_VERSION}.stage.XXXXXX")"
    make -C "$source_dir" DESTDIR="$BASH_STAGE_ROOT" install || fail "Bash staged installation failed"
    installed="$BASH_STAGE_ROOT$(bash_prefix)"
    verify_staged_bash "$installed/bin/bash" || fail "staged Bash verification failed"
    printf '%s\n' "$RUN_MARKER" > "$installed/.suxus-source-toolchain-owner"
    chmod 0600 "$installed/.suxus-source-toolchain-owner"
}

publish_stages() {
    local staged_git staged_bash
    staged_git="$GIT_STAGE_ROOT$(git_prefix)"
    staged_bash="$BASH_STAGE_ROOT$(bash_prefix)"
    ! path_present "$(git_prefix)" || fail "Git prefix appeared before publication"
    ! path_present "$(bash_prefix)" || fail "Bash prefix appeared before publication"
    ! path_present "$(git_link)" || fail "Git link appeared before publication"

    mv -T -- "$staged_git" "$(git_prefix)"
    GIT_PUBLISHED=1
    mv -T -- "$staged_bash" "$(bash_prefix)"
    BASH_PUBLISHED=1
    ln -s -- "$(git_prefix)/bin/git" "$(git_link)"
    LINK_PUBLISHED=1
}

safe_remove_stage() {
    local path="$1" parent="$2" prefix="$3"
    [[ -n "$path" ]] || return 0
    if [[ "$path" == "$parent"/"$prefix".* && "$path" != "$parent" && -d "$path" && ! -L "$path" ]]; then
        rm -rf -- "$path"
    else
        printf 'WARNING: refused unsafe staging cleanup: %s\n' "$path" >&2
    fi
}

safe_remove_published() {
    local path="$1" expected="$2" marker
    marker="$path/.suxus-source-toolchain-owner"
    if [[ "$path" == "$expected" && -d "$path" && ! -L "$path" && -f "$marker" && ! -L "$marker" &&
        "$(< "$marker")" == "$RUN_MARKER" ]]; then
        rm -rf -- "$path"
    else
        printf 'WARNING: refused unsafe published-path cleanup: %s\n' "$path" >&2
    fi
}

cleanup() {
    if [[ "$RUN_SUCCEEDED" -ne 1 ]]; then
        if [[ "$LINK_PUBLISHED" -eq 1 && -L "$(git_link)" &&
            "$(readlink -- "$(git_link)")" == "$(git_prefix)/bin/git" ]]; then
            rm -- "$(git_link)"
        fi
        [[ "$BASH_PUBLISHED" -eq 0 ]] || safe_remove_published "$(bash_prefix)" "$(bash_prefix)"
        [[ "$GIT_PUBLISHED" -eq 0 ]] || safe_remove_published "$(git_prefix)" "$(git_prefix)"
    fi
    safe_remove_stage "$GIT_STAGE_ROOT" "$(dirname -- "$(git_prefix)")" ".${GIT_VERSION}.stage"
    safe_remove_stage "$BASH_STAGE_ROOT" "$(dirname -- "$(bash_prefix)")" ".${BASH_SOURCE_VERSION}.stage"
    if [[ -n "$BUILD_ROOT" ]]; then
        if [[ "$BUILD_ROOT" == /tmp/suxus-source-toolchain.* && -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]]; then
            rm -rf -- "$BUILD_ROOT"
        else
            printf 'WARNING: refused unsafe build cleanup: %s\n' "$BUILD_ROOT" >&2
        fi
    fi
}

verify_acquire_prerequisites() {
    local script output
    script="$(acquire_script)"
    [[ -f "$script" && -x "$script" && ! -L "$script" ]] || fail "acquire.sh is unavailable beside this script"
    output="$("$(bash_prefix)/bin/bash" "$script" prerequisites-detect)" ||
        fail "acquire.sh prerequisites-detect failed"
    grep -Fxq 'git=present' <<< "$output" || fail "acquire.sh did not detect Git"
    "$(bash_prefix)/bin/bash" "$script" prerequisites-plan >/dev/null ||
        fail "acquire.sh prerequisites-plan failed"
}

verify_complete_state() {
    local active_git
    verify_git_prefix || fail "final Git prefix verification failed"
    verify_bash_prefix || fail "final Bash prefix verification failed"
    verify_git_link || fail "final Git link verification failed"
    PATH="$(dirname -- "$(git_link)"):$(git_prefix)/bin:$PATH"
    export PATH
    hash -r
    active_git="$(command -v git)"
    [[ "$active_git" == "$(git_link)" ]] || fail "active Git is not $(git_link)"
    [[ "$(git --version)" == "git version $GIT_VERSION" ]] || fail "active Git version is unexpected"
    [[ "$(git --exec-path)" == "$(git_prefix)/libexec/git-core" ]] || fail "active Git exec-path is unexpected"
    verify_acquire_prerequisites
    verify_system_baseline
}

print_plan() {
    require_root
    require_preflight_commands
    validate_platform
    inspect_yum_git_versions
    inspect_installation_state
    if [[ "$INSTALLATION_STATE" == ready ]]; then
        printf 'source_build=not-needed-existing-installation-ready\n'
    elif [[ "$YUM_GIT_SUITABLE" -eq 1 ]]; then
        printf 'source_build=refused-use-distribution-git\n'
    else
        printf 'source_build=available-after-explicit-authorization\n'
    fi
}

install_toolchain() {
    [[ "$AUTHORIZED_SOURCE_BUILD" -eq 1 ]] || fail "install requires --authorize-source-build"
    require_root
    require_preflight_commands
    validate_platform
    inspect_yum_git_versions
    inspect_installation_state
    [[ "$YUM_GIT_SUITABLE" -eq 0 ]] || fail "yum offers Git $MINIMUM_GIT_VERSION or newer; source build refused"

    capture_system_baseline
    if [[ "$INSTALLATION_STATE" == fresh ]]; then
        install_build_prerequisites
        prepare_install_parents
        BUILD_ROOT="$(mktemp -d /tmp/suxus-source-toolchain.XXXXXX)"
        build_git_stage
        build_bash_stage
        publish_stages
    fi
    verify_complete_state
    RUN_SUCCEEDED=1
    printf 'SOURCE_TOOLCHAIN_READY\n'
}

parse_args() {
    case "${1:-}" in
        plan) MODE=plan; shift ;;
        install) MODE=install; shift ;;
        --help|-h) usage; exit 0 ;;
        --version) printf 'bootstrap-source-toolchain.sh %s\n' "$VERSION"; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    while (($#)); do
        case "$1" in
            --authorize-source-build)
                [[ "$AUTHORIZED_SOURCE_BUILD" -eq 0 ]] || fail "authorization flag was supplied more than once"
                AUTHORIZED_SOURCE_BUILD=1
                ;;
            *) fail "unknown argument: $1" ;;
        esac
        shift
    done
    [[ "$MODE" == install || "$AUTHORIZED_SOURCE_BUILD" -eq 0 ]] ||
        fail "authorization flag is valid only with install"
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$MODE" in
        plan) print_plan ;;
        install) install_toolchain ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
