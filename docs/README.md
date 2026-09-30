# Comma documentation

This directory contains current engineering contracts and the Chinese product manual.
General documentation has a recursive limit of 20 tracked files, each at most 20,000 UTF-8 bytes.
`architecture/` and `user_manual/` are excluded from both limits and preserved during general cleanup.
Generated previews, reports, screenshots, and PDFs are build artifacts, not additional documents.
Keep them outside the general documentation inventory. Architecture and user-manual artifact workflows remain unchanged.
Do not move general documents into either excluded directory to bypass the budget.
Update the relevant topic instead of adding a plan, review transcript, or completion report.

## Topic index

| Topic                                                             | Read for                                                              |
| ----------------------------------------------------------------- | --------------------------------------------------------------------- |
| [Architecture](architecture/README.md)                            | Product concepts, owners, repository map                              |
| [Development](development.md)                                     | Local setup, native development, troubleshooting                      |
| [Clients](clients.md)                                             | Native authority, authentication lifecycle, browser and UI boundaries |
| [Identity and security](identity-security.md)                     | User, tenant, admin, OAuth, signing-key operations                    |
| [Conversations](salix/conversation-owner-actor.md)                | Canonical messages, participants, delivery, history                   |
| [Agent runtime](agent-runtime.md)                                 | Session execution, dependency liveness, compaction                    |
| [Tasks and background execution](salix/tasks-background-execution.md)             | Task state, delegation, schedules, archive                        |
| [Tools and integrations](tools-integrations.md)                   | Tool authority, plugins, provider ingress and egress                  |
| [Messaging and voice](messaging-voice.md)                         | iMessage, WeChat, Telegram, Signal, voice calls and the voice WebSocket API |
| [Verification](verification.md)                                   | Session, AgentLoop, IFC, TLA+, and proof boundaries                   |
| [Storage and search](storage-search.md)                           | Durable facts, segmented archives, bounded search projections         |
| [Compute and devices](compute-devices.md)                         | Device identity, connector routing, VMM ownership                     |
| [Meetings and calendar](meetings-calendar.md)                     | Calendar sources, preparation, personal delivery                      |
| [Bridge For Teams](bridge-for-teams/design.md)                    | Product boundary, Triage, runner and integration operations           |
| [Billing and models](billing-models.md)                           | Tenant templates, BYOK, subscription accounts, charging               |
| [Observability](observability.md)                                 | Telemetry, encrypted archive, alert ownership                         |
| [Release operations](release-operations.md)                       | Rollout availability policy, human shutdown approval, recovery, convergence             |
| [Testing](testing.md)                                             | Commands, test placement, CI and manual evidence                      |
| [Product features](product-features.md)                           | Cross-client interaction contracts and source map                     |
| [Chinese user manual](user_manual/bridge_for_teams/manual_zh.tex) | Dashboard user procedures and PDF source                              |

## Maintenance

Current implementation and its regression tests establish whether a feature exists.
A design proposal, passing abstraction, or historical staging check does not prove deployed behavior.
Verify the live revision before claiming an environment has a feature or fix.

The September 2026 consolidation removes dated plans, duplicate RFCs, review diaries,
and hand-test logs outside the excluded directories. It does not revoke product guarantees.
Use `git log -- docs/` and `git show <commit>:docs/<old-path>` for historical decisions.
The last pre-consolidation tree is `842628fe89a384528d5b882dc58dfc2b9e36d856`.
Do not treat old model links or one-time rollout evidence as current verification.

Repository-scoped instructions remain in [AGENTS.md](../AGENTS.md).
The retained formal-model roster remains in [tla/README.md](../tla/README.md).
Package-local READMEs describe their package commands, not a second archive of these documents.

Historical citations inside published migration sources, saved benchmark evidence, and the dated generated prompt snapshot retain their original paths.
Do not change migration checksums to repair those citations. Resolve them through the pre-consolidation Git tree above.
