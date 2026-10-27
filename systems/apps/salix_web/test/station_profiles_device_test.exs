defmodule SalixWeb.StationProfilesDeviceTest do
  @moduledoc """
  The workspace's accounts lent to a member's device station
  (`SalixWeb.StationProfiles` on a device's Connector run): once the run
  proves its station with `relay_register`, Salix sends `station_profiles`,
  an empty list when the workspace has no accounts, and no placement. The
  station's `share.*` requests are served while its owner may enroll a
  station in the Group; a read-only member's station gets no profiles and is
  refused.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixAgent.SubscriptionStore
  alias SalixEnv.ConnectorTokens

  @prefix "comma-salix-relay-v1:"

  defmodule Product do
    @moduledoc "The product that owns the test's Group: a member, and a read-only viewer."
    @behaviour SalixStore.StationMembers

    @impl true
    def role(_tenant_id, _group_id, "u_member"), do: {:ok, "member"}
    def role(_tenant_id, _group_id, "u_viewer"), do: {:ok, "viewer"}
    def role(_tenant_id, _group_id, _user_id), do: :none

    @impl true
    def manager_role?(_role), do: false

    @impl true
    def read_only_role?(role), do: role == "viewer"

    @impl true
    def workspace_name(_tenant_id, _group_id), do: :none

    @impl true
    def workspace_active?(_tenant_id, _group_id), do: :none
  end

  defmodule Client do
    @moduledoc "A desktop station's Connector: it tells the test what Salix asks and answers it."
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

        %{"type" => "request", "id" => id, "method" => method} = request ->
          SystemsRuntime.Proc.send(test_pid, {:asked, method, request["params"]})
          reply = %{"type" => "response", "id" => id, "result" => %{"received" => true}}
          {:reply, {:text, Jason.encode!(reply)}, test_pid}

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
    prior = SystemsRuntime.get_env(:salix_store, :station_members)
    SystemsRuntime.put_env(:salix_store, :station_members, [Product])

    on_exit(fn ->
      if prior,
        do: SystemsRuntime.put_env(:salix_store, :station_members, prior),
        else: SystemsRuntime.delete_env(:salix_store, :station_members)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Desktop station profiles"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Desktop WS"}, tenant["tenant_id"])
    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  defp add_api_key(tenant_id) do
    account = "acct-" <> SubscriptionStore.id()
    {:ok, sealed} = SubscriptionStore.seal(tenant_id, account, %{"api_key" => "sk-desk"})

    {:ok, _} =
      SubscriptionStore.create(tenant_id, %{
        "id" => account,
        "name" => "Anthropic",
        "credential" => "api_key",
        "source" => "anthropic",
        "disabled" => false,
        "credentials" => sealed,
        "endpoint" => "https://api.anthropic.com",
        "protocol" => "anthropic",
        "auth" => "api_key"
      })
  end

  # The member's desktop station connects and proves its key.
  defp connect_station(tenant_id, group_id, owner) do
    {:ok, credential} =
      ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
        "meta" => %{"owner_user_id" => owner}
      })

    {:ok, pid} = Client.start(credential["token"], SystemsRuntime.Proc.self())

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    settle_receive({:connected, connected})
    conn = %{pid: pid, connected: connected}
    # Nothing is lent to a run before it proves a station.
    refute_received {:asked, "station_profiles", _}
    register(conn)
    conn
  end

  defp register(conn) do
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)

    message =
      @prefix <> conn.connected["connector_run_id"] <> ":" <> conn.connected["relay_challenge"]

    params = %{
      "endpoint_id" => Base.encode16(public, case: :lower),
      "signature" =>
        Base.encode64(SystemsRuntime.Proc.sign(:eddsa, :none, message, [private, :ed25519]))
    }

    assert %{"type" => "response"} = request(conn, "register", "relay_register", params)
  end

  defp request(%{pid: pid}, id, method, params) do
    SystemsRuntime.Proc.send(
      pid,
      {:send, %{"type" => "request", "id" => id, "method" => method, "params" => params}}
    )

    settle_receive({:answer, ^id, answer})
    answer
  end

  test "a member's desktop station is sent the workspace's accounts once it proves its key, and is not placed",
       %{tenant_id: tenant_id, group_id: group_id} do
    add_api_key(tenant_id)
    conn = connect_station(tenant_id, group_id, "u_member")

    # Desktop connections need no separate single-Group roster enrollment.
    assert SalixStore.Stations.roster(tenant_id, group_id) == []

    settle_until(fn ->
      SalixStore.StationDeviceLookup.page(tenant_id, group_id, "u_member", 8) != []
    end)

    assert [%{device_id: device}] =
             SalixStore.StationDeviceLookup.page(tenant_id, group_id, "u_member", 8)

    assert device == conn.connected["device_id"]

    settle_receive({:asked, "station_profiles", %{"profiles" => profiles}})
    assert [%{"id" => "sh-" <> _ = share, "profile" => profile}] = profiles

    assert Map.take(profile, ~w(runtime credential key)) ==
             %{"runtime" => "claude", "credential" => "api_key", "key" => "sk-desk"}

    assert %{"type" => "response", "result" => %{"profile" => ^profile}} =
             request(conn, "get", "share.get", %{"id" => share})

    assert %{"type" => "error", "error" => "only a subscription is lent"} =
             request(conn, "lend", "share.lend", %{"id" => share})

    refute_received {:asked, "station_identity", _}
    refute_received {:asked, "station_place", _}
  end

  test "a workspace without accounts sends an empty list",
       %{tenant_id: tenant_id, group_id: group_id} do
    _conn = connect_station(tenant_id, group_id, "u_member")
    settle_receive({:asked, "station_profiles", %{"profiles" => []}})
  end

  test "a read-only member's station is sent no accounts and refused what it asks",
       %{tenant_id: tenant_id, group_id: group_id} do
    add_api_key(tenant_id)
    conn = connect_station(tenant_id, group_id, "u_viewer")
    settle_receive({:asked, "station_profiles", %{"profiles" => []}})

    assert %{"type" => "error", "error" => "this station is not lent the workspace's accounts"} =
             request(conn, "lend", "share.lend", %{"id" => "sh-any"})
  end
end
