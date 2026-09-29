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
