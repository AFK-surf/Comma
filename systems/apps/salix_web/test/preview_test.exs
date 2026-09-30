defmodule SalixWeb.PreviewTest do
  @moduledoc """
  publish_html_preview (`SalixAgent.Tools.Preview`) willow-parity end to end:
  the tool writes a REAL website entrypoint under
  `/.salix/websites/{site}/index.html` (vfs_write event), returns willow's
  JSON output object with the canonical hosted-site URL
  `{scheme}://{site}-{base32-agent-id}.{sites-domain}/`, and the published
  page is then served by the public host-based site server WITHOUT auth.
  Against the Fake S3 backend.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.SiteId
  alias SalixAgent.Tools.Preview
  alias SalixAgent.AgentWorkspace

  @html "<!doctype html><html><body><h1>salix preview</h1></body></html>"
  @domain "salix.localhost"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    prev_domain = Application.get_env(:salix_agent, :sites_domain)
    prev_port = Application.get_env(:salix_agent, :sites_port)
    Application.put_env(:salix_agent, :sites_domain, @domain)
    # Pin the port off: URL assertions here stay port-less; the sites_port
    # suffix behavior is covered by SiteIdTest.
    Application.put_env(:salix_agent, :sites_port, nil)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :sites_domain, prev_domain)
      Application.put_env(:salix_agent, :sites_port, prev_port)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp seed!(agent, path, content) do
    {:ok, ev} = AgentWorkspace.prepare_write(agent, path, content)
    commit_workspace!(agent, "preview-seed:#{path}", [ev])
    :ok
  end

  defp http_get(host, path) do
    port = SalixWeb.Application.http_port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok =
      :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")

    resp = recv_all(sock, [])
    :gen_tcp.close(sock)
    [head, body] = String.split(resp, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    body =
      if headers["transfer-encoding"] == "chunked" do
        dechunk(body, [])
      else
        body
      end

    {String.to_integer(status), headers, body}
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, [acc | data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp dechunk(data, acc) do
    case String.split(data, "\r\n", parts: 2) do
      [size_hex, rest] ->
        case String.to_integer(String.trim(size_hex), 16) do
          0 ->
            IO.iodata_to_binary(acc)

          size ->
            <<chunk::binary-size(^size), "\r\n", rest2::binary>> = rest
            dechunk(rest2, [acc | chunk])
        end

      _ ->
        IO.iodata_to_binary(acc)
    end
  end

  test "publish inline html → hosted-site URL → public host-based GET", %{agent: a} do
    {output, [event]} =
      Preview.publish_html_preview(
        %{"html" => @html, "site_name" => "My Demo App", "title" => "Demo"},
        %{agent_id: a, tool_call_id: "call-1"}
      )

    commit_workspace!(a, "preview-publish-inline", [event])

    # Sanitized DNS-label site name; a real vfs_write entrypoint event.
    assert event["type"] == "vfs_write"
    assert event["path"] == "/.salix/websites/my-demo-app/index.html"

    decoded = Jason.decode!(output)
    {:ok, encoded} = SiteId.encode(a)

    assert decoded == %{
             "published_preview" => true,
             "url" => "http://my-demo-app-#{encoded}.#{@domain}/",
             "site_name" => "my-demo-app",
             "entrypoint_path" => "/",
             "vfs_path" => "/.salix/websites/my-demo-app/index.html",
             "mime_type" => "text/html; charset=utf-8",
             "verified_status" => "ok"
           }

    # The published site is served on the {site}-{b32}.{domain} host with NO
    # Authorization header despite the configured test api_token.
    {status, headers, body} = http_get("my-demo-app-#{encoded}.#{@domain}", "/")
    assert status == 200
    assert headers["content-type"] =~ "text/html"
    assert headers["cache-control"] == "no-cache"
    assert body =~ "salix preview"
  end

  test "publish from source_path; site name defaults from the file basename", %{agent: a} do
    seed!(a, "/demo/Landing Page.html", @html)

    {output, [event]} =
      Preview.publish_html_preview(
        %{"source_path" => "/demo/Landing Page.html"},
        %{agent_id: a, tool_call_id: "toolu_99"}
      )

    assert event["path"] == "/.salix/websites/landing-page/index.html"
    assert Jason.decode!(output)["site_name"] == "landing-page"
  end

  test "source_root publishes one site tree and a same-name update snapshots the old tree", %{
    agent: a
  } do
    work_root = "/.salix/websites/stable-site/_work"
    seed!(a, work_root <> "/v1/index.html", "<html><body>version one</body></html>")
    seed!(a, work_root <> "/v1/assets/app.css", "body { color: red; }")
    seed!(a, work_root <> "/v1/old.js", "console.log('old')")

    {first_output, first_events} =
      Preview.publish_html_preview(
        %{"source_root" => work_root <> "/v1", "site_name" => "Stable Site"},
        %{agent_id: a, tool_call_id: "publish-v1"}
      )

    commit_workspace!(a, "preview-publish-tree-v1", first_events)
    first = Jason.decode!(first_output)

    assert first["site_name"] == "stable-site"
    refute Map.has_key?(first, "backup_version")

    assert {:ok, "<html><body>version one</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/index.html")

    assert {:ok, "body { color: red; }"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/assets/app.css")

    seed!(a, work_root <> "/v2/index.html", "<html><body>version two</body></html>")
    seed!(a, work_root <> "/v2/assets/app.css", "body { color: blue; }")
    seed!(a, work_root <> "/v2/new.js", "console.log('new')")

    {second_output, second_events} =
      Preview.publish_html_preview(
        %{"source_root" => work_root <> "/v2", "site_name" => "stable-site"},
        %{agent_id: a, tool_call_id: "publish-v2"}
      )

    second = Jason.decode!(second_output)
    assert second["url"] == first["url"]
    assert second["site_name"] == first["site_name"]
    assert second["backup_version"] == "v0001"

    # The tool returns one atomic workspace batch; live files and the backup do
    # not change until that batch commits.
    assert {:ok, "<html><body>version one</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/index.html")

    assert {:error, :not_found} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/_versions/v0001/index.html")

    commit_workspace!(a, "preview-publish-tree-v2", second_events)

    assert {:ok, "<html><body>version two</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/index.html")

    assert {:ok, "body { color: blue; }"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/assets/app.css")

    assert {:ok, "console.log('new')"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/new.js")

    assert {:error, :not_found} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/old.js")

    assert {:ok, "<html><body>version one</body></html>"} =
             AgentWorkspace.read(
               a,
               "/.salix/websites/stable-site/_versions/v0001/index.html"
             )

    assert {:ok, "console.log('old')"} =
             AgentWorkspace.read(a, "/.salix/websites/stable-site/_versions/v0001/old.js")
  end

  test "inline same-name update snapshots the complete site and preserves assets", %{agent: a} do
    seed!(a, "/.salix/websites/docs/index.html", "<html><body>old</body></html>")
    seed!(a, "/.salix/websites/docs/app.js", "old asset")

    {output, events} =
      Preview.publish_html_preview(
        %{"html" => "<html><body>new</body></html>", "site_name" => "docs"},
        %{agent_id: a, tool_call_id: "inline-update"}
      )

    assert Jason.decode!(output)["backup_version"] == "v0001"
    commit_workspace!(a, "preview-inline-update", events)

    assert {:ok, "<html><body>new</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/index.html")

    assert {:ok, "old asset"} = AgentWorkspace.read(a, "/.salix/websites/docs/app.js")

    assert {:ok, "<html><body>old</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0001/index.html")

    assert {:ok, "old asset"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0001/app.js")
  end

  test "an unchanged publish does not create another version", %{agent: a} do
    seed!(a, "/.salix/websites/docs/index.html", @html)

    {output, events} =
      Preview.publish_html_preview(
        %{"html" => @html, "site_name" => "docs"},
        %{agent_id: a, tool_call_id: "unchanged"}
      )

    refute Map.has_key?(Jason.decode!(output), "backup_version")
    assert events == []
  end

  test "a historical source_root rolls back through the same publishing entrypoint", %{agent: a} do
    seed!(a, "/.salix/websites/docs/index.html", "<html><body>current</body></html>")
    seed!(a, "/.salix/websites/docs/current.js", "current")
    seed!(a, "/.salix/websites/docs/_versions/v0001/index.html", "<html>old</html>")
    seed!(a, "/.salix/websites/docs/_versions/v0001/old.js", "old")

    {output, events} =
      Preview.publish_html_preview(
        %{
          "source_root" => "/.salix/websites/docs/_versions/v0001",
          "site_name" => "docs"
        },
        %{agent_id: a, tool_call_id: "rollback"}
      )

    assert Jason.decode!(output)["backup_version"] == "v0002"
    commit_workspace!(a, "preview-rollback", events)

    assert {:ok, "<html>old</html>"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/index.html")

    assert {:ok, "old"} = AgentWorkspace.read(a, "/.salix/websites/docs/old.js")
    assert {:error, :not_found} = AgentWorkspace.read(a, "/.salix/websites/docs/current.js")

    assert {:ok, "<html><body>current</body></html>"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0002/index.html")
  end

  test "automatic history retains the newest twenty versions", %{agent: a} do
    seed!(a, "/.salix/websites/docs/index.html", "<html>current</html>")

    for version <- 1..20 do
      name = version |> Integer.to_string() |> String.pad_leading(4, "0")
      seed!(a, "/.salix/websites/docs/_versions/v#{name}/index.html", "version #{version}")
    end

    {output, events} =
      Preview.publish_html_preview(
        %{"html" => "<html>next</html>", "site_name" => "docs"},
        %{agent_id: a, tool_call_id: "retention"}
      )

    assert Jason.decode!(output)["backup_version"] == "v0021"
    commit_workspace!(a, "preview-retention", events)

    assert {:error, :not_found} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0001/index.html")

    assert {:ok, "version 2"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0002/index.html")

    assert {:ok, "<html>current</html>"} =
             AgentWorkspace.read(a, "/.salix/websites/docs/_versions/v0021/index.html")
  end

  test "tool validation mirrors willow", %{agent: a} do
    seed!(a, "/empty.html", "   ")
    ctx = %{agent_id: a, tool_call_id: "call-x"}

    # neither html nor an absolute source_path/source_root
    assert_raise RuntimeError,
                 ~r/html, an absolute source_path, or an absolute source_root/,
                 fn ->
                   Preview.publish_html_preview(%{}, ctx)
                 end

    assert_raise RuntimeError, ~r/html or an absolute source_path is required/, fn ->
      Preview.publish_html_preview(%{"source_path" => "page.html"}, ctx)
    end

    # nonexistent source file
    assert_raise RuntimeError, ~r/no such file/, fn ->
      Preview.publish_html_preview(%{"source_path" => "/nope.html"}, ctx)
    end

    assert_raise RuntimeError, ~r/source_root does not contain index.html/, fn ->
      Preview.publish_html_preview(%{"source_root" => "/nope"}, ctx)
    end

    # empty content (willow: "html content is empty")
    assert_raise RuntimeError, ~r/html content is empty/, fn ->
      Preview.publish_html_preview(%{"source_path" => "/empty.html"}, ctx)
    end

    # data: URLs are not publishable previews
    assert_raise RuntimeError, ~r/data:text\/html URLs are not publishable/, fn ->
      Preview.publish_html_preview(%{"html" => "data:text/html,<h1>hi</h1>"}, ctx)
    end

    # unconfigured sites domain → willow's exact error
    Application.put_env(:salix_agent, :sites_domain, nil)

    assert_raise RuntimeError, ~r/agent website domain is not configured/, fn ->
      Preview.publish_html_preview(%{"html" => @html}, ctx)
    end

    Application.put_env(:salix_agent, :sites_domain, @domain)
  end

  test "site-name fallback chain: title → basename → tool call id → preview", %{agent: a} do
    ctx = %{agent_id: a, tool_call_id: "toolu_AB12"}

    {out, _} = Preview.publish_html_preview(%{"html" => @html, "title" => "Fancy Title!"}, ctx)
    assert Jason.decode!(out)["site_name"] == "fancy-title"

    {out, _} = Preview.publish_html_preview(%{"html" => @html}, ctx)
    assert Jason.decode!(out)["site_name"] == "toolu-ab12"

    {out, _} =
      Preview.publish_html_preview(%{"html" => @html}, %{ctx | tool_call_id: "!!!"})

    assert Jason.decode!(out)["site_name"] == "preview"
  end

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} = AgentWorkspace.seed_operation(agent, operation_id, %{}, events)
  end
end
