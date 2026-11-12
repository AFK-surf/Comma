defmodule SalixIM.LarkSocketRuntime do
  @moduledoc """
  Keeps one long connection (`SalixIM.LarkSocket`) per Lark or Feishu
  connect with `"events" => "socket"` in the cluster.

  Every pass lists those connects. For each one without a socket on this
  node, the node tries to take the connect's lease; the node that has it
  starts the socket, which renews the lease and stops when it loses it. A
  socket whose connect is gone, disabled, or has other credentials now is
  stopped, and the next pass starts a new one.

  A pass reads the index of socket connects
  (`ProviderConnects.list_socket_connects/0`), so its cost is that of the
  socket connects alone. Once when it starts, the runtime indexes the socket
  connects stored before the index (`ProviderConnects.index_socket_connects/0`),
  which reads every connect; it tries again on the next pass until that
  succeeds. A pass never crashes the runtime: a failed pass is logged and
  the next one runs on schedule.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.{LarkSocket, ProviderConnects}

  @default_interval_ms 15_000
  @lease_ttl_ms 30_000

  def start_link(opts \\ []),
    do:
      SystemsRuntime.Server.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, __MODULE__)
      )

  @doc "One pass: start the sockets this node may hold, stop the stale ones."
  def sync_once(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, SalixIM.LarkSocketSupervisor)
    holder = Keyword.get(opts, :holder, holder())

    with {:ok, connects} <- ProviderConnects.list_socket_connects() do
      wanted = Map.new(connects, &{&1["connect_id"], &1})

      stop_stale(supervisor, wanted)
      Enum.each(wanted, fn {_id, connect} -> ensure(supervisor, connect, holder) end)
      {:ok, map_size(wanted)}
    end
  end

  @doc "The lease key of a connect's socket."
  def lease_key(connect_id), do: "ctl/im/lark-socket/" <> connect_id

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sync, 0)

    {:ok,
     %{
       interval_ms: interval_ms,
       holder: holder(),
       indexed?: Keyword.get(opts, :indexed?, false)
     }}
  end

  @impl true
  def handle_info(:sync, state) do
    state = index(state)

    try do
      case sync_once(holder: state.holder) do
        {:ok, _count} -> :ok
        {:error, reason} -> Logger.warning("lark socket pass failed", reason: inspect(reason))
      end
    rescue
      exception ->
        Logger.error("lark socket pass crashed: " <> Exception.message(exception))
    end

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sync, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp index(%{indexed?: true} = state), do: state

  defp index(state) do
    case ProviderConnects.index_socket_connects() do
      :ok ->
        %{state | indexed?: true}

      {:error, reason} ->
        Logger.warning("lark socket connects not indexed", reason: inspect(reason))
        state
    end
  rescue
    exception ->
      Logger.error("lark socket indexing crashed: " <> Exception.message(exception))
      state
  end

  # A socket whose connect is gone, or opened with other credentials.
  defp stop_stale(supervisor, wanted) do
    for {connect_id, pid, credentials} <-
          SystemsRuntime.Registry.select(SalixIM.LarkSocketRegistry, [
            {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
          ]),
        wanted[connect_id] == nil or LarkSocket.credentials(wanted[connect_id]) != credentials do
      SystemsRuntime.DynamicSupervisor.terminate_child(supervisor, pid)
    end

    :ok
  end

  defp ensure(supervisor, connect, holder) do
    connect_id = connect["connect_id"]

    if LarkSocket.whereis(connect_id) == nil do
      case SalixStore.Lease.acquire(lease_key(connect_id), holder, ttl_ms: @lease_ttl_ms) do
        {:ok, lease} ->
          case SystemsRuntime.DynamicSupervisor.start_child(
                 supervisor,
                 {LarkSocket, connect: connect, lease: lease}
               ) do
            {:ok, _pid} ->
              :ok

            other ->
              SalixStore.Lease.release(lease)

              Logger.warning("lark socket not started",
                connect_id: connect_id,
                reason: inspect(other)
              )
          end

        {:error, {:held_by, _holder, _until}} ->
          :ok

        {:error, reason} ->
          Logger.warning("lark socket lease not taken",
            connect_id: connect_id,
            reason: inspect(reason)
          )
      end
    end

    :ok
  end

  # One live process per node: a restarted runtime takes its own stale lease
  # back, and another node's holder never matches.
  defp holder, do: Atom.to_string(node()) <> ":lark-socket"
end
