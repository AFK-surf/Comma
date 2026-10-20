defmodule SalixWeb.ConnectorAbandonedDeviceTest do
  @moduledoc "An owner's next mint deletes abandoned and expired devices."
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.{ConnectorTokens, Registry}

  defmodule Client do
    @moduledoc "A connector that connects and answers heartbeats."
    use WebSockex

    def start(token, test_pid) do
      ws = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")
      query = URI.encode_query(%{"name" => "studio-mac", "os" => "linux"})

      WebSockex.start(ws <> "/v1/connect?" <> query, __MODULE__, test_pid,
        extra_headers: [{"authorization", "Bearer " <> token}]
      )
    end

    @impl true
    def handle_frame({:text, raw}, test_pid) do
      case Jason.decode!(raw) do
        %{"type" => "connected", "connector_run_id" => run} ->
          SystemsRuntime.Proc.send(test_pid, {:connected, run})
          {:ok, test_pid}

        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, test_pid}

        _ ->
          {:ok, test_pid}
      end
    end
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Abandoned devices"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Devices WS"}, tenant["tenant_id"])
    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "a mint deletes only its owner's revoked devices of the same surface that never connected",
       %{tenant_id: tenant_id, group_id: group_id} do
    mint = fn owner, surface ->
      meta =
        if surface,
          do: %{"owner_user_id" => owner, "surface" => surface},
          else: %{"owner_user_id" => owner}

      {:ok, credential} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{"meta" => meta})

      credential
    end

    revoke = fn credential ->
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 credential["token"]
               )

      credential["device_id"]
    end

    # Every comma mint by usr_a also sweeps, so what it must keep comes first.
    live = mint.("usr_a", "comma")["device_id"]

    connected = mint.("usr_a", "comma")
    {:ok, pid} = Client.start(connected["token"], SystemsRuntime.Proc.self())

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    settle_receive({:connected, _run})
    revoke.(connected)

    other_owner = mint.("usr_b", "comma") |> revoke.()
    other_surface = mint.("usr_a", "cli") |> revoke.()
    abandoned = [mint.("usr_a", "comma") |> revoke.()]

    # A mint that names no surface deletes nothing.
    mint.("usr_a", nil)
    assert Enum.all?(abandoned, &present?(tenant_id, group_id, &1))

    current = mint.("usr_a", "comma")["device_id"]

    refute Enum.any?(abandoned, &present?(tenant_id, group_id, &1))

    for kept <- [other_owner, other_surface, live, connected["device_id"], current] do
      assert present?(tenant_id, group_id, kept)
    end

    # A client still holding a deleted device's id is refused and mints a fresh one.
    assert {:error, :stable_device_unavailable} =
             ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
               "stable_device_id" => hd(abandoned),
               "meta" => %{"owner_user_id" => "usr_a", "surface" => "comma"}
             })
  end

  test "a mint removes the group's devices offline for more than 30 days and revokes them",
       %{tenant_id: tenant_id, group_id: group_id} do
    day = 24 * 60 * 60 * 1000
    now = SystemsClock.system_time(:millisecond)

    device = fn meta, offline_days ->
      {:ok, credential} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{"meta" => meta})

      {:ok, _transport, record} =
        Registry.connect(
          to_string(node()),
          %{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "device_id" => credential["device_id"],
            "connector_id" => credential["connector_id"]
          },
          connection_generation: 1,
          credential_generation: credential["credential_generation"],
          transport_id: "expiry-" <> credential["device_id"],
          now: now - (offline_days || 40) * day
        )

      if offline_days do
        {:ok, _} =
          Registry.mark_disconnected(record["connector_run_id"], now: now - offline_days * day)
      end

      credential
    end

    # Owner metadata without a surface: these mints sweep nothing.
    expired = device.(%{"owner_user_id" => "usr_b"}, 31)
    recent = device.(%{"owner_user_id" => "usr_b"}, 29)
    online = device.(%{"owner_user_id" => "usr_b"}, nil)
    ownerless = device.(%{}, 60)

    assert present?(tenant_id, group_id, expired["device_id"])

    {:ok, _} =
      ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
        "meta" => %{"owner_user_id" => "usr_a", "surface" => "comma"}
      })

    refute present?(tenant_id, group_id, expired["device_id"])

    for kept <- [recent, online, ownerless] do
      assert present?(tenant_id, group_id, kept["device_id"])
    end

    assert {:error, :connector_credential_revoked} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "device_id" => expired["device_id"],
                 "connector_id" => expired["connector_id"]
               },
               credential_generation: expired["credential_generation"],
               transport_id: "expiry-again"
             )
  end

  defp present?(tenant_id, group_id, device_id) do
    match?({:ok, _}, Registry.get_device(tenant_id, group_id, device_id))
  end
end
