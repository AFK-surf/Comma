defmodule BridgeForTeams.ProjectSignal do
  @moduledoc """
  A project's Signal chats (docs/messaging-voice.md): the people and Signal
  groups bound to the project's Salix group, and one-time connection codes.

  Salix owns the bindings and codes (`Salix.Control.Signal`). BridgeForTeams
  owns project authorization and forwards over erpc. A new code appears only
  in the `start_claim/3` result. The client callbacks are optional: a client
  without them yields `{:error, :unsupported}`.
  """

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  @doc "The project's Signal status: `account`, `bindings` and `pending_claims`."
  @spec status(Organization.t(), Project.t()) :: {:ok, map()} | {:error, term()}
  def status(%Organization{} = org, %Project{} = project),
    do: Client.call_optional(:get_group_signal, [project.salix_group_id, org.salix_tenant_id])

  @doc "Creates a one-time connection code; the result carries it in `claim`."
  @spec start_claim(Organization.t(), Project.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def start_claim(%Organization{} = org, %Project{} = project, user_id),
    do:
      Client.call_optional(:start_group_signal_claim, [
        project.salix_group_id,
        org.salix_tenant_id,
        "bft_user:" <> to_string(user_id)
      ])

  @doc "Disconnects one Signal chat from the project."
  @spec remove_binding(Organization.t(), Project.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_binding(%Organization{} = org, %Project{} = project, binding_id),
    do:
      Client.call_optional(:remove_group_signal_binding, [
        project.salix_group_id,
        org.salix_tenant_id,
        binding_id
      ])
end
