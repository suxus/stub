# Security

Do not submit credentials, keys, tokens, host identifiers, inventory output, or
other environment data to this repository.

Treat every script and revision as untrusted until its exact commit has been
reviewed. Before running a write-capable script, also compare its SHA-256 with a
value obtained through a separate approved channel. Reports remain local unless
an operator deliberately shares them through an approved channel.

`inventory.sh` remains strictly read-only: it performs no package management,
network access, or runtime writes.

`acquire.sh` is the sole network/write exception. `checkout` and `verify`
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

`adopt-origin` contacts GitHub through the exact supplied SSH config and changes
only local checkout configuration after separate authorization and exact-state
validation. No mode may be given a GitHub token, broad management credential, or
write-capable repository key.
