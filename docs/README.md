# Comma documentation

This directory holds current engineering contracts and the Chinese product manual.
[AGENTS.md](../AGENTS.md) sets the documentation scope and budget.
Update the relevant topic. Do not add a plan, review transcript, or completion report.

## Topic index

| Topic | Read for |
| --- | --- |
| [Architecture](architecture/README.md) | Concepts, owners, repository map |
| [Development](development.md) | Local setup and troubleshooting |
| [Clients](clients.md) | Native authority, auth, UI boundaries |
| [Identity and security](identity-security.md) | Users, tenants, admin, OAuth, signing keys |
| [Guest mode](architecture/DOMAIN_CONCEPTS.md#guest-mode) | Guest sign-in, handoff, chat import |
| [Conversations](salix/conversation-owner-actor.md) | Messages, participants, delivery, history |
| [Agent runtime](agent-runtime.md) | Session execution, compaction, workspace |
| [Tasks and background execution](salix/tasks-background-execution.md) | Task state, delegation, schedules, archive |
| [Tools and integrations](tools-integrations.md) | Tool authority, plugins, provider I/O |
| [Messaging and voice](messaging-voice.md) | Chat channels and voice calls |
| [Verification](verification.md) | Proof boundaries |
| [Storage and search](storage-search.md) | Durable facts, archives, search |
| [Compute and devices](compute-devices.md) | Device identity, routing, VMM ownership |
| [Meetings and calendar](meetings-calendar.md) | Calendar sources, preparation, delivery |
| [Bridge For Teams](bridge-for-teams/design.md) | Product boundary, Triage, runner ops |
| [Billing and models](billing-models.md) | Models, BYOK, subscriptions, charging |
| [Observability](observability.md) | Telemetry, archive, alert ownership |
| [Release operations](release-operations.md) | Rollout policy, approval, recovery, convergence |
| [Testing](testing.md) | Test placement, CI, manual evidence |
| [Product features](product-features.md) | Cross-client contracts and source map |
| [Chinese user manual](user_manual/bridge_for_teams/manual_zh.tex) | Dashboard procedures, PDF source |

## Maintenance

Find old decisions with `git log -- docs/`.
The last tree before the September 2026 consolidation is `842628fe89a384528d5b882dc58dfc2b9e36d856`.
Published migration sources, saved benchmark evidence, and the dated prompt snapshot cite paths in that tree.
Do not change migration checksums to repair those citations.
