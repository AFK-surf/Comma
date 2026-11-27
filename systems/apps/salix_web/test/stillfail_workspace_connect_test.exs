defmodule SalixWeb.StillfailWorkspaceConnectTest do
  @moduledoc """
  A still.fail station's connect names its still.fail workspace as it
  connects (`stillfail_workspace`); a Group takes one device of a workspace,
  so that workspace's usage and chats count once. Another device of the same
  workspace is refused until the first is removed; a device of another
  workspace connects.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.StillfailDevices

  defmodule Client do
    @moduledoc "A still.fail station's connect: it reports `connected` to the test."
    use WebSockex

    def start(token, workspace, test_pid) do
      ws = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")

      query =
        URI.encode_query(%{
          "name" => "WS · mac",
          "os" => "darwin",
          "stillfail_workspace" => workspace
        })

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

        _ ->
          {:ok, test_pid}
      end
    end
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "still.fail workspaces"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Comma WS"}, tenant_id)
    {:ok, tenant_id: tenant_id, group_id: group["group_id"]}
  end

  defp token(group_id, tenant_id) do
    {:ok, "comma " <> rest} = StillfailDevices.connect_line(group_id, tenant_id)
    [_server, token] = String.split(rest, " ")
    token
  end

  defp connect(token, workspace) do
    case Client.start(token, workspace, SystemsRuntime.Proc.self()) do
      {:ok, pid} ->
        on_exit(fn ->
          if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
        end)

        settle_receive({:connected, connected})
        {:ok, Map.put(connected, "client", pid)}

      {:error, error} ->
        {:error, error}
    end
  end

  test "a Group takes one still.fail device of a workspace", %{tenant_id: tenant, group_id: group} do
    first = token(group, tenant)
    second = token(group, tenant)

    assert {:ok, %{"device_id" => first_device}} = connect(first, "ws_one")

    assert {:error, %WebSockex.RequestError{code: 409}} = connect(second, "ws_one")

    # The same station connecting again is its own device, not another.
    assert {:ok, %{"device_id" => ^first_device}} = connect(first, "ws_one")

    # Another workspace connects; the first workspace's device removed, the second takes it.
    assert {:ok, _} = connect(token(group, tenant), "ws_two")
    assert :ok = StillfailDevices.remove(group, first_device)
    assert {:ok, %{"device_id" => second_device}} = connect(second, "ws_one")

    # An agent's tool reads them within one bounded read, as the plugin lists them.
    {:ok, listed} = StillfailDevices.list(group)
    assert {:ok, paged, false} = StillfailDevices.first_page(group)
    assert Enum.sort_by(paged, & &1["id"]) == Enum.sort_by(listed, & &1["id"])

    assert %{"connected" => true, "name" => "WS · mac", "workspace" => nil} =
             Enum.find(paged, &(&1["id"] == second_device))
  end

  test "stillfail_owner_email metadata is exposed on StillfailDevices and wakes station_task_index_observer",
       %{tenant_id: tenant, group_id: group} do
    test_pid = SystemsRuntime.Proc.self()
    prev_observer = SystemsRuntime.get_env(:salix_web, :station_task_index_observer)

    defmodule OwnerEmailObserver do
      def station_tasks_changed(group_id) do
        if pid = SystemsRuntime.get_env(:salix_web, :stillfail_owner_email_test_pid) do
          SystemsRuntime.Proc.send(pid, {:station_tasks_changed, group_id})
        end

        :ok
      end
    end

    SystemsRuntime.put_env(:salix_web, :stillfail_owner_email_test_pid, test_pid)
    SystemsRuntime.put_env(:salix_web, :station_task_index_observer, OwnerEmailObserver)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :stillfail_owner_email_test_pid)

      if prev_observer do
        SystemsRuntime.put_env(:salix_web, :station_task_index_observer, prev_observer)
      else
        SystemsRuntime.delete_env(:salix_web, :station_task_index_observer)
      end
    end)

    assert {:ok, %{"device_id" => device_id, "client" => client}} =
             connect(token(group, tenant), "ws_owner")

    :ok =
      WebSockex.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "type" => "metadata",
           "capabilities" => %{
             "tasks" => 2,
             "stillfail_owner_email" => "  Owner@Stillfail.Test "
           }
         })}
      )

    settle_receive({:station_tasks_changed, ^group})

    assert %{^device_id => "owner@stillfail.test"} =
             StillfailDevices.owner_emails_by_device(group)

    assert {:ok, [shown]} = StillfailDevices.list(group)
    assert shown["owner_email"] == "owner@stillfail.test"

    # A subsequent metadata update carrying an updated stillfail_owner_active_at
    # (with the same stillfail_owner_email) updates StillfailDevices without
    # re-triggering station_tasks_changed.
    active_ts = 1_795_200_000_000

    :ok =
      WebSockex.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "type" => "metadata",
           "capabilities" => %{
             "tasks" => 2,
             "stillfail_owner_email" => "  Owner@Stillfail.Test ",
             "stillfail_owner_active_at" => active_ts
           }
         })}
      )

    settle_until(fn ->
      match?(%{^device_id => ^active_ts}, StillfailDevices.owner_active_at_by_device(group))
    end)

    refute_received {:station_tasks_changed, ^group}

    assert {:ok, [shown_after]} = StillfailDevices.list(group)
    assert shown_after["owner_active_at"] == active_ts
  end

  test "the station's metadata says its workspace, and the list shows it",
       %{tenant_id: tenant, group_id: group} do
    assert {:ok, %{"device_id" => device, "client" => client}} =
             connect(token(group, tenant), "ws_one")

    metadata = fn workspace ->
      WebSockex.send_frame(
        client,
        {:text,
         Jason.encode!(%{
           "type" => "metadata",
           "capabilities" => %{"tasks" => 2, "stillfail_workspace" => workspace}
         })}
      )
    end

    shown = fn ->
      {:ok, listed} = StillfailDevices.list(group)
      Enum.find(listed, &(&1["id"] == device))["workspace"]
    end

    :ok =
      metadata.(%{
        "id" => "ws_one",
        "name" => "Acme",
        "emoji" => "🦊",
        "icon" => "https://example.com/acme.png",
        "station" => "mac",
        "stations" => [%{"id" => "s1", "name" => "mac"}, %{"id" => "s2", "name" => "studio"}]
      })

    settle()

    assert shown.() == %{
             "name" => "Acme",
             "emoji" => "🦊",
             "station" => "mac",
             "station_count" => 2
           }

    # Said again as it changes (a rename, a station gone), the list follows.
    :ok =
      metadata.(%{
        "id" => "ws_one",
        "name" => "Acme Labs",
        "station" => "mac",
        "stations" => [%{"id" => "s1"}]
      })

    settle()

    assert shown.() == %{
             "name" => "Acme Labs",
             "emoji" => nil,
             "station" => "mac",
             "station_count" => 1
           }
  end
end
