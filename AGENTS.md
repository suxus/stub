# Repository instructions

This public repository contains only small, generic, read-only system inventory
stubs.

- Never add organization-specific infrastructure information.
- Never add hostnames, addresses, ports, account names, fingerprints,
  credentials, keys, tokens, customer data, or generated inventory reports.
- Never add access-enablement, deployment, persistence, privilege-escalation,
  service-control, firewall, DNS, package-installation, or destructive logic.
- Scripts must not initiate network connections or upload output.
- Prefer standard platform tools, deterministic output, and graceful handling
  of missing commands.
- Keep runtime output outside Git.
- Validate shell syntax and behavior before proposing a change.
- Use a branch and pull request for functional changes. Do not merge without
  explicit permission.

