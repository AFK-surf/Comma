defmodule SalixWeb.SiteServingTest do
  @moduledoc """
  The Salix website-hosting surface, end to end over real HTTP against the live
  Bandit server (Fake S3 backend):

    * host-based public static serving (`{site}-{b32-agent-id}.{domain}`):
      index resolution, directory indexes, the preview entrypoint, HTML error
      pages, `/_api.json` blocking, traversal rejection, MIME/cache headers,
      `If-Modified-Since` 304s, favicon/og/twitter HTML decoration with
      thumbnail probing
    * `/_api/` site APIs: `_api.json` gating, CORS, bearer auth, storage
      rules, document CRUD + list paging + the 10-namespace cap, and the
      LLM proxy (sync + SSE streaming + rate limiting + billing) against a
      mock OpenAI-compatible provider
    * tenant API URLs flipping to the subdomain form when a sites domain is
      configured
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixAgent.SiteId
  alias SalixAgent.AgentWorkspace

  @domain "salix.localhost"

  defmodule CapturingBrowser do
    def screenshot(_settings, "browser-token", url, size) do
      {test, result} = SystemsRuntime.PersistentTerm.get({__MODULE__, :capture})
      SystemsRuntime.Proc.send(test, {:captured, url, size})
      result
    end
  end

  defmodule DenyingStorageAuthorizer do
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :site_storage_authorization_test_pid),
        {
          :site_storage_authorize,
          attrs
        }
      )

      {:error, {:billing_unavailable, %{allowed?: false, reason: "insufficient_credits"}}}
    end
  end

  defmodule AllowingStorageAuthorizer do
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :site_storage_authorization_test_pid),
        {
          :site_storage_authorize,
          attrs
        }
      )

      :ok
    end
  end

  defmodule MockProvider do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}, nil) do
        SystemsRuntime.Proc.send(pid, {:provider_request, req})
      end

      if req["stream"] == true do
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        chunks = [
          %{
            "id" => "s1",
            "object" => "chat.completion.chunk",
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "Hel"}, "finish_reason" => nil}
            ]
          },
          %{
            "id" => "s1",
            "object" => "chat.completion.chunk",
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "lo"}, "finish_reason" => "stop"}
            ]
          },
          %{
            "id" => "s1",
            "object" => "chat.completion.chunk",
            "choices" => [],
            "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 2, "total_tokens" => 9}
          }
        ]

        conn =
          Enum.reduce(chunks, conn, fn c, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(c) <> "\n\n")
            conn
          end)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
      else
        resp = %{
          "id" => "resp-1",
          "object" => "chat.completion",
          # extraneous provider fields willow's ChatResponse projection drops:
          "created" => 1_700_000_000,
          "model" => req["model"],
          "system_fingerprint" => "fp",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{
                "role" => "assistant",
                "content" => "model=#{req["model"]} max_tokens=#{req["max_tokens"]}"
              },
              "finish_reason" => "stop",
              "logprobs" => nil
            }
          ],
          "usage" => %{
            "prompt_tokens" => 10,
            "completion_tokens" => 5,
            "total_tokens" => 15,
            "prompt_tokens_details" => %{"cached_tokens" => 4}
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "mock: not found")
    end
  end

  defmodule MeteringFake do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :site_llm_metering_test_pid),
        {:site_meter_before, fact}
      )

      :ok
    end

    @impl true
    def after_llm_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :site_llm_metering_test_pid),
        {:site_meter_after, fact}
      )

      :ok
    end
  end

  setup do
    Salix.App.configure()
    SalixAgent.TestSupport.stop_all_agents()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    prev_domain = SystemsRuntime.get_env(:salix_agent, :sites_domain)
    prev_port = SystemsRuntime.get_env(:salix_agent, :sites_port)
    prev_metering = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    prev_metering_pid = SystemsRuntime.get_env(:salix_web, :site_llm_metering_test_pid)
    prev_storage_authorization = SystemsRuntime.get_env(:salix_agent, :storage_authorization_mod)

    prev_storage_authorization_pid =
      SystemsRuntime.get_env(:salix_web, :site_storage_authorization_test_pid)

    SystemsRuntime.put_env(:salix_agent, :sites_domain, @domain)
    # Pin the port off: URL assertions here stay port-less; the sites_port
    # suffix behavior is covered by SiteIdTest.
    SystemsRuntime.put_env(:salix_agent, :sites_port, nil)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, MeteringFake)
    SystemsRuntime.put_env(:salix_web, :site_llm_metering_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(
      :salix_web,
      :site_storage_authorization_test_pid,
      SystemsRuntime.Proc.self()
    )

    SystemsRuntime.PersistentTerm.put({MockProvider, :test_pid}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      SystemsRuntime.put_env(:salix_agent, :sites_domain, prev_domain)
      SystemsRuntime.put_env(:salix_agent, :sites_port, prev_port)
      restore_env(:salix_agent, :llm_metering_mod, prev_metering)
      restore_env(:salix_web, :site_llm_metering_test_pid, prev_metering_pid)
      restore_env(:salix_agent, :storage_authorization_mod, prev_storage_authorization)

      restore_env(
        :salix_web,
        :site_storage_authorization_test_pid,
        prev_storage_authorization_pid
      )

      SystemsRuntime.PersistentTerm.erase({MockProvider, :test_pid})
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Site serving"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Site serving"}, tenant["tenant_id"])

    {:ok, agent_record} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Site agent"},
        tenant["tenant_id"]
      )

    agent = agent_record["agent_id"]
    {:ok, encoded} = SiteId.encode(agent)
    {:ok, agent: agent, encoded: encoded}
  end

  # ---- helpers ----

  defp write_files!(agent, files) do
    events =
      Enum.map(files, fn {path, content} ->
        {:ok, ev} = AgentWorkspace.prepare_write(agent, path, content)
        ev
      end)

    assert {:ok, _} =
             AgentWorkspace.seed_operation(
               agent,
               "site-test:" <> unique_operation_suffix(),
               %{},
               events
             )
  end

  defp write_stream_file!(agent, path, stream) do
    {:ok, ev} = AgentWorkspace.prepare_write_stream(agent, path, stream)

    assert {:ok, _} =
             AgentWorkspace.seed_operation(
               agent,
               "site-stream-test:" <> unique_operation_suffix(),
               %{},
               [ev]
             )
  end

  defp write_file_at!(agent, path, content, modified_at) do
    {:ok, event} = AgentWorkspace.prepare_write(agent, path, content)
    event = Map.put(event, "modified_at", modified_at)

    assert {:ok, _} =
             AgentWorkspace.seed_operation(
               agent,
               "site-test:" <> unique_operation_suffix(),
               %{},
               [event]
             )
  end

  defp unique_operation_suffix,
    do: SystemsRuntime.Proc.unique_integer([:positive]) |> Integer.to_string()

  defp site_host(site, encoded), do: "#{site}-#{encoded}.#{@domain}"

  describe "lookup_agent/1 (host-decoded id -> stored agent)" do
    test "resolves a canonical agent id from its base32 subdomain label" do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(agent_id)

      # Encode the prefixed id, then decode the label as the endpoint does.
      {:ok, encoded} = SiteId.encode(agent_id)
      {:ok, decoded} = SiteId.decode(encoded)

      assert {:ok, ^agent_id, %{}} = SalixWeb.Site.lookup_agent(decoded)
    end
  end

  defp request(method, host, path, headers \\ [], body \\ nil) do
    port = SalixWeb.Application.http_port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    header_lines =
      [{"Host", host}, {"Connection", "close"} | headers] ++
        if(body, do: [{"Content-Length", Integer.to_string(byte_size(body))}], else: [])

    req =
      "#{method} #{path} HTTP/1.1\r\n" <>
        Enum.map_join(header_lines, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "\r\n" <> (body || "")

    :ok = :gen_tcp.send(sock, req)
    resp = recv_all(sock, [])
    :gen_tcp.close(sock)

    [head, raw_body] = String.split(resp, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    resp_headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    body =
      if resp_headers["transfer-encoding"] == "chunked",
        do: dechunk(raw_body, []),
        else: raw_body

    %{status: String.to_integer(status), headers: resp_headers, body: body}
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
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

  defp http_date(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp fixed_stream(total, chunk) when total >= 0 and is_binary(chunk) and byte_size(chunk) > 0 do
    Stream.resource(
      fn -> total end,
      fn
        0 ->
          {:halt, 0}

        remaining ->
          size = min(remaining, byte_size(chunk))
          {[binary_part(chunk, 0, size)], remaining - size}
      end,
      fn _ -> :ok end
    )
  end

  # ---- static serving ----

  test "host-based site traffic emits bounded common HTTP telemetry", %{
    agent: agent,
    encoded: encoded
  } do
    write_files!(agent, [
      {"/.salix/websites/docs/index.html", "<html><body>instrumented</body></html>"}
    ])

    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma_system, :http, :stop],
        fn event, measurements, metadata, _ ->
          SystemsRuntime.Proc.send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    assert request("GET", site_host("docs", encoded), "/").status == 200

    settle_receive({[:comma_system, :http, :stop], %{duration: duration}, metadata})
    assert duration >= 0
    assert metadata.route == "/_site/content"
    assert metadata.endpoint == :salix_api
  end

  test "host-based static serving: resolution, headers, errors", %{
    agent: a,
    encoded: e
  } do
    write_files!(a, [
      {"/.salix/websites/docs/index.html",
       "<html><head><title>Docs</title></head><body>salix docs</body></html>"},
      {"/.salix/websites/docs/guides/index.html", "<html><body>guides index</body></html>"},
      {"/.salix/websites/docs/app.wasm", <<0, "asm">>},
      {"/.salix/websites/docs/_versions/v0001/index.html", "<html>old version</html>"},
      {"/.salix/websites/docs/_work/draft.html", "<html>unfinished draft</html>"},
      {"/.salix/websites/snake/preview/index.html", "<html><body>snake preview</body></html>"}
    ])

    docs = site_host("docs", e)

    # Root index and headers.
    resp = request("GET", docs, "/")
    assert resp.status == 200
    assert resp.body =~ "salix docs"
    assert resp.headers["content-type"] == "text/html; charset=utf-8"
    assert resp.headers["cache-control"] == "no-cache"
    refute resp.headers["last-modified"]
    refute resp.headers["etag"]

    # Bare directory URL resolves to its index.html.
    resp = request("GET", docs, "/guides")
    assert resp.status == 200
    assert resp.body =~ "guides index"

    # Stable asset URLs revalidate after same-site updates.
    resp = request("GET", docs, "/app.wasm")
    assert resp.status == 200
    assert resp.headers["content-type"] == "application/wasm"
    assert resp.headers["cache-control"] == "no-cache"
    assert resp.headers["etag"]

    # Preview entrypoint at the site root.
    assert request("GET", site_host("snake", e), "/").body =~ "snake preview"

    # HTML error pages.
    resp = request("GET", docs, "/missing")
    assert resp.status == 404

    assert resp.body ==
             "<!doctype html><html><head><title>404 Not found</title></head><body><h1>404 Not found</h1></body></html>"

    assert request("GET", site_host("ghost", e), "/").status == 404

    # Unknown agent id (valid base32) → "Site not found".
    {:ok, other} = SiteId.encode(SalixAgent.TestSupport.new_agent_id())
    resp = request("GET", site_host("docs", other), "/")
    assert resp.status == 404
    assert resp.body =~ "Site not found"

    # Reserved /_* files and directories are blocked from static serving.
    assert request("GET", docs, "/_api.json").status == 404
    assert request("GET", docs, "/_versions/v0001/index.html").status == 404
    assert request("GET", docs, "/_work/draft.html").status == 404

    # Path traversal → 400 Invalid path.
    resp = request("GET", docs, "/a..b")
    assert resp.status == 400
    assert resp.body =~ "Invalid path"
  end

  test "host-based static serving streams files beyond the full-read cap", %{
    agent: a,
    encoded: e
  } do
    size = SalixStore.Blob.max_bytes() + 1
    docs = site_host("docs", e)
    chunk = String.duplicate("S", 256 * 1024)

    write_stream_file!(a, "/.salix/websites/docs/large.bin", fixed_stream(size, chunk))
    write_stream_file!(a, "/.salix/websites/docs/large.html", fixed_stream(size, chunk))

    resp = request("GET", docs, "/large.bin")
    assert resp.status == 200
    assert resp.headers["content-length"] == Integer.to_string(size)
    refute Map.has_key?(resp.headers, "transfer-encoding")
    assert byte_size(resp.body) == size

    resp = request("GET", docs, "/large.html")
    assert resp.status == 200
    assert resp.headers["content-type"] == "text/html; charset=utf-8"
    assert resp.headers["content-length"] == Integer.to_string(size)
    refute Map.has_key?(resp.headers, "transfer-encoding")
    assert byte_size(resp.body) == size
  end

  test "If-Modified-Since returns 304 for byte-stable assets", %{agent: a, encoded: e} do
    write_files!(a, [{"/.salix/websites/docs/app.css", "body { color: red; }"}])
    docs = site_host("docs", e)
    now = SystemsClock.system_time(:second)

    resp = request("GET", docs, "/app.css", [{"If-Modified-Since", http_date(now + 60)}])
    assert resp.status == 304
    assert resp.body == ""

    resp = request("GET", docs, "/app.css", [{"If-Modified-Since", http_date(now - 3600)}])
    assert resp.status == 200
  end

  test "same-URL asset updates revalidate by content hash", %{agent: a, encoded: e} do
    path = "/.salix/websites/docs/app.css"
    docs = site_host("docs", e)
    modified_at = SystemsClock.system_time(:second)

    write_file_at!(a, path, "body { color: red; }", modified_at)
    first = request("GET", docs, "/app.css")

    assert first.status == 200
    assert first.body == "body { color: red; }"
    assert first.headers["cache-control"] == "no-cache"
    assert old_etag = first.headers["etag"]

    # Keep the timestamp identical to prove ETag precedence prevents a stale
    # If-Modified-Since 304 when a stable asset URL changes within one second.
    write_file_at!(a, path, "body { color: blue; }", modified_at)

    second =
      request("GET", docs, "/app.css", [
        {"If-None-Match", old_etag},
        {"If-Modified-Since", http_date(modified_at)}
      ])

    assert second.status == 200
    assert second.body == "body { color: blue; }"
    assert second.headers["cache-control"] == "no-cache"
    assert second.headers["etag"] != old_etag

    unchanged =
      request("GET", docs, "/app.css", [{"If-None-Match", second.headers["etag"]}])

    assert unchanged.status == 304
    assert unchanged.body == ""
    assert unchanged.headers["cache-control"] == "no-cache"
    assert unchanged.headers["etag"] == second.headers["etag"]
  end

  test "HTML decoration: tenant favicon + og:image from site thumbnail", %{
    agent: a,
    encoded: e
  } do
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(a)

    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" =>
          Jason.encode!(%{
            "favicon_url" => "https://cdn.example.test/favicon.ico",
            "default_og_image_url" => "https://cdn.example.test/default-og.png"
          })
      })

    write_files!(a, [
      {"/.salix/websites/docs/index.html",
       "<html><head><title>d</title></head><body>x</body></html>"},
      {"/.salix/websites/docs/thumbnail.png", "png-bytes"},
      {"/.salix/websites/plain/index.html",
       ~s(<html><head><meta property="og:image" content="https://own.example/og.png"></head></html>)}
    ])

    docs = site_host("docs", e)
    resp = request("GET", docs, "/")
    assert resp.body =~ ~s(<link rel="icon" href="https://cdn.example.test/favicon.ico">)
    # Site-local thumbnail wins over the tenant default, absolute on this host.
    assert resp.body =~ ~s(<meta property="og:image" content="http://#{docs}/thumbnail.png">)
    assert resp.body =~ ~s(<meta name="twitter:image" content="http://#{docs}/thumbnail.png">)
    assert resp.body =~ ~s(<meta name="twitter:card" content="summary_large_image">)

    # Page-authored og:image is preserved, never overridden.
    resp = request("GET", site_host("plain", e), "/")
    assert resp.body =~ "https://own.example/og.png"
    refute resp.body =~ "cdn.example.test/default-og.png"
  end

  describe "default share image" do
    setup %{agent: a} do
      previous = SystemsRuntime.get_env(:salix_agent, :browser_provider)
      SystemsRuntime.put_env(:salix_agent, :browser_provider, CapturingBrowser)
      capture_returns({:ok, "jpeg-bytes"})

      on_exit(fn ->
        # A page view's capture must end before the outer setup restores its env.
        for pid <- SystemsRuntime.TaskSupervisor.children(SalixWeb.SiteOgImage.Supervisor) do
          ref = SystemsRuntime.Proc.monitor(pid)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          end
        end

        restore_env(:salix_agent, :browser_provider, previous)
        SystemsRuntime.PersistentTerm.erase({CapturingBrowser, :capture})
      end)

      {:ok, tenant_id: SalixStore.Ids.tenant_id_from_agent!(a)}
    end

    # A page view's capture reports the screenshot before it stores it, so a test
    # reads the image only after the capture task ends.
    defp await_captures do
      for pid <- SystemsRuntime.TaskSupervisor.children(SalixWeb.SiteOgImage.Supervisor) do
        ref = SystemsRuntime.Proc.monitor(pid)
        settle_receive({:DOWN, ^ref, _, _, _})
      end

      :ok
    end

    defp capture_returns(result) do
      SystemsRuntime.PersistentTerm.put(
        {CapturingBrowser, :capture},
        {SystemsRuntime.Proc.self(), result}
      )
    end

    defp enable_browser!(tenant_id) do
      :ok =
        unwrap_ok(
          SalixStore.BrowserSettings.put(tenant_id, %{
            "mode" => "override",
            "account_id" => String.duplicate("a", 32),
            "api_token" => "browser-token"
          })
        )
    end

    defp unwrap_ok({:ok, :ok}), do: :ok

    defp og_image_path(body) do
      [_, url] = Regex.run(~r/<meta property="og:image" content="http:\/\/[^\/]+([^"]+)">/, body)
      url
    end

    test "a page with no image gets the tags every link preview reads", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)

      write_files!(a, [
        {"/.salix/websites/docs/index.html",
         ~s(<html><head><title>Docs &amp; "guides"</title>) <>
           ~s(<meta content='About the docs' name="description"></head><body>x</body></html>)}
      ])

      docs = site_host("docs", e)
      resp = request("GET", docs, "/")
      path = og_image_path(resp.body)
      assert String.starts_with?(path, "/_og-image.jpg?v=")

      assert resp.body =~ ~s(<meta property="og:image:type" content="image/jpeg">)
      assert resp.body =~ ~s(<meta property="og:image:width" content="1200">)
      assert resp.body =~ ~s(<meta property="og:image:height" content="630">)
      assert resp.body =~ ~s(<meta property="og:title" content="Docs &amp; &quot;guides&quot;">)
      assert resp.body =~ ~s(<meta property="og:description" content="About the docs">)
      assert resp.body =~ ~s(<meta property="og:url" content="http://#{docs}/">)
      assert resp.body =~ ~s(<meta property="og:type" content="website">)
      assert resp.body =~ ~s(<meta name="twitter:image" content="http://#{docs}#{path}">)
      assert resp.body =~ ~s(<meta name="twitter:card" content="summary_large_image">)
    end

    test "a page view captures the home page once and the image reads the capture", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)
      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])

      docs = site_host("docs", e)
      path = og_image_path(request("GET", docs, "/").body)
      home = "http://#{docs}/"
      await_captures()
      assert_received {:captured, ^home, {1200, 630}}

      image = request("GET", docs, path)
      assert image.status == 200
      assert image.body == "jpeg-bytes"
      assert image.headers["content-type"] == "image/jpeg"
      assert image.headers["cache-control"] == "no-cache"

      unchanged = request("GET", docs, path, [{"If-None-Match", image.headers["etag"]}])
      assert unchanged.status == 304

      assert request("GET", docs, path).body == "jpeg-bytes"
      refute_received {:captured, _, _}
    end

    test "a publish replaces the image", %{agent: a, encoded: e, tenant_id: tenant_id} do
      enable_browser!(tenant_id)
      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])

      docs = site_host("docs", e)
      old_path = og_image_path(request("GET", docs, "/").body)
      await_captures()
      assert_received {:captured, _, _}
      assert request("GET", docs, old_path).body == "jpeg-bytes"

      capture_returns({:ok, "newer-jpeg"})
      SystemsClock.advance(60_001)
      write_files!(a, [{"/.salix/websites/docs/app.css", "body { color: red }"}])

      new_path = og_image_path(request("GET", docs, "/").body)
      assert new_path != old_path
      await_captures()
      assert_received {:captured, _, _}
      assert request("GET", docs, new_path).body == "newer-jpeg"
      refute_received {:captured, _, _}
    end

    test "a failed capture answers 503 and the site waits for its next window", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)
      capture_returns({:error, :browser_provider_unavailable})
      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])

      docs = site_host("docs", e)
      failed = request("GET", docs, "/_og-image.jpg")
      assert failed.status == 503
      assert failed.headers["retry-after"] == "60"
      assert_received {:captured, _, _}

      capture_returns({:ok, "jpeg-bytes"})
      SystemsClock.advance(60_001)
      assert request("GET", docs, "/_og-image.jpg").body == "jpeg-bytes"
    end

    test "a version that keeps failing stops capturing until the next publish", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)
      capture_returns({:error, :browser_provider_unavailable})
      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])
      docs = site_host("docs", e)

      for _attempt <- 1..3 do
        assert request("GET", docs, "/_og-image.jpg").status == 503
        assert_received {:captured, _, _}
        SystemsClock.advance(60_001)
      end

      assert request("GET", docs, "/_og-image.jpg").status == 503
      refute_received {:captured, _, _}

      capture_returns({:ok, "jpeg-bytes"})
      SystemsClock.advance(60_001)
      write_files!(a, [{"/.salix/websites/docs/app.css", "body { color: red }"}])
      assert request("GET", docs, "/_og-image.jpg").body == "jpeg-bytes"
    end

    test "a site without a home page names no screenshot", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)
      write_files!(a, [{"/.salix/websites/docs/guide/index.html", "<html><head></head></html>"}])

      refute request("GET", site_host("docs", e), "/guide/").body =~ "_og-image.jpg"
      refute_received {:captured, _, _}
    end

    test "an image the site or tenant chose is used, and nothing is captured", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)

      write_files!(a, [
        {"/.salix/websites/own/index.html",
         ~s(<html><head><meta property="og:image" content="https://own.example/og.png"></head></html>)},
        {"/.salix/websites/shot/index.html", "<html><head></head></html>"},
        {"/.salix/websites/shot/guide/index.html", "<html><head></head></html>"},
        {"/.salix/websites/shot/og-image.png", "png-bytes"}
      ])

      own = request("GET", site_host("own", e), "/")
      refute own.body =~ "_og-image.jpg"
      refute own.body =~ "og:url"

      shot = site_host("shot", e)
      subpage = request("GET", shot, "/guide/")
      assert subpage.body =~ ~s(<meta property="og:image" content="http://#{shot}/og-image.png">)
      refute subpage.body =~ "og:image:width"

      {:ok, _} =
        Salix.Control.Tenants.update(tenant_id, %{
          "config" =>
            Jason.encode!(%{"default_og_image_url" => "https://cdn.example.test/default.png"})
        })

      write_files!(a, [{"/.salix/websites/plain/index.html", "<html><head></head></html>"}])
      plain = request("GET", site_host("plain", e), "/")

      assert plain.body =~
               ~s(<meta property="og:image" content="https://cdn.example.test/default.png">)

      refute_received {:captured, _, _}
    end

    test "Browser Run limited to allowed domains names no screenshot", %{
      agent: a,
      encoded: e,
      tenant_id: tenant_id
    } do
      enable_browser!(tenant_id)

      {:ok, :ok} =
        SalixStore.BrowserSettings.put(tenant_id, %{
          "mode" => "override",
          "allowed_domains" => ["example.com"]
        })

      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])

      docs = site_host("docs", e)
      refute request("GET", docs, "/").body =~ "og:image"
      assert request("GET", docs, "/_og-image.jpg").status == 404
      refute_received {:captured, _, _}
    end

    test "without Browser Run a page names no screenshot", %{agent: a, encoded: e} do
      write_files!(a, [{"/.salix/websites/docs/index.html", "<html><head></head></html>"}])

      docs = site_host("docs", e)
      refute request("GET", docs, "/").body =~ "og:image"
      assert request("GET", docs, "/_og-image.jpg").status == 404
      refute_received {:captured, _, _}
    end
  end

  test "decorated HTML ignores source validators when tenant branding changes", %{
    agent: a,
    encoded: e
  } do
    tenant_id = SalixStore.Ids.tenant_id_from_agent!(a)
    html = "<html><head><title>d</title></head><body>x</body></html>"

    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" => Jason.encode!(%{"favicon_url" => "https://cdn.example.test/one.ico"})
      })

    write_files!(a, [{"/.salix/websites/docs/index.html", html}])
    docs = site_host("docs", e)

    first = request("GET", docs, "/")
    assert first.status == 200
    assert first.body =~ "https://cdn.example.test/one.ico"

    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" => Jason.encode!(%{"favicon_url" => "https://cdn.example.test/two.ico"})
      })

    source_etag = ~s("#{SalixStore.Crypto.hex(html)}")
    refreshed = request("GET", docs, "/", [{"If-None-Match", source_etag}])

    assert refreshed.status == 200
    assert refreshed.body =~ "https://cdn.example.test/two.ico"
    refute refreshed.headers["etag"]
  end

  test "tenant sites API returns subdomain URLs when the domain is configured", %{
    agent: a,
    encoded: e
  } do
    write_files!(a, [{"/.salix/websites/docs/index.html", "<html>ok</html>"}])

    {:ok, sites} = SalixAgent.Workspace.list_sites(a)
    assert [%{"name" => "docs", "url" => url}] = sites
    assert url == "http://docs-#{e}.#{@domain}"

    tenant_id = SalixStore.Ids.tenant_id_from_agent!(a)
    {:ok, hosted} = SalixAgent.Workspace.list_hosted_sites(tenant_id, limit: "10")
    assert Enum.any?(hosted["sites"], &(&1["agent_id"] == a and &1["url"] == url))
  end

  # ---- site APIs ----

  test "/_api/ is gated on _api.json", %{agent: a, encoded: e} do
    write_files!(a, [{"/.salix/websites/docs/index.html", "<html>ok</html>"}])
    docs = site_host("docs", e)

    resp = request("GET", docs, "/_api/documents")
    assert resp.status == 404
    assert resp.body =~ "Site API not configured"

    # CORS preflight short-circuits before the config check.
    resp = request("OPTIONS", docs, "/_api/documents", [{"Origin", "https://app.example"}])
    assert resp.status == 204
    assert resp.headers["access-control-allow-origin"] == "https://app.example"
    assert resp.headers["access-control-allow-methods"] == "GET, PUT, POST, DELETE, OPTIONS"
  end

  test "document storage: rules, CRUD, paging, auth, caps", %{agent: a, encoded: e} do
    api_config = %{
      "auth" => %{"bearer_tokens" => ["sekret"]},
      "storage" => %{
        "default_policy" => "deny",
        "rules" => [
          %{"key_prefix" => "public/", "operations" => ["read", "write", "list", "delete"]},
          %{"key_prefix" => "private/", "operations" => ["read"], "require_auth" => true},
          %{"key_prefix" => "small/", "operations" => ["write"], "max_value_size" => 64}
        ]
      }
    }

    write_files!(a, [
      {"/.salix/websites/docs/index.html", "<html>ok</html>"},
      {"/.salix/websites/docs/_api.json", Jason.encode!(api_config)}
    ])

    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]

    # List before any namespace exists → empty.
    resp = request("GET", docs, "/_api/documents?prefix=public/")
    assert resp.status == 200
    assert Jason.decode!(resp.body) == %{"data" => [], "has_more" => false}

    # Create.
    resp =
      request(
        "PUT",
        docs,
        "/_api/documents/public/a",
        json,
        Jason.encode!(%{"value" => %{"n" => 1}})
      )

    assert resp.status == 200
    doc = Jason.decode!(resp.body)
    assert %{"doc_id" => doc_id, "key" => "public/a", "value" => %{"n" => 1}} = doc
    created_at = doc["created_at"]
    assert is_integer(created_at)

    # Update preserves doc_id and created_at.
    resp =
      request(
        "PUT",
        docs,
        "/_api/documents/public/a",
        json,
        Jason.encode!(%{"value" => %{"n" => 2}})
      )

    updated = Jason.decode!(resp.body)
    assert updated["doc_id"] == doc_id
    assert updated["created_at"] == created_at
    assert updated["value"] == %{"n" => 2}

    # Read back.
    resp = request("GET", docs, "/_api/documents/public/a")
    assert Jason.decode!(resp.body)["value"] == %{"n" => 2}

    # Paging: 3 docs, limit 2 → has_more; `after` resumes.
    request("PUT", docs, "/_api/documents/public/b", json, Jason.encode!(%{"value" => 1}))
    request("PUT", docs, "/_api/documents/public/c", json, Jason.encode!(%{"value" => 2}))

    page = Jason.decode!(request("GET", docs, "/_api/documents?prefix=public/&limit=2").body)
    assert Enum.map(page["data"], & &1["key"]) == ["public/a", "public/b"]
    assert page["has_more"] == true

    page2 =
      Jason.decode!(
        request("GET", docs, "/_api/documents?prefix=public/&limit=2&after=public/b").body
      )

    assert Enum.map(page2["data"], & &1["key"]) == ["public/c"]
    assert page2["has_more"] == false

    # No matching rule → default deny.
    resp = request("GET", docs, "/_api/documents/zzz")
    assert resp.status == 403
    assert resp.body =~ "Access denied"

    # Rule without the op → 403 Operation not allowed.
    resp = request("PUT", docs, "/_api/documents/private/x", json, Jason.encode!(%{"value" => 1}))
    assert resp.status == 403
    assert resp.body =~ "Operation not allowed"

    # require_auth rule: 401 without bearer; with bearer → 404 (no doc yet).
    assert request("GET", docs, "/_api/documents/private/x").status == 401

    resp =
      request("GET", docs, "/_api/documents/private/x", [{"Authorization", "Bearer sekret"}])

    assert resp.status == 404
    assert resp.body =~ "Document not found"

    assert request("GET", docs, "/_api/documents/private/x", [{"Authorization", "Bearer wrong"}]).status ==
             401

    # Per-rule max_value_size → 413 (the cap applies to the request body).
    big = Jason.encode!(%{"value" => String.duplicate("x", 100)})
    resp = request("PUT", docs, "/_api/documents/small/big", json, big)
    assert resp.status == 413
    assert resp.body =~ "Value too large"

    # Body validation.
    assert request("PUT", docs, "/_api/documents/public/bad", json, "{nope").status == 400
    resp = request("PUT", docs, "/_api/documents/public/bad", json, Jason.encode!(%{"x" => 1}))
    assert resp.status == 400
    assert resp.body =~ "Value required"

    # Invalid document key (rule matching runs FIRST, willow order — so the
    # key must pass the storage rule to reach key validation).
    resp =
      request("PUT", docs, "/_api/documents/public/ba$d", json, Jason.encode!(%{"value" => 1}))

    assert resp.status == 400
    assert resp.body =~ "Invalid document key"

    # Delete.
    resp = request("DELETE", docs, "/_api/documents/public/a")
    assert Jason.decode!(resp.body) == %{"status" => "deleted"}
    assert request("DELETE", docs, "/_api/documents/public/a").status == 404
    assert request("GET", docs, "/_api/documents/public/a").status == 404

    # Unknown /_api/ path and wrong method.
    assert request("GET", docs, "/_api/nope").status == 404
    assert request("POST", docs, "/_api/documents/public/a", json, "{}").status == 405
  end

  test "document storage write and delete are blocked by billing authorization", %{
    agent: a,
    encoded: e
  } do
    {:ok, agent} = SalixAgent.Control.get(a)

    {:ok, _group} =
      Salix.Control.Groups.update(agent["group_id"], %{
        "billing_owner" => %{
          "billing_account_id" => "ba_site_docs_zero",
          "surface" => "bridge",
          "product_owner_type" => "organization",
          "product_owner_id" => "org_site_docs",
          "salix_tenant_id" => agent["tenant_id"],
          "salix_group_id" => agent["group_id"]
        }
      })

    api_config = %{
      "storage" => %{
        "default_policy" => "deny",
        "rules" => [
          %{"key_prefix" => "public/", "operations" => ["read", "write", "list", "delete"]}
        ]
      }
    }

    write_files!(a, [
      {"/.salix/websites/docs/index.html", "<html>ok</html>"},
      {"/.salix/websites/docs/_api.json", Jason.encode!(api_config)}
    ])

    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]
    SystemsRuntime.put_env(:salix_agent, :storage_authorization_mod, DenyingStorageAuthorizer)

    resp =
      request(
        "PUT",
        docs,
        "/_api/documents/public/blocked",
        json,
        Jason.encode!(%{"value" => 1})
      )

    assert resp.status == 402
    assert resp.body =~ "Billing unavailable"

    settle_receive(
      {:site_storage_authorize,
       %{
         agent_id: ^a,
         events: [%{"type" => "site_doc_namespace_write"}],
         billing_context: %{"billing_account_id" => "ba_site_docs_zero"}
       }}
    )

    assert {:error, :not_found} = SalixStore.S3.head(SalixStore.Keys.site_doc_namespaces(a))

    assert {:error, :not_found} =
             SalixStore.S3.head(SalixStore.Keys.site_doc(a, "docs", "public/blocked"))

    SystemsRuntime.put_env(:salix_agent, :storage_authorization_mod, AllowingStorageAuthorizer)

    assert request(
             "PUT",
             docs,
             "/_api/documents/public/deletable",
             json,
             Jason.encode!(%{"value" => 2})
           ).status == 200

    SystemsRuntime.put_env(:salix_agent, :storage_authorization_mod, DenyingStorageAuthorizer)
    resp = request("DELETE", docs, "/_api/documents/public/deletable")

    assert resp.status == 402
    assert resp.body =~ "Billing unavailable"

    settle_receive(
      {:site_storage_authorize,
       %{
         agent_id: ^a,
         events: [%{"type" => "site_doc_delete"}],
         billing_context: %{"billing_account_id" => "ba_site_docs_zero"}
       }}
    )

    assert {:ok, _} = SalixStore.S3.head(SalixStore.Keys.site_doc(a, "docs", "public/deletable"))
  end

  test "10-namespace cap across sites → 409", %{agent: a, encoded: e} do
    cfg =
      Jason.encode!(%{
        "storage" => %{
          "default_policy" => "allow"
        }
      })

    sites = for i <- 1..11, do: "site#{i}"
    write_files!(a, Enum.map(sites, &{"/.salix/websites/#{&1}/_api.json", cfg}))

    json = [{"Content-Type", "application/json"}]

    for site <- Enum.take(sites, 10) do
      resp =
        request(
          "PUT",
          site_host(site, e),
          "/_api/documents/k",
          json,
          Jason.encode!(%{"value" => 1})
        )

      assert resp.status == 200
    end

    resp =
      request(
        "PUT",
        site_host("site11", e),
        "/_api/documents/k",
        json,
        Jason.encode!(%{"value" => 1})
      )

    assert resp.status == 409
    assert resp.body =~ "too many site document namespaces"
  end

  # ---- LLM proxy ----

  defp setup_llm_agent(a, llm_config) do
    start_supervised!(
      {Bandit,
       plug: MockProvider,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: __MODULE__.MockServer]]}
    )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(__MODULE__.MockServer)

    # The Agent follows the platform model of its role.
    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "http://127.0.0.1:#{port}",
      "mock-model",
      %{"max_tokens" => 50}
    )

    write_files!(a, [
      {"/.salix/websites/docs/index.html", "<html>ok</html>"},
      {"/.salix/websites/docs/_api.json", Jason.encode!(%{"llm" => llm_config})}
    ])
  end

  test "LLM proxy: model forced from the agent model, max_tokens clamped, billing recorded", %{
    agent: a,
    encoded: e
  } do
    {:ok, agent} = SalixAgent.Control.get(a)

    {:ok, _group} =
      Salix.Control.Groups.update(agent["group_id"], %{
        "billing_owner" => %{
          "billing_account_id" => "ba_site",
          "surface" => "bridge",
          "product_owner_type" => "organization",
          "product_owner_id" => "org_site",
          "salix_tenant_id" => agent["tenant_id"],
          "salix_group_id" => agent["group_id"]
        }
      })

    setup_llm_agent(a, %{"enabled" => true})
    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]

    body =
      Jason.encode!(%{
        "model" => "attacker-chosen-model",
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "max_tokens" => 9_999
      })

    resp = request("POST", docs, "/_api/llm/chat", json, body)
    assert resp.status == 200

    # The provider saw the agent model and its clamped max_tokens.
    settle_receive({:provider_request, provider_req})
    assert provider_req["model"] == "mock-model"
    assert provider_req["max_tokens"] == 50
    assert provider_req["prompt_cache_key"] == a

    # Response is willow's ChatResponse projection (provider extras dropped).
    decoded = Jason.decode!(resp.body)

    assert decoded == %{
             "id" => "resp-1",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "model=mock-model max_tokens=50"
                 },
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15,
               "prompt_tokens_details" => %{"cached_tokens" => 4}
             }
           }

    settle_receive(
      {:site_meter_before,
       %{
         entrypoint: "site_llm",
         salix_agent_id: ^a,
         billing_account_id: "ba_site",
         group_id: group_id
       }}
    )

    assert group_id == agent["group_id"]

    settle_receive(
      {:site_meter_after,
       %{
         status: "ok",
         entrypoint: "site_llm",
         billing_account_id: "ba_site",
         model: "mock-model",
         usage: %{
           "prompt_tokens" => 10,
           "completion_tokens" => 5,
           "total_tokens" => 15,
           "cache_read_input_tokens" => 4
         }
       }}
    )

    # Validation: messages required.
    resp = request("POST", docs, "/_api/llm/chat", json, Jason.encode!(%{"messages" => []}))
    assert resp.status == 400
    assert resp.body =~ "Messages required"
  end

  test "LLM proxy: disabled / auth", %{agent: a, encoded: e} do
    setup_llm_agent(a, %{"enabled" => true, "require_auth" => true})

    write_files!(a, [
      {"/.salix/websites/off/_api.json", Jason.encode!(%{"llm" => %{"enabled" => false}})}
    ])

    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]
    body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

    # Disabled site.
    resp = request("POST", site_host("off", e), "/_api/llm/chat", json, body)
    assert resp.status == 404
    assert resp.body =~ "LLM API not enabled"

    # require_auth.
    assert request("POST", docs, "/_api/llm/chat", json, body).status == 401

    # _api.json bearer tokens are absent → any token fails.
    assert request(
             "POST",
             docs,
             "/_api/llm/chat",
             json ++ [{"Authorization", "Bearer nope"}],
             body
           ).status == 401
  end

  test "LLM proxy: rate limit sliding window → 429 + Retry-After", %{agent: a, encoded: e} do
    setup_llm_agent(a, %{"enabled" => true, "rate_limit_rpm" => 2})
    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]
    body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

    assert request("POST", docs, "/_api/llm/chat", json, body).status == 200
    assert request("POST", docs, "/_api/llm/chat", json, body).status == 200

    resp = request("POST", docs, "/_api/llm/chat", json, body)
    assert resp.status == 429
    assert resp.headers["retry-after"] == "60"
    assert resp.body =~ "Rate limit exceeded"
  end

  test "LLM proxy streaming: SSE forwarding with [DONE] + metering", %{agent: a, encoded: e} do
    setup_llm_agent(a, %{"enabled" => true})
    docs = site_host("docs", e)
    json = [{"Content-Type", "application/json"}]

    body =
      Jason.encode!(%{
        "messages" => [%{"role" => "user", "content" => "hi"}],
        "stream" => true
      })

    resp = request("POST", docs, "/_api/llm/chat", json, body)
    assert resp.status == 200
    assert resp.headers["content-type"] =~ "text/event-stream"

    events =
      resp.body
      |> String.split("\n\n", trim: true)
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

    assert List.last(events) == "[DONE]"

    deltas =
      events
      |> Enum.drop(-1)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map(fn chunk ->
        for c <- chunk["choices"], text = c["delta"]["content"], is_binary(text), do: text
      end)

    assert Enum.join(deltas, "") == "Hello"

    settle_receive(
      {:site_meter_after,
       %{
         status: "ok",
         usage: %{
           "prompt_tokens" => 7,
           "completion_tokens" => 2
         }
       }}
    )
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
