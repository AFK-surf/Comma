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
        {:ok, connected}

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

    assert %{"connected" => true, "name" => "WS · mac"} =
             Enum.find(paged, &(&1["id"] == second_device))
  end
end
