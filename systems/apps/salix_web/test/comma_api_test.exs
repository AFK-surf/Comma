defmodule SalixWeb.CommaApiTest do
  use SystemsClock.Case, async: false

  @admin_token "test-token"

  setup do
    prev_api_token = SystemsRuntime.get_env(:salix_web, :api_token)
    SystemsRuntime.put_env(:salix_web, :api_token, @admin_token)

    on_exit(fn ->
      if prev_api_token do
        SystemsRuntime.put_env(:salix_web, :api_token, prev_api_token)
      else
        SystemsRuntime.delete_env(:salix_web, :api_token)
      end
    end)

    :ok
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

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp base, do: SalixWeb.Application.base_url()
end
