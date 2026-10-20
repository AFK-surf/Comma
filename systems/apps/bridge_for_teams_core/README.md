# BridgeForTeamsCore

The business-logic backend (system of record) of the BridgeForTeams subsystem.

It owns the commercial domain in Postgres (`BridgeForTeams.Repo`): organizations,
Agent Swarms, users, memberships and roles, integrations, agent lifecycle records,
and auth and sessions (`BridgeForTeams.Auth.*`). The **Salix anti-corruption
layer** (`BridgeForTeams.Salix.*`) drives the Salix runtime over `:erpc`.
Project device runtime state is **not** stored here. Salix's connector-run
registry is the source of truth, and `BridgeForTeams.Environments` reads it live
over `:erpc`.

`BridgeForTeams.RateLimit` uses Redis. Global security limits fail closed when
Redis is unavailable. There is no ETS fallback.

**Agent Swarm** is the user-facing name for the internal `Project` model. Keep
internal names such as `projects`, `Project`, and `BridgeForTeams.Projects`
unless a separate internal rename explicitly requests it.

`BridgeForTeams.Release` is the migration entrypoint for releases.

See [the current BridgeForTeams architecture](../../../docs/bridge-for-teams/design.md).
