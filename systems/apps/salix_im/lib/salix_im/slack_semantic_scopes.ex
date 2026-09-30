defmodule SalixIM.SlackSemanticScopes do
  @moduledoc """
  Background discovery over Slack installations and owner-observed channels.
  Each step reads one bounded page; no channel allowlist or global scope cache.
  Returned state contains references only, never installation credentials.
  Modeled in tla/salix/SemanticScopeDiscovery.tla.
  Discovery does not authorize reads: file acquisition checks its current
  credential owner; message search checks current group/connect ownership and
  retained channel provenance without per-query Slack membership calls.
  """
  alias SalixIM.ProviderConnects
  alias SalixStore.SlackSearchCatalog
  @page_size 20

  def next(nil),
    do: next(%{connects: [], connect_cursor: nil, connect: nil, channels: [], channel_cursor: ""})

  def next(%{channels: [scope | remaining]} = state),
    do: {:ok, scope, %{state | channels: remaining}}

  def next(%{connect: connect} = state) when is_map(connect) do
    with {:ok, channels} <-
           SlackSearchCatalog.channel_page(connect, state.channel_cursor, @page_size) do
      scopes = Enum.map(channels, &Map.merge(&1, Map.take(connect, ~w(group_id connect_id))))
      last = List.last(channels)

      next_state = %{
        state
        | channels: scopes,
          channel_cursor: if(last, do: last["channel_id"], else: ""),
          connect: if(length(channels) < @page_size, do: nil, else: connect)
      }

      take_channel(next_state)
    end
  end

  def next(%{connects: [connect | remaining]} = state),
    do: next(%{state | connect: connect, connects: remaining, channel_cursor: ""})

  def next(state) do
    with {:ok, page} <-
           ProviderConnects.list_slack_search_connects(@page_size, state.connect_cursor) do
      connects =
        Enum.map(
          Enum.filter(page.candidates, & &1["active"]),
          &Map.take(&1, ~w(tenant_id workspace_id group_id connect_id connect_generation))
        )

      _ = SlackSearchCatalog.remember_connects(page.candidates)

      next_state = %{state | connects: connects, connect_cursor: page.next_cursor}
      # An empty/short page is still a cursor step. Never recurse through the
      # installation corpus in one tick, even when every record is inactive.
      {:ok, nil, next_state}
    end
  end

  defp take_channel(%{channels: [scope | remaining]} = state),
    do: {:ok, scope, %{state | channels: remaining}}

  defp take_channel(state), do: {:ok, nil, state}
end
