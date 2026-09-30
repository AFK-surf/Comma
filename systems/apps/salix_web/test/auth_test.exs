defmodule SalixWeb.AuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Salix.Control.Tenants
  alias SalixStore.{Ids, Keys, S3}

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    {:ok, tenant} = Tenants.create(%{"name" => "Auth Test"})
    {:ok, tenant_key} = Tenants.create_api_key(tenant["tenant_id"], %{"name" => "Auth Test"})

    {connector_token, connector_token_key} = seed_connector_token!(tenant["tenant_id"])

    SalixStore.S3.Fake.reset_read_log()

    foreign_read_key = "auth-test/foreign-read/#{System.unique_integer([:positive])}"

    assert {:error, :not_found} =
             Task.async(fn -> SalixStore.S3.Fake.get(foreign_read_key, []) end)
             |> Task.await()

    on_exit(fn -> restore_env(:salix_store, :s3_backend, previous_backend) end)

    {:ok,
     tenant_id: tenant["tenant_id"],
     tenant_key: tenant_key["key"],
     tenant_key_record: Keys.ctl_api_key(tenant["tenant_id"], token_hash(tenant_key["key"])),
     tenant_record: Keys.ctl_tenant(tenant["tenant_id"]),
     connector_token: connector_token,
     connector_token_key: connector_token_key,
     foreign_read_key: foreign_read_key}
  end

  test "tenant API key is validated once per request", ctx do
    conn =
      ctx.tenant_key
      |> request_conn("/v1/runtime/agents")
      |> SalixWeb.Auth.call([])

    assert conn.assigns.auth_role == :tenant
    assert conn.assigns.tenant_id == ctx.tenant_id

    # The key lookup is a Postgres point read; the only S3 read is the tenant
    # record (docs/storage-search.md).
    assert {:get, ctx.foreign_read_key} in SalixStore.S3.Fake.read_log()
    assert SalixStore.S3.Fake.read_log(self()) == [{:get, ctx.tenant_record}]
  end

  test "connector token is validated once and keeps the connector role", ctx do
    conn =
      ctx.connector_token
      |> request_conn("/v1/connect")
      |> SalixWeb.Auth.call([])

    assert conn.assigns.auth_role == :connector
    assert conn.assigns.tenant_id == ctx.tenant_id
    assert conn.assigns.connector_token["token_hash"]
    assert SalixStore.S3.Fake.read_log(self()) == [{:get, ctx.connector_token_key}]
  end

  test "connect path still falls back to a tenant API key without duplicate validation", ctx do
    conn =
      ctx.tenant_key
      |> request_conn("/v1/connect")
      |> SalixWeb.Auth.call([])

    assert conn.assigns.auth_role == :tenant
    assert conn.assigns.tenant_id == ctx.tenant_id
    refute Map.has_key?(conn.assigns, :connector_token)

    assert SalixStore.S3.Fake.read_log(self()) == [
             {:get, Keys.ctl_connector_token(token_hash(ctx.tenant_key))},
             {:get, ctx.tenant_record}
           ]
  end

  test "invalid tenant bearer remains unauthorized after one validation", _ctx do
    token = "invalid-tenant-token"

    conn =
      token
      |> request_conn("/v1/runtime/agents")
      |> SalixWeb.Auth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}

    # An unknown key misses in Postgres before any S3 read happens.
    assert SalixStore.S3.Fake.read_log(self()) == []
  end

  test "compute gateway secret is scoped to compute paths and requires workload identity" do
    previous = Application.get_env(:salix_web, :agent_vmm_gateway_control_secret)
    Application.put_env(:salix_web, :agent_vmm_gateway_control_secret, "compute-secret")
    on_exit(fn -> restore_env(:salix_web, :agent_vmm_gateway_control_secret, previous) end)

    conn =
      "compute-secret"
      |> request_conn("/v1/compute/commands/claim")
      |> put_req_header("x-agent-vmm-gateway-instance", "gateway-a")
      |> SalixWeb.Auth.call([])

    assert conn.assigns.auth_role == :compute_gateway
    assert conn.assigns.gateway_instance_id == "gateway-a"

    refute Map.has_key?(
             "compute-secret"
             |> request_conn("/v1/runtime/agents")
             |> SalixWeb.Auth.call([])
             |> Map.get(:assigns),
             :auth_role
           )
  end

  defp request_conn(token, path) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp seed_connector_token!(tenant_id) do
    token = "salix_conn_auth_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    hash = token_hash(token)

    record = %{
      "token_hash" => hash,
      "tenant_id" => tenant_id,
      "group_id" => Ids.new_group_id(tenant_id),
      "device_id" => "dev_auth",
      "connector_id" => "conn_auth",
      "name" => "Auth Test",
      "alias" => "auth-test",
      "meta" => %{},
      "created_at" => System.system_time(:second),
      "expires_at" => nil
    }

    assert {:ok, _} = S3.put(Keys.ctl_connector_token(hash), Jason.encode!(record))
    {token, Keys.ctl_connector_token(hash)}
  end

  defp token_hash(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
