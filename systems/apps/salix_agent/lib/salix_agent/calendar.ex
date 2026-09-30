defmodule SalixAgent.Calendar do
  @moduledoc "Group-scoped runtime seam for agent Calendar tools."

  alias SalixAgent.GroupRuntime

  @callback list_items(String.t(), map(), map() | nil) :: {:ok, map()} | {:error, term()}
  @callback get_item(String.t(), map(), map() | nil) :: {:ok, map()} | {:error, term()}
  @callback update_context(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback create_event(String.t(), map(), map() | nil, String.t() | nil) ::
              {:ok, map()} | {:error, term()}
  @callback issue_feed_link(String.t(), map() | nil) :: {:ok, map()} | {:error, term()}

  def list_items(agent_id, params, principal_ref \\ nil),
    do:
      GroupRuntime.call(agent_id, :calendar_mod, :calendar_not_configured, :list_items, [
        params,
        principal_ref
      ])

  def get_item(agent_id, params, principal_ref \\ nil),
    do:
      GroupRuntime.call(agent_id, :calendar_mod, :calendar_not_configured, :get_item, [
        params,
        principal_ref
      ])

  def create_event(agent_id, params, principal_ref, creation_request_id) do
    GroupRuntime.call(agent_id, :calendar_mod, :calendar_not_configured, :create_event, [
      params,
      principal_ref,
      creation_request_id
    ])
  end

  def issue_feed_link(agent_id, principal_ref),
    do:
      GroupRuntime.call(agent_id, :calendar_mod, :calendar_not_configured, :issue_feed_link, [
        principal_ref
      ])

  def update_context(agent_id, params) do
    call(
      agent_id,
      :update_context,
      Map.put(params, "actor", %{"actor_type" => "agent", "agent_id" => agent_id})
    )
  end

  defp call(agent_id, command, params),
    do: GroupRuntime.call(agent_id, :calendar_mod, :calendar_not_configured, command, [params])
end
