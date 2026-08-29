# Security policy

Eggshell is pre-release software. Security fixes are made on the current
`main` branch and included in the next release; older development snapshots are
not maintained as separate supported lines.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. Please do not
open a public issue for a suspected vulnerability or include private prompts,
tool output, `.egg` contents, credentials, or repository data in a report that
others can see.

Include the affected commit or release, operating system, Codex version, the
smallest safe reproduction, and the expected authority boundary. Redact secrets
and proprietary content. You should receive an acknowledgement within seven
days.

## Security boundary

Eggshell observes Codex hook events, starts a loopback-only daemon, and writes
only to the authority selected by the user. Semantic retrieval is advisory;
similarity alone cannot create persistent equality or complete work. See
[PRIVACY.md](PRIVACY.md) for data locations, network behavior, and removal.

Auto-discovered project configuration cannot name an executable semantic
matcher. Custom provider commands are accepted only from the user-owned global
configuration file.

Project configuration may declare only authority files below its own root and
may reference only its own declarations. Eggshell rejects symbolic links and
non-regular authority files, decodes an existing `.egg` before hardening its
permissions, and creates a missing authority only during an explicit write.
