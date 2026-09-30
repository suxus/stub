# stub

Minimal, generic system-inspection stubs.

This repository contains no environment-specific configuration, credentials,
host inventory, access tooling, or deployment logic. Inspect an exact commit
before running any file, especially with elevated read privileges.

## Inventory

`inventory.sh` prints a deliberately small compatibility report to standard
output. It reports only operating-system family/version, architecture, init
style, privilege class, selected local command availability, and whether the
local SSH daemon configuration can be validated. It does not report hostnames,
addresses, ports, user names, keys, fingerprints, repositories, or network
state. It neither writes files nor initiates network connections.

Clone over HTTPS, detach at an exact reviewed commit, inspect the script, and
then run it locally:

```sh
git clone https://github.com/suxus/stub.git
cd stub
git checkout --detach <reviewed-commit-sha>
sed -n '1,240p' inventory.sh
sudo ./inventory.sh
```

Keep the output local unless it has been reviewed and an approved channel has
been selected deliberately.

## CentOS 7 source toolchain bootstrap

`bootstrap-source-toolchain.sh` is a deliberately narrow bridge for a legacy
CentOS 7 systemd host whose configured yum repositories do not offer the
reviewed Git baseline. It never checks or reports a host name, address, port,
account, key, fingerprint, or environment identity.

The minimum acceptable distribution Git is 2.43.7. This is the pinned and
reviewed acquisition baseline, including the environment-based Git config and
`protocol.*.allow` controls used by `acquire.sh`. If the configured yum
repositories offer Git 2.43.7 or newer, the source-build route is refused and
the distribution package route must be used instead.

Run the non-installing plan first from an exact reviewed Stub commit:

```sh
sudo ./bootstrap-source-toolchain.sh plan
```

The plan validates the exact `inventory.sh` classification
`os_id=centos`, `os_version=7`, and `init_style=systemd`; queries all Git
versions offered by the configured yum repositories; and classifies the local
parallel-install state. It performs no package transaction and does not build
or publish software. Yum may read or refresh its normal repository metadata
cache while answering the query. Repository errors, missing candidates, and
ambiguous version output fail closed.

Only after reviewing that plan, authorize the source route explicitly:

```sh
sudo ./bootstrap-source-toolchain.sh install --authorize-source-build
```

The source route installs only missing build prerequisites from the configured
distribution repositories. The fixed CentOS 7 build-package set is `gcc`,
`make`, `libcurl-devel`, `expat-devel`, `openssl-devel`, `perl-ExtUtils-MakeMaker`,
`zlib-devel`, and `ncurses-devel`. The `curl`, `tar`, and `sha256sum`
commands are checked independently and map to the CentOS 7 `curl`, `tar`, and
`coreutils` packages only when missing. No external RPM repository is added.

The only source inputs are:

- Git 2.43.7 from
  `https://www.kernel.org/pub/software/scm/git/git-2.43.7.tar.gz`, SHA-256
  `b30055b0dac1aebcb6f332f1fddbc81e3ce43819920a23709d71b4f76763f1f4`;
- Bash 5.2.37 from `https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz`, SHA-256
  `9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff`.

Both archives must pass checksum and archive-path validation. Installation is
staged before publication. Git is installed at `/opt/suxus/git/2.43.7` and the
exact `/usr/local/bin/git` symlink activates it. Bash is installed alongside the
system shell at `/opt/suxus/bash/5.2.37`; `/bin/bash` is never replaced or
linked. Existing Git and Bash RPM identities and the `/bin/bash` file are
captured before mutation and verified unchanged afterward.

An exact existing parallel installation is verified and accepted idempotently.
Partial prefixes, a wrong link, checksum drift, package or repository errors,
build failures, and failed final verification stop safely. Success is reported
only as `SOURCE_TOOLCHAIN_READY` after Git version and exec-path checks, Bash
version and empty-array checks, Git security-control checks, RPM/system-shell
preservation checks, and successful `acquire.sh prerequisites-detect` and
`prerequisites-plan` runs under the parallel Bash.

Inspect the complete script and independently compare its SHA-256 before any
privileged execution. Do not use `curl | bash`. Package-manager transactions do
not have a general rollback guarantee; the script can clean up only the source
outputs and staging paths that it can prove it created itself.

The [legacy source-toolchain runbook](docs/legacy-source-toolchain-runbook.md)
provides the complete generic operator sequence for obtaining an exact reviewed
Stub revision, independently verifying this script, reviewing a plan, and
keeping installation behind a separate explicit authorization.

## Acquire

`acquire.sh` prepares one repository-scoped ED25519 keypair and uses it to fetch
one GitHub repository at one exact commit. It also detects, plans, and—only with
separate authorization—installs the small prerequisite set needed to do that.
It has no organization, repository, account, host, port, path, or revision
defaults.

### Prerequisites

Detection and planning are strictly read-only. They do not refresh package
caches, contact repositories, or change files:

```sh
./acquire.sh prerequisites-detect
./acquire.sh prerequisites-plan
```

The required capabilities are `git`, `ssh`, `ssh-keygen`, and usable CA trust.
Supported managers and packages are:

- `dnf` or `yum`: `git`, `openssh-clients`, `ca-certificates`;
- `apt-get`: `git`, `openssh-client`, `ca-certificates`.

Review the exact printed plan before authorizing installation:

```sh
sudo ./acquire.sh prerequisites-install --authorize-prerequisite-install
```

Only missing packages are requested. No distribution upgrade, general package
upgrade, or autoremove is performed. Installation contacts the configured
distribution repositories and may change package caches, CA trust, files owned
by the listed packages, and state changed by package hooks. Unknown or ambiguous
operating systems/package managers, missing privileges, repository/package
errors, and failed post-install verification stop the operation.

If Git is absent before this repository can be cloned, obtain the exact reviewed
`acquire.sh` through an approved console, management platform, or previously
delivered artifact. Independently verify its SHA-256 before execution. Never use
`curl | bash`; this repository intentionally contains no management endpoint.

The two operations are separate. First prepare the key and register only the
reported public key as a read-only deploy key on the exact repository:

```sh
sudo ./acquire.sh prepare --authorize-acquire \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH
```

Before registration, inspect the repository's existing deploy-key title
convention. A generic title is `HOST - OWNER/REPOSITORY - read-only acquire`.
Keep **Allow write access** disabled. The GitHub UI or API value
`read_only: true` is the authoritative configuration check. A public-key comment
may be omitted or changed without changing the cryptographic key identity.
Deploy keys are immutable, so an existing key is never silently rotated or
replaced.

After manual registration, acquire the reviewed revision:

```sh
sudo ./acquire.sh checkout --authorize-acquire \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
  --destination /ABSOLUTE/CHECKOUT/PATH \
  --revision 0123456789abcdef0123456789abcdef01234567
```

`prepare` performs no network operation. `checkout` connects only to
`github.com` over SSH, with the official ED25519 host key pinned. It fetches and
checks the exact revision in temporary state, confirms a unique probe ref is
absent, and performs only `git push --dry-run`. The checkout is published only
when GitHub returns its exact explicit read-only-deploy-key rejection and the
probe ref is still absent. A successful dry-run push is a security failure;
network, authentication, or changed/ambiguous responses fail closed. GitHub may
record the rejected dry-run attempt in audit data.

Recheck an existing exact key and checkout without rotation, replacement, or
remote ref mutation:

```sh
sudo ./acquire.sh verify --authorize-acquire \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
  --destination /ABSOLUTE/CHECKOUT/PATH \
  --revision 0123456789abcdef0123456789abcdef01234567
```

### Explicit bootstrap adoption

The initial checkout uses `git@github.com:OWNER/REPOSITORY.git`. A later host
bootstrap may require the generic alias format
`git@github-owner-repository:OWNER/REPOSITORY.git`. Origins are never changed
silently. After the bootstrap SSH config exists, adoption requires its own
authorization, exact old/new origins, a clean pinned checkout, and successful
read-only reachability through that exact config:

```sh
sudo ./acquire.sh adopt-origin --authorize-origin-adoption \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
  --destination /ABSOLUTE/CHECKOUT/PATH \
  --revision 0123456789abcdef0123456789abcdef01234567 \
  --expected-old-origin git@github.com:OWNER/REPOSITORY.git \
  --new-origin git@github-owner-repository:OWNER/REPOSITORY.git \
  --ssh-config /ABSOLUTE/SSH/CONFIG
```

The adoption mode changes only the checkout's `origin` and local
`core.sshCommand`. It does not create keys or remote refs. Do not run a later
seed/apply phase until this contract has been validated for its exact pinned
bootstrap revision.

Always detach at a separately reviewed repository commit before inspecting or
executing `acquire.sh`. Verify the script's SHA-256 against a value obtained
through a separate approved channel; a checksum stored only beside the script
does not provide independent protection.

Package-manager rollback is not claimed: package transactions and hooks may not
be fully reversible. Failed acquisition removes only validated temporary paths;
it never replaces an existing key or checkout. Origin adoption restores the
prior local origin and Git SSH command when its local configuration or
post-change verification fails, but it is not a general rollback mechanism.
