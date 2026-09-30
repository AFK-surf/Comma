# BridgeForTeamsWeb

The BridgeForTeams Phoenix LiveView dashboard (design §3). It coexists with
`salix_web` on a distinct port (4101 vs salix_web's 4000).

Surfaces: organization login/SSO, org/project/user admin, integration setup, agent & env
management, and conversation read/debug views. Every Salix-facing action is
authorized in `bridge_for_teams_core` before any erpc (design §7).

See [the current BridgeForTeams architecture](../../../docs/bridge-for-teams/design.md).
