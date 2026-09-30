defmodule BridgeForTeamsWeb.MacMiniInstallWrapperTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Orgs
  alias BridgeForTeamsWeb.DashboardEndpoint

  setup do
    {:ok, org} =
      Orgs.create_org(%{"name" => "Org", "slug" => "org-#{System.unique_integer([:positive])}"})

    %{org: org}
  end

  test "wrapper endpoint returns a no-store executable failure for a missing code", %{org: org} do
    conn =
      build_conn(:get, "/v1/orgs/#{org.id}/runners/install.sh")
      |> put_req_header("x-forwarded-proto", "https")
      |> DashboardEndpoint.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert ["nosniff"] == get_resp_header(conn, "x-content-type-options")
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/x-shellscript"

    {output, status} = execute_response(conn.resp_body)
    assert status != 0
    refute output =~ "bft_"
  end

  test "wrapper endpoint does not return HTML for an invalid code", %{org: org} do
    conn =
      build_conn(:get, "/v1/orgs/#{org.id}/runners/install.sh?code=invalid")
      |> put_req_header("x-forwarded-proto", "https")
      |> DashboardEndpoint.call([])

    {_output, status} = execute_response(conn.resp_body)
    assert conn.status == 200
    assert status != 0
  end

  defp execute_response(script) do
    root =
      Path.join(System.tmp_dir!(), "bft-wrapper-response-#{System.unique_integer([:positive])}")

    path = Path.join(root, "response.sh")
    File.mkdir_p!(root)

    try do
      File.write!(path, script)
      File.chmod!(path, 0o755)
      System.cmd("sh", [path], stderr_to_stdout: true)
    after
      File.rm_rf!(root)
    end
  end
end
