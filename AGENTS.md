# Repository instructions

This public repository contains only small, generic system-inspection and
source-acquisition stubs.

- Never add organization-specific infrastructure information.
- Never add hostnames, addresses, ports, account names, fingerprints,
  credentials, keys, tokens, customer data, or generated inventory reports.
- Never add access-enablement, deployment, persistence, privilege-escalation,
  service-control, firewall, DNS, package-installation, or destructive logic.
- Inventory scripts must not initiate network connections or write runtime
  state.
- `acquire.sh` is the only network/write exception. It may create one explicit
  ED25519 keypair and one exact-revision GitHub checkout after a separate
  authorization flag. It must contact only `github.com`, pin the official host
  key, never upload output, never overwrite state, and remove only its own
  validated temporary paths.
- Prefer standard platform tools, deterministic output, and graceful handling
  of missing commands.
- Keep runtime output outside Git.
- Validate shell syntax and behavior before proposing a change.
- Use a branch and pull request for functional changes. Do not merge without
  explicit permission.
