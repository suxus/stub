# Security

Do not submit credentials, keys, tokens, host identifiers, inventory output, or
other environment data to this repository.

Treat every script and revision as untrusted until its exact commit has been
reviewed. Before running a write-capable script, also compare its SHA-256 with a
value obtained through a separate approved channel. Reports remain local unless
an operator deliberately shares them through an approved channel.

`acquire.sh checkout` makes one outbound SSH connection to `github.com` and
writes only the explicitly named keypair and checkout plus validated temporary
state. It must never be given credentials other than the repository-scoped key
it creates.

