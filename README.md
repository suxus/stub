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

