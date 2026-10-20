defmodule BridgeForTeams.ProjectTailnet do
  @moduledoc """
  A project's Tailscale network: the node of the project's Salix group in
  the organization's own tailnet.

  Salix owns the settings and the node (`Salix.Control.Tailnet`).
  BridgeForTeams owns project authorization and forwards over erpc. The
  login link appears only in the status of a node that waits for approval.
  The client callbacks are optional: a client without them yields
  `{:error, :unsupported}`.
  """

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  @doc "The project's tailnet settings and node status."
  @spec status(Organization.t(), Project.t()) :: {:ok, map()} | {:error, term()}
  def status(%Organization{} = org, %Project{} = project),
    do: Client.call_optional(:get_group_tailnet, [project.salix_group_id, org.salix_tenant_id])

  @doc "Enables or changes the project's tailnet (`tags`, `accept_routes`, `expected_tailnet`)."
  @spec connect(Organization.t(), Project.t(), map(), term()) :: {:ok, map()} | {:error, term()}
  def connect(%Organization{} = org, %Project{} = project, attrs, user_id) when is_map(attrs),
    do:
      Client.call_optional(:connect_group_tailnet, [
        project.salix_group_id,
        org.salix_tenant_id,
        Map.take(attrs, ~w(tags accept_routes expected_tailnet)),
        "bft_user:" <> to_string(user_id)
      ])

  @doc "Disconnects the project from its tailnet."
  @spec disconnect(Organization.t(), Project.t(), term()) :: {:ok, map()} | {:error, term()}
  def disconnect(%Organization{} = org, %Project{} = project, user_id),
    do:
      Client.call_optional(:disconnect_group_tailnet, [
        project.salix_group_id,
        org.salix_tenant_id,
        "bft_user:" <> to_string(user_id)
      ])
end
