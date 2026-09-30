defmodule SalixEnv.VM.Providers.Cloudflare.ClientTest do
  use ExUnit.Case, async: false

  alias SalixEnv.VM.Providers.Cloudflare.{Client, MockGateway}
  alias SalixStore.Compute

  setup do
    mock = start_supervised!(MockGateway)

    client =
      Client.new(base_url: MockGateway.base_url(mock), secret: "test-secret", backoff_ms: 1)

    %{mock: mock, client: client}
  end

  test "ensure/status/destroy/checkpoint/restore/keepalive call versioned worker contract", %{
    mock: mock,
    client: client
  } do
    assert {:ok,
            %{
              "sandbox_id" => "sb-1",
              "status" => "ready",
              "worker_version_id" => "version-1",
              "worker_version_tag" => "tag-1",
              "gateway_build_id" => "build-1",
              "connector_image_version" => "connector-1"
            }} =
             Client.ensure(client, "sb-1", keep_alive: true)

    assert {:ok, %{"status" => "ready"}} = Client.status(client, "sb-1")
    assert {:ok, %{"archive" => %{"id" => "a1"}}} = Client.checkpoint(client, "sb-1")

    assert {:ok, %{"restore" => %{"restored" => true}}} =
             Client.restore(client, "sb-1", %{"id" => "a1"})

    assert {:ok, %{"keep_alive" => false}} = Client.keepalive(client, "sb-1", false)
    assert :ok = Client.destroy(client, "sb-1")

    assert [
             %{
               op: :ensure,
               sandbox_id: "sb-1",
               body: %{"sandbox_id" => "sb-1", "keep_alive" => true}
             },
             %{op: :status, sandbox_id: "sb-1"},
             %{op: :proxy, sandbox_id: "sb-1", path: "/internal/v1/sandboxes/sb-1/proxy/archive"},
             %{op: :checkpoint, sandbox_id: "sb-1"},
             %{op: :restore, sandbox_id: "sb-1"},
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

  test "connect_request returns signed websocket endpoint", %{client: client} do
    request = Client.connect_request(client, "sb-1")
    assert request.url =~ ~r|^ws://127\.0\.0\.1:\d+/internal/v1/sandboxes/sb-1/connect$|

    assert {"x-salix-signature", "sha256=" <> _} =
             List.keyfind(request.headers, "x-salix-signature", 0)

    assert {"Cloudflare-Workers-Version-Key", "sb-1"} =
             List.keyfind(request.headers, "Cloudflare-Workers-Version-Key", 0)
  end

  test "standard-1 signs and routes every operation through its profile path", %{mock: mock} do
    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        profile_key: "cf-standard-1"
      )

    assert {:ok, _} = Client.ensure(client, "sb-shared")
    assert {:ok, _} = Client.status(client, "sb-shared")
    assert :ok = Client.destroy(client, "sb-shared")

    assert Enum.all?(MockGateway.calls(mock), fn call ->
             String.starts_with?(
               call.path,
               "/internal/v1/profiles/cf-standard-1/sandboxes"
             )
           end)

    assert Client.connect_request(client, "sb-shared").url =~
             "/internal/v1/profiles/cf-standard-1/sandboxes/sb-shared/connect"
  end

  test "an unresolved profile fails closed without using the standard-2 path", %{mock: mock} do
    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        profile_key: nil,
        max_retries: 0
      )

    assert {:error, _} = Client.ensure(client, "sb-legacy")
    assert [%{path: "/internal/v1/profiles/unknown/sandboxes"}] = MockGateway.calls(mock)
  end

  test "a Gateway without the profile collection fails closed on the first ensure", %{
    mock: mock
  } do
    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        profile_key: "cf-standard-1",
        max_retries: 2
      )

    # A pre-profile Worker answers its unknown-path body for the profile collection.
    :ok =
      MockGateway.set_error(mock, 404, %{
        "ok" => false,
        "error" => %{"code" => "not_found", "message" => "not_found"}
      })

    assert {:error, {:gateway_profile_unsupported, "cf-standard-1"}} =
             Client.ensure(client, "sb-new")

    assert [%{path: "/internal/v1/profiles/cf-standard-1/sandboxes"}] = MockGateway.calls(mock)
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

  test "adds optional worker version override header", %{mock: mock} do
    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        worker_name: "salix-vm-verify",
        worker_version_id: "candidate-version",
        backoff_ms: 1
      )

    assert {:ok, %{"sandbox_id" => "sb-1"}} = Client.ensure(client, "sb-1")

    assert [
             %{
               worker_version_key: "sb-1",
               worker_version_overrides: "salix-vm-verify=\"candidate-version\""
             }
           ] = MockGateway.calls(mock)
  end

  test "proxy calls diagnostic path with signed headers", %{mock: mock, client: client} do
    assert {:ok, %Req.Response{status: 200}} = Client.proxy(client, "sb-1", "/readyz")

    assert [%{op: :proxy, path: "/internal/v1/sandboxes/sb-1/proxy/readyz"}] =
             MockGateway.calls(mock)
  end

  test "a completed proxy error settles its Gateway attempt", %{mock: mock} do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sb-proxy-error",
               "status" => "ready",
               "created_at" => 1234
             })

    client =
      Client.new(base_url: MockGateway.base_url(mock), secret: "test-secret", group_id: group)

    :ok = MockGateway.set_error(mock, 503, %{"error" => "connector unavailable"})

    assert {:ok, %Req.Response{status: 503}} = Client.proxy(client, "sb-proxy-error", "/readyz")
    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)
  end

  test "a rejected managed request settles its Gateway attempt", %{mock: mock} do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sb-rejected",
               "status" => "ready",
               "created_at" => 1234
             })

    client =
      Client.new(
        base_url: MockGateway.base_url(mock),
        secret: "test-secret",
        group_id: group,
        max_retries: 0
      )

    :ok =
      MockGateway.set_error(mock, 401, %{
        "ok" => false,
        "error" => %{"code" => "bad_signature", "message" => "invalid signature"}
      })

    assert {:error, {:api_error, 401, "bad_signature", _}} = Client.status(client, "sb-rejected")
    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)
  end

  test "maps structured worker errors", %{mock: mock, client: client} do
    :ok =
      MockGateway.set_error(mock, 401, %{
        "ok" => false,
        "error" => %{"code" => "bad_signature", "message" => "invalid signature"}
      })

    assert {:error, {:api_error, 401, "bad_signature", "invalid signature"}} =
             Client.status(client, "sb-1")
  end

  test "signatures match the Worker canonical request format" do
    assert Client.signature("secret", :post, "/internal/v1/sandboxes", "123", "nonce", "{}") ==
             "sha256=3df2bb52d5944d88507b72a5542b58d6bb3dc4e8c568a43b46708c5493a2c254"
  end
end
