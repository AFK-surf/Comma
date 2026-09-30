defmodule SalixWeb.CommaApiTest do
  use ExUnit.Case, async: false

  @admin_token "test-token"

  setup do
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_web, :api_token, @admin_token)

    on_exit(fn ->
      if prev_api_token do
        Application.put_env(:salix_web, :api_token, prev_api_token)
      else
        Application.delete_env(:salix_web, :api_token)
      end
    end)

    tenant_resp = admin_req(:post, "/v1/admin/tenants", json: %{name: "Comma Api Test Tenant"})
    tenant_id = tenant_resp.body["tenant_id"]
    key_resp = admin_req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"})
    tenant_key = key_resp.body["key"]
    Process.put(:test_tenant_id, tenant_id)
    Process.put(:test_tenant_key, tenant_key)
    :ok
  end

  test "Comma product API is not served from the Salix runtime endpoint" do
    # Admin-namespaced Comma routes: admin token is accepted, but the routes are
    # absent from the Salix runtime endpoint, so they 404.
    assert admin_req(:post, "/v1/admin/users", json: %{"email" => "user@example.com"}).status ==
             404

    assert admin_req(:get, "/v1/admin/users").status == 404

    # /v1/workspaces is a non-admin path. The admin token is no longer valid
    # outside /v1/admin/*, so auth rejects it before routing (401, not 200).
    assert admin_req(:get, "/v1/workspaces").status == 401

    # A valid tenant API key passes auth but the route is genuinely absent from
    # the Salix runtime endpoint, confirming the Comma product API is not served here.
    assert tenant_req(:get, "/v1/workspaces").status == 404
  end

  test "cluster observability remains admin-only on the Salix runtime endpoint" do
    assert Req.request!(method: :get, url: base() <> "/v1/admin/cluster/stats").status == 401

    stats = admin_req(:get, "/v1/admin/cluster/stats") |> expect_status(200) |> Map.fetch!(:body)
    nodes = admin_req(:get, "/v1/admin/cluster/nodes") |> expect_status(200) |> Map.fetch!(:body)

    assert is_map(stats)
    assert is_list(nodes)
  end

  defp admin_req(method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: base() <> path,
        headers: [{"authorization", "Bearer " <> @admin_token}]
      ] ++ opts
    )
  end

  defp tenant_req(method, path, opts \\ []) do
    key = Process.get(:test_tenant_key)

    Req.request!(
      [method: method, url: base() <> path, headers: [{"authorization", "Bearer " <> key}]] ++
        opts
    )
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp base, do: SalixWeb.Application.base_url()
end
