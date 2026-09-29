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

`acquire.sh` has one deliberately narrow purpose: prepare one repository-scoped
ED25519 keypair and use it to fetch one GitHub repository at one exact commit.
It has no organization, repository, account, host, port, path, or revision
defaults.

The two operations are separate. First prepare the key and register only the
reported public key as a read-only deploy key on the exact repository:

```sh
sudo ./acquire.sh prepare --authorize-acquire \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH
```

After that manual registration, acquire the reviewed revision:

```sh
sudo ./acquire.sh checkout --authorize-acquire \
  --repository OWNER/REPOSITORY \
  --key-path /ABSOLUTE/PRIVATE/KEY/PATH \
  --destination /ABSOLUTE/CHECKOUT/PATH \
  --revision 0123456789abcdef0123456789abcdef01234567
```

`prepare` performs no network operation. `checkout` connects only to
`github.com` over SSH, with the official ED25519 host key pinned, and refuses
an existing checkout unless its remote, revision, and clean state already match
exactly. Neither operation replaces a key or checkout.

Always detach at a separately reviewed repository commit before inspecting or
executing `acquire.sh`. Verify the script's SHA-256 against a value obtained
through a separate approved channel; a checksum stored only beside the script
does not provide independent protection.
