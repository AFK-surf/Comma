defmodule SalixAgent.GuestPolicy do
  @moduledoc """
  Fail-closed tool allowlist for guest Routers.

  A guest Router answers in its own Router chat with server-side tools only. It
  cannot create or address Worker agents, start a Cloud VM, reach devices,
  install plugins or MCP servers, or connect external accounts. New tools stay
  unavailable to guests until this list names them.

  `SalixAgent.AgentControl` admits the guest purpose only in a router-only
  Tenant and keeps it immutable, so the purpose selects this policy.
  """

  @allowed ~w(
    help
    tool_call.get_result
    tool_call.get_status
    tool_call.cancel
    fs.read_file
    fs.write_file
    fs.edit_file
    fs.list_files
    fs.stat_file
    fs.glob
    fs.grep
    fs.copy_file
    fs.move_file
    fs.delete_file
    web.search
    web.read_pages
    history.get
    history.list
    history.search
    memory.get
    memory.search
    memory.write
    question.request
    ui.create
    im_api.internal.send_message
    im_api.internal.read_conversation
    im_api.internal.search_conversations
  )

  def guest_purpose?(purpose), do: purpose == SalixStore.TenantProfiles.guest_router_purpose()

  def policy_for_purpose(purpose),
    do: if(guest_purpose?(purpose), do: :restricted, else: :ordinary)

  def allowed_tool?(ctx, name) do
    case policy(ctx) do
      :restricted -> to_string(name || "") in @allowed
      :ordinary -> true
      :unresolved -> false
    end
  end

  def allowed_disclosure?(ctx, candidate) when is_map(candidate),
    do: allowed_tool?(ctx, candidate["name"])

  defp policy(ctx) when is_map(ctx) do
    explicit = value(ctx, :guest_policy)
    disclosed = nested_value(ctx, :tool_disclosure, :guest_policy)

    case explicit || disclosed do
      value when value in [:restricted, "restricted"] -> :restricted
      value when value in [:ordinary, "ordinary"] -> :ordinary
      nil -> :ordinary
      _ -> :unresolved
    end
  end

  defp policy(_ctx), do: :ordinary

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp nested_value(map, parent_key, child_key) do
    case value(map, parent_key) do
      nested when is_map(nested) -> value(nested, child_key)
      _ -> nil
    end
  end
end
