defmodule SalixIM.IFC.AudiencePlacement do
  @moduledoc """
  Bounded Slack placement observations for the readers of an internal Task.

  These observations supplement, but never replace, operator placement facts.
  Unknown or failed lookups do not grant access. Cache entries expire after
  one minute and are scoped to the current installation.
  """

  alias SalixIM.IFC.Projection
  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects

  @table :salix_ifc_audience_placement
  @slots 4096
  @ttl_ms 60_000
  @user_limit 20

  @doc false
  def create_table! do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @doc "Resolve at most 20 named users. Unresolved users remain absent."
  def resolve(scope, user_ids) do
    with [_ | _] <- user_ids,
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(scope.group_id, scope.connect_id, "slack"),
         true <- connect["tenant_id"] == scope.tenant_id,
         generation when is_binary(generation) and generation != "" <-
           connect["connect_generation"] do
      user_ids
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@user_limit)
      |> Enum.reduce(%{}, fn user_id, acc ->
        case lookup(scope, connect, generation, user_id) do
          placement when placement in [:internal, :external] ->
            Map.put(acc, user_id, Atom.to_string(placement))

          :unknown ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp lookup(scope, connect, generation, user_id) do
    key =
      {scope.tenant_id, scope.group_id, scope.connect_id, generation, connect["workspace_id"],
       user_id}

    slot = :erlang.phash2(key, @slots)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, slot) do
      [{^slot, ^key, expires_at, placement}] when expires_at > now ->
        placement

      _ ->
        placement = fetch(connect, user_id)
        # Fixed slots bound memory. A collision evicts a cache entry, not its
        # identity check. Concurrent misses may each perform a provider read.
        :ets.insert(@table, {slot, key, now + @ttl_ms, placement})
        placement
    end
  end

  defp fetch(connect, user_id) do
    user = connect |> API.installation() |> API.user_info(user_id)

    if user["id"] == user_id and user["deleted"] != true,
      do: Projection.provider_placement(user),
      else: :unknown
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end
end
