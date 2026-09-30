# Security

Do not submit credentials, keys, tokens, host identifiers, inventory output, or
other environment data to this repository.

Treat every script and revision as untrusted until its exact commit has been
reviewed. Before running a write-capable script, also compare its SHA-256 with a
value obtained through a separate approved channel. Reports remain local unless
an operator deliberately shares them through an approved channel.

`inventory.sh` remains strictly read-only: it performs no package management,
network access, or runtime writes.

`acquire.sh` is a network/write exception. `checkout` and `verify`
connect to `github.com` over SSH using only the exact repository-scoped key and
the pinned official ED25519 host key. They fetch the exact requested revision
and use only a dry-run push to prove the key is effectively read-only. They must
never create a remote ref. An explicit GitHub `read_only: true` UI/API result is
the authoritative configuration control; the rejected capability probe is the
technical failsafe.

`prerequisites-install` contacts only the configured distribution package
repositories and is unavailable without its dedicated authorization flag. It
may install only missing `git`, OpenSSH client, and CA-certificate packages.
Package caches, CA trust, package-owned files, and package-hook state may change;
no complete rollback is claimed.

`bootstrap-source-toolchain.sh` is the only other network/write exception. It
is restricted to a CentOS 7 systemd classification, configured yum repository
queries, missing documented build packages from those repositories, and the
two pinned official Git 2.43.7 and Bash 5.2.37 HTTPS archives. Both archives
must match the SHA-256 values embedded in the reviewed script. Those embedded
values prevent unexpected download content but are not an independent trust
channel; operators must compare the script checksum with a separately reviewed
value before privileged execution.

The source toolchain is published only under versioned `/opt/suxus` prefixes.
It preserves the Git and Bash RPM identities and `/bin/bash`, refuses suitable
yum Git and unexpected or partial install state, and does not add package
repositories. Package installation and hooks have no general rollback
guarantee. Staged or newly published source paths are removed after failure
only when exact path and run-ownership checks succeed.

`adopt-origin` contacts GitHub through the exact supplied SSH config and changes
only local checkout configuration after separate authorization and exact-state
validation. No mode may be given a GitHub token, broad management credential, or
write-capable repository key.
