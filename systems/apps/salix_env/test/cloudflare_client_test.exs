defmodule SalixEnv.VM.Providers.Cloudflare.ClientTest do
  use SystemsClock.Case, async: false

  alias SalixEnv.VM.Providers.Cloudflare.{Client, MockGateway}
  alias SalixStore.Compute

  @station %{"server" => "wss://salix.example", "credential" => "connect-credential"}

  setup do
    mock = start_supervised!(MockGateway)

    client =
      Client.new(base_url: MockGateway.base_url(mock), secret: "test-secret", backoff_ms: 1)

    %{mock: mock, client: client}
  end

  test "ensure/status/keepalive/destroy call versioned worker contract", %{
    mock: mock,
    client: client
  } do
    assert {:ok,
            %{
              "sandbox_id" => "sb-1",
              "status" => "started",
              "worker_version_id" => "version-1",
              "worker_version_tag" => "tag-1",
              "gateway_build_id" => "build-1",
              "connector_image_version" => "connector-1"
            }} =
             Client.ensure(client, "sb-1", keep_alive: true, station: @station)

    assert {:ok, %{"status" => "running"}} = Client.status(client, "sb-1")

    assert {:ok, %{"keep_alive" => false}} = Client.keepalive(client, "sb-1", false)
    assert :ok = Client.destroy(client, "sb-1")

    assert [
             %{
               op: :ensure,
               sandbox_id: "sb-1",
               body: %{"sandbox_id" => "sb-1", "keep_alive" => true, "station" => @station}
             },
             %{op: :status, sandbox_id: "sb-1"},
             %{op: :keepalive, sandbox_id: "sb-1", body: %{"keep_alive" => false}},
             %{op: :destroy, sandbox_id: "sb-1"}
           ] = MockGateway.calls(mock)

    for call <- MockGateway.calls(mock) do
      assert call.signature =~ ~r/^sha256=[0-9a-f]{64}$/
      assert call.timestamp
      assert call.nonce
      assert call.request_id
      assert call.worker_version_key == "sb-1"
    end
  end

  test "a transport failure keeps the start claim until release reconciliation", %{mock: mock} do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sb-transport",
               "status" => "ready",
               "created_at" => 1234
             })

    settled =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        group_id: group,
        max_retries: 0
      )

    assert {:ok, _} = Client.status(settled, "sb-transport")
    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)

    uncertain = %{settled | base_url: "http://127.0.0.1:1"}
    assert {:error, _} = Client.status(uncertain, "sb-transport")
    assert {:ok, %{"active_operation_count" => 1}} = Compute.group_workload(group)
  end

  test "signatures match the Worker canonical request format" do
    assert Client.signature("secret", :post, "/internal/v1/sandboxes", "123", "nonce", "{}") ==
             "sha256=3df2bb52d5944d88507b72a5542b58d6bb3dc4e8c568a43b46708c5493a2c254"
  end

  @tag :disposable_reset
  test "nonrunning does not settle an unknown native destroy and stale owner never calls it", %{
    mock: mock
  } do
    {client, before, prepared} = prepare_discard(mock, "cf-standard-2", 0)
    observation = discarded_observation(prepared)

    unknown =
      put_in(observation, ["control", "pending"], observation["control"]["last_terminal"])
      |> put_in(["control", "last_terminal"], nil)

    :ok =
      MockGateway.set_responses(mock, [
        {200, unknown},
        {200, unknown},
        {409, %{"error" => "control_command_unsettled"}},
        {200, unknown}
      ])

    assert {:error, {:cloudflare_discard_unconfirmed, _}} =
             Client.discard(client, "sb-discard", prepared)

    assert {:error, :cloudflare_discard_target_changed} =
             Client.discard(client, "sb-discard", before)

    assert length(MockGateway.calls(mock)) == 4
    assert {:ok, current} = Compute.group_workload(client.group_id)
    assert current["generation"] == before["generation"]
  end

  defp prepare_discard(mock, profile, claims) do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    {:ok, _, :created} =
      Compute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "provider" => "cloudflare",
        "provider_resource_id" => "sb-discard",
        "provider_resource_name" => "sb-discard",
        "provider_spec" => %{"profile_key" => profile},
        "status" => "ready",
        "created_at" => 1234
      })

    target = profile <> ":sb-discard"
    {:ok, _} = Compute.prepare_cloudflare_control(group, target, :open)

    if claims > 0 do
      for n <- 1..claims do
        {:ok, _} = Compute.begin_cloudflare_gateway_attempt(group, "legacy-#{n}", :normal, target)
      end
    end

    {:ok, before} = Compute.group_workload(group)
    {:ok, prepared} = Compute.begin_cloudflare_discard(group, before)

    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        group_id: group,
        profile_key: profile,
        max_retries: 2,
        backoff_ms: 1
      )

    {client, before, prepared}
  end

  defp discarded_observation(prepared) do
    terminal =
      prepared["cloudflare_control"]
      |> Map.put("claim_id", prepared["archive_operation_id"])
      |> Map.put("action", "destroy")
      |> Map.put("outcome", "completed")

    %{
      "running" => false,
      "managed_commands_settled" => true,
      "control" =>
        prepared["cloudflare_control"]
        |> Map.put("pending", nil)
        |> Map.put("last_terminal", terminal)
    }
  end
end
