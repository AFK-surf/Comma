defmodule SalixWeb.StationTaskIndexTest do
  @moduledoc """
  `task.index` on a Connector run (`SalixWeb.StationTaskIndex`): a station
  that proved its key with `relay_register` sends its Task index while it is
  an active station of the run's Group, and the Device records the station
  it runs. Any other run is answered `not_this_group`; a connection over its
  page rate is answered `rate_limited`.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Ecto.Query

  alias SalixEnv.ConnectorTokens
  alias SalixStore.{Repo, Stations}
  alias SalixStore.StationTaskIndex.Row
  alias SalixWeb.StationTaskIndex

  @prefix "comma-salix-relay-v1:"

  defmodule Client do
    @moduledoc "A station's Connector: it reports `connected` and every answer to the test."
    use WebSockex

    def start(token, test_pid) do
      ws = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")
      query = URI.encode_query(%{"name" => "station-mac", "os" => "darwin"})

      WebSockex.start(ws <> "/v1/connect?" <> query, __MODULE__, test_pid,
        extra_headers: [{"authorization", "Bearer " <> token}]
      )
    end

    @impl true
    def handle_frame({:text, raw}, test_pid) do
      case Jason.decode!(raw) do
        %{"type" => "connected"} = connected ->
          SystemsRuntime.Proc.send(test_pid, {:connected, connected})
          {:ok, test_pid}

        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, test_pid}

        %{"type" => type, "id" => id} = answer when type in ["response", "error"] ->
          SystemsRuntime.Proc.send(test_pid, {:answer, id, answer})
          {:ok, test_pid}

        _ ->
          {:ok, test_pid}
      end
    end

    @impl true
    def handle_info({:send, frame}, test_pid),
      do: {:reply, {:text, Jason.encode!(frame)}, test_pid}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station Task index"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Index WS"}, tenant_id)
    {:ok, other} = Salix.Control.Groups.create(%{"name" => "Other WS"}, tenant_id)
    {:ok, tenant_id: tenant_id, group_id: group["group_id"], other_group_id: other["group_id"]}
  end

  defp connect(tenant_id, group_id) do
    {:ok, credential} = ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{})
    {:ok, pid} = Client.start(credential["token"], SystemsRuntime.Proc.self())

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    settle_receive({:connected, connected})
    %{pid: pid, connected: connected, device_id: credential["device_id"]}
  end

  defp request(%{pid: pid}, id, method, params) do
    SystemsRuntime.Proc.send(
      pid,
      {:send, %{"type" => "request", "id" => id, "method" => method, "params" => params}}
    )

    settle_receive({:answer, ^id, answer})
    answer
  end

  # The station proves its key: the iroh endpoint id is the station id.
  defp register(conn, {public, private}) do
    run = conn.connected["connector_run_id"]
    challenge = conn.connected["relay_challenge"]
    message = @prefix <> run <> ":" <> challenge

    params = %{
      "endpoint_id" => Base.encode16(public, case: :lower),
      "signature" =>
        Base.encode64(SystemsRuntime.Proc.sign(:eddsa, :none, message, [private, :ed25519]))
    }

    assert %{"type" => "response"} = request(conn, "register", "relay_register", params)
  end

  defp station_key do
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    {public, private, Base.encode16(public, case: :lower)}
  end

  defp reset_page(rows) do
    %{"epoch" => "e1", "reset" => true, "through" => length(rows), "rows" => rows}
  end

  defp row(thread, rev) do
    %{
      "thread" => thread,
      "rev" => rev,
      "title" => "Fix the build",
      "status" => "in_progress",
      "created_at" => 1_000,
      "last_activity_at" => 2_000
    }
  end

  test "a station that proved its key sends its Task index, and its Device records the station",
       %{tenant_id: tenant_id, group_id: group_id} do
    {public, private, station_id} = station_key()
    {:ok, _station, nil} = Stations.admit(tenant_id, group_id, station_id)
    conn = connect(tenant_id, group_id)
    register(conn, {public, private})
    :ok = StationTaskIndex.subscribe(group_id, SystemsRuntime.Proc.self())

    assert %{"type" => "response", "result" => %{"epoch" => "e1", "through" => 1}} =
             request(conn, "index-1", "task.index", reset_page([row("EMBER/1", 1)]))

    # A change Salix applied is told to the Group's subscribers; a page that
    # changes nothing is not.
    assert_received {:station_tasks_invalidated, ^group_id}

    assert %{"type" => "response", "result" => %{"through" => 1}} =
             request(conn, "index-2", "task.index", %{
               "epoch" => "e1",
               "since" => 1,
               "through" => 1,
               "rows" => []
             })

    refute_received {:station_tasks_invalidated, _}
    assert [%{thread: "EMBER/1", station_id: ^station_id}] = StationTaskIndex.list(group_id)

    assert [%Row{group_id: ^group_id, device_id: device_id, thread: "EMBER/1"}] =
             Repo.all(from(r in Row, where: r.station_id == ^station_id))

    assert device_id == conn.device_id

    assert settle_until(fn ->
             match?(
               {:ok, %{"station_id" => ^station_id}},
               SalixEnv.Control.get_environment(conn.device_id, group_id, tenant_id)
             )
           end)
  end

  test "a run that proved no station, or a station of another Group, is answered not_this_group",
       %{tenant_id: tenant_id, group_id: group_id, other_group_id: other_group_id} do
    {public, private, station_id} = station_key()
    {:ok, _station, nil} = Stations.admit(tenant_id, other_group_id, station_id)
    conn = connect(tenant_id, group_id)
    page = reset_page([row("EMBER/1", 1)])

    assert %{"type" => "error", "error" => "not_this_group"} =
             request(conn, "before", "task.index", page)

    register(conn, {public, private})

    assert %{"type" => "error", "error" => "not_this_group"} =
             request(conn, "elsewhere", "task.index", page)

    # Moved into the run's Group, then removed from it.
    {:ok, _station, _moved} = Stations.admit(tenant_id, group_id, station_id)
    assert %{"type" => "response"} = request(conn, "here", "task.index", page)
    :ok = Stations.remove(tenant_id, group_id, station_id)

    assert %{"type" => "error", "error" => "not_this_group"} =
             request(conn, "removed", "task.index", page)

    assert Repo.all(from(r in Row, where: r.station_id == ^station_id)) == []
  end

  test "a connection sends at most 4 pages a second" do
    {:ok, window} = StationTaskIndex.admit(nil, 0)
    {:ok, window} = StationTaskIndex.admit(window, 10)
    {:ok, window} = StationTaskIndex.admit(window, 20)
    {:ok, window} = StationTaskIndex.admit(window, 30)
    assert {:error, :rate_limited} = StationTaskIndex.admit(window, 999)
    assert {:ok, %{count: 1}} = StationTaskIndex.admit(window, 1_000)
  end

  test "an asynchronous page from a replaced physical run cannot overwrite the index",
       %{tenant_id: tenant, group_id: group} do
    {public, private, station} = station_key()
    {:ok, _station, nil} = Stations.admit(tenant, group, station)
    conn = connect(tenant, group)
    register(conn, {public, private})

    assert %{"type" => "response"} =
             request(conn, "current", "task.index", reset_page([row("EMBER/1", 1)]))

    {:ok, device} = SalixEnv.Registry.get_device(tenant, group, conn.device_id)
    context = SalixStore.ComputeStation.connection(tenant, group, device)

    {:ok, _, _replacement} =
      SalixEnv.Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => tenant,
          "group_id" => group,
          "device_id" => conn.device_id,
          "connector_id" => device["connector_id"]
        },
        transport_id: "index-replacement-" <> SystemsRuntime.Proc.uuid()
      )

    assert {:error, _} =
             StationTaskIndex.receive_page(station, context, reset_page([row("EMBER/1", 2)]))

    assert [%Row{rev: 1}] = Repo.all(from(r in Row, where: r.station_id == ^station))
  end

  test "a managed page uses its proved generation instead of the Device's newer Workload",
       %{tenant_id: tenant, group_id: group} do
    {_public, _private, station} = station_key()
    {:ok, _station, nil} = Stations.admit(tenant, group, station)
    conversation = "index-" <> SystemsRuntime.Proc.uuid()

    {:ok, workload} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: tenant,
        group_id: group,
        conversation_id: conversation,
        workspace: "comma:" <> group,
        repo: %{"owner" => "acme", "name" => "api"}
      })

    {:ok, _, device} =
      SalixEnv.Registry.connect(to_string(node()), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "device_id" => workload.spec["device_id"],
        "connector_id" => workload.spec["connector_id"],
        "workload_id" => workload.id,
        "workload_generation" => workload.generation,
        "managed_compute" => true
      })

    context = SalixStore.ComputeStation.connection(tenant, group, device)

    assert {:ok, _held} =
             StationTaskIndex.receive_page(station, context, reset_page([row("EMBER/1", 1)]))

    assert {:ok, _stopped} =
             SalixStore.CodingSandboxes.update(workload.id, fn current ->
               {:ok, Map.put(current.spec, "state", "stopped")}
             end)

    assert {:ok, _next} = SalixStore.CodingSandboxes.advance(workload.id)

    assert {:error, _} =
             StationTaskIndex.receive_page(station, context, reset_page([row("EMBER/1", 2)]))

    assert [%Row{rev: 1}] = Repo.all(from(r in Row, where: r.station_id == ^station))
  end
end
