# BridgeForTeamsCore

The business-logic backend (system of record) of the BridgeForTeams subsystem.

Owns the commercial domain in Postgres (via Ecto): organizations, Agent Swarms,
users, memberships/roles, integrations, agent lifecycle records, auth/sessions,
and the **Salix anti-corruption layer** (`BridgeForTeams.Salix.*`) that drives
the Salix runtime over `:erpc`. Project device runtime state is **not**
persisted here: Salix's connector-run registry is the source of truth and
`BridgeForTeams.Environments` reads it live over `:erpc` (no runtime-state
Postgres mirror).

Terminology note: **Agent Swarm** is the user-facing name for the internal
`Project` model. Keep internal tables, schemas, contexts, routes, and function
names such as `projects`, `Project`, and `BridgeForTeams.Projects` unchanged
unless a separate internal rename/migration explicitly requests it.

See [the current BridgeForTeams architecture](../../../docs/bridge-for-teams/design.md).

## Layout

- `BridgeForTeams.Repo` — Ecto repo (Postgres).
- `BridgeForTeams.Schema.*` — Ecto schemas (design §5).
- Contexts: `BridgeForTeams.{Orgs,Accounts,Projects,Memberships,Integrations,Agents,Environments}`.
- `BridgeForTeams.Cache` — node-local rebuildable ETS.
- `BridgeForTeams.RateLimit` — supervised Redis-backed Hammer limiter; global
  security limits fail closed without an ETS fallback.
- `BridgeForTeams.Salix.{Client,Erpc,Nodes,Reconciler}` — erpc ACL.
- `BridgeForTeams.Auth.*` — OIDC SSO + sessions.
- `BridgeForTeams.Release` — migration entrypoint for releases.
