defmodule Comma.Stations.Window do
  @moduledoc """
  The rollout window of the release that moves the station roster to Salix
  (`Comma.Stations.SalixCopy`, "The three phases"): servers of the release
  before still run. They write Comma's three station tables and publish
  station changes on Comma's PubSub under Workspace ids; this release's
  servers write Salix's tables and publish on Salix's PubSub under Group ids.

  While the window is open, a server of this release

    * merges what Comma's tables hold into Salix before it reads it
      (`station/1`, `group/2`, `workspace/1`): a station enrolled, taken
      back, moved or removed, a revocation written and a signing key made
      through a server of the release before are in Salix by the time the
      answer is read. It never writes Comma's tables;
    * hears what those servers publish (`listen_station/1`,
      `listen_group/2`), and tells them what it must not keep to itself: a
      removal, a revocation, a newer socket (`tell_*`).

  Once `SalixCopy.finish/1` has marked the move complete, every function
  here answers at once from one cached read of the marker and touches
  neither Comma's tables nor Comma's PubSub.

  This module is for one release. The release after it removes it.
  """

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Repo
  alias Comma.Stations.SalixCopy
  alias SalixStore.Repo, as: SalixRepo
  alias SalixStore.Stations.Station, as: SalixStation

  @complete {__MODULE__, :complete}

  @doc """
  Whether servers of the release before may still run. A marker that cannot
  be read counts as open: reading Comma's tables once more is safe, missing a
  removal is not.
  """
  @spec open?() :: boolean()
  def open? do
    if SystemsRuntime.PersistentTerm.get(@complete, false) do
      false
    else
      case SalixCopy.phase() do
        {:ok, :complete} ->
          # Complete stays complete while this server runs: read once.
          SystemsRuntime.PersistentTerm.put(@complete, true)
          false

        _ ->
          true
      end
    end
  end

  @doc false
  # A test that opens the window again in the same VM.
  def forget, do: SystemsRuntime.PersistentTerm.put(@complete, false)

  # ── reading ─────────────────────────────────────────────────────────────

  @doc """
  Before a station is looked up by its id: its Comma row is merged, then its
  Group's revocations and the signing keys.
  """
  @spec station(term()) :: :ok
  def station(station_id) when is_binary(station_id) do
    if open?() do
      SalixCopy.merge_station(Repo, station_id)

      case SalixRepo.one(
             from(s in SalixStation,
               where: s.id == ^station_id,
               select: {s.tenant_id, s.group_id}
             )
           ) do
        {tenant_id, group_id} -> group(tenant_id, group_id)
        nil -> keys()
      end
    end

    :ok
  end

  def station(_station_id), do: :ok

  @doc "Before a Group's roster, revocations or keys are read: its Workspace's are merged."
  @spec group(term(), term()) :: :ok
  def group(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    if open?() do
      if id = workspace_id(group_id), do: SalixCopy.merge_workspace(Repo, id)
      keys()
    end

    :ok
  end

  def group(_tenant_id, _group_id), do: :ok

  @doc "As `group/2`, for a Workspace at hand."
  @spec workspace(Workspace.t()) :: :ok
  def workspace(%Workspace{id: id}) do
    if open?() do
      SalixCopy.merge_workspace(Repo, id)
      keys()
    end

    :ok
  end

  defp keys do
    SalixCopy.merge_signing_keys(Repo)
    :ok
  end

  @doc "The Comma Workspace id of a Group while the window is open; nil for another product's Group, or after it."
  @spec workspace_id(String.t()) :: String.t() | nil
  def workspace_id(group_id) when is_binary(group_id) do
    if open?(),
      do: Repo.one(from(w in Workspace, where: w.salix_group_id == ^group_id, select: w.id))
  end

  # ── Comma's PubSub, as the servers of the release before use it ─────────

  defp station_topic(station_id), do: "comma_station:" <> station_id
  defp workspace_topic(workspace_id), do: "comma_station_ws:" <> workspace_id
  @keys_topic "comma_station_keys"

  defp pubsub, do: SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)

  @doc """
  A presence socket hears what servers of the release before publish for its
  station: removed, replaced, changed, a tool call, the keys.
  """
  def listen_station(station_id) do
    if open?() do
      Phoenix.PubSub.subscribe(pubsub(), station_topic(station_id))
      Phoenix.PubSub.subscribe(pubsub(), @keys_topic)
    end

    :ok
  end

  @doc "And for its Group's Workspace: the roster, a revocation. Answers the topic, for `unlisten/1`."
  def listen_group(group_id) do
    if id = workspace_id(group_id) do
      Phoenix.PubSub.subscribe(pubsub(), workspace_topic(id))
      workspace_topic(id)
    end
  end

  def unlisten(nil), do: :ok
  def unlisten(topic), do: Phoenix.PubSub.unsubscribe(pubsub(), topic)

  @doc "A station removed here: its socket on a server of the release before closes too."
  def tell_removed(station_id),
    do: tell(station_topic(station_id), {:comma_station, :removed})

  @doc "A newer socket here: an older one on a server of the release before closes."
  def tell_replaced(station_id, pid),
    do: tell(station_topic(station_id), {:comma_station, :replaced, pid})

  @doc "Revocations committed here: stations connected to a server of the release before get the `revoke` frame."
  def tell_revoked(revocations) do
    if open?() do
      Enum.each(revocations, fn {{_tenant_id, group_id}, revocation} ->
        if id = workspace_id(group_id),
          do: broadcast(workspace_topic(id), {:comma_station_ws, :revoke, revocation})
      end)
    end

    :ok
  end

  @doc "A device tool call for a station whose socket is on a server of the release before."
  def tell_tool(station_id, message), do: tell(station_topic(station_id), message)

  defp tell(topic, message) do
    if open?(), do: broadcast(topic, message)
    :ok
  end

  # Comma's PubSub runs where Comma's web application does; a server without
  # it (one that serves no stations) has no socket of the release before to
  # tell either.
  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(pubsub(), topic, message)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
