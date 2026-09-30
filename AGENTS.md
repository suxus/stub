# Repository instructions

This public repository contains only small, generic system-inspection and
source-acquisition stubs.

- Never add organization-specific infrastructure information.
- Never add hostnames, addresses, ports, account names, fingerprints,
  credentials, keys, tokens, customer data, or generated inventory reports.
- Never add access-enablement, deployment, persistence, privilege-escalation,
  service-control, firewall, DNS, or destructive logic. Package installation is
  permitted only in `acquire.sh`'s explicit prerequisite-install mode and in
  `bootstrap-source-toolchain.sh`'s narrowly scoped CentOS 7 source-build mode,
  only for missing documented prerequisites, and only after each script's
  dedicated authorization flag.
- Inventory scripts must not initiate network connections or write runtime
  state.
- `acquire.sh` is a network/write exception. It may create one explicit
  ED25519 keypair and one exact-revision GitHub checkout after a separate
  authorization flag. It may install only its documented prerequisites from the
  detected distribution repositories after separate authorization. It must
  otherwise contact only `github.com`, pin the official host key, prove the
  repository key effectively read-only using only a dry-run push, never create
  a remote ref, never upload output, never overwrite state, and remove only its
  own validated temporary paths.
- `bootstrap-source-toolchain.sh` is the only additional network/write
  exception. It may validate only CentOS 7 with systemd, query configured yum
  repositories, install only its documented source-build prerequisites from
  those repositories, download the exact pinned official Git 2.43.7 and Bash
  5.2.37 archives, verify their SHA-256 checksums, and install them alongside
  the system versions under versioned `/opt/suxus` paths after separate
  authorization. It must preserve RPM packages and system binaries, refuse a
  source build when yum offers suitable Git, never overwrite unexpected state,
  and remove only its own validated temporary or newly published paths.
- Prefer standard platform tools, deterministic output, and graceful handling
  of missing commands.
- Keep runtime output outside Git.
- Validate shell syntax and behavior before proposing a change.
- Use a branch and pull request for functional changes. Do not merge without
  explicit permission.
