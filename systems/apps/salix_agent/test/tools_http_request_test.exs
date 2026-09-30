defmodule SalixAgent.ToolsHttpRequestTest do
  @moduledoc """
  `web.http_request` (`SalixAgent.Tools.HttpRequest`) against a Bandit mock
  API: the request the caller shapes (method, headers, query, body,
  credential placeholders) is what leaves; the response comes back as one
  JSON result; the destination policy refuses non-public hosts; and the same
  tool is reachable from the JavaScript host through `salix.call`.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.HttpRequest
  alias SalixAgent.{SessionToolDispatch, ToolDisclosure, Tools}

  defmodule MockApi do
    @moduledoc "Echo API; records what it saw for assertions."
    @behaviour Plug
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def last_request, do: __MODULE__ |> Agent.get(& &1) |> List.first()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      Agent.update(
        __MODULE__,
        &[
          %{
            method: conn.method,
            path: conn.request_path,
            query: conn.query_params,
            headers: Map.new(conn.req_headers),
            body: raw
          }
          | &1
        ]
      )

      case conn.request_path do
        "/echo" ->
          json(conn, 200, %{
            "method" => conn.method,
            "query" => conn.query_params,
            "headers" => conn.req_headers |> Map.new() |> Map.delete("authorization"),
            "json" => decode(raw),
            "raw" => raw
          })

        "/fail" ->
          json(conn, 503, %{"error" => "down"})

        "/redirect" ->
          conn |> put_resp_header("location", "/echo") |> send_resp(302, "")

        "/text" ->
          conn |> put_resp_content_type("text/plain") |> send_resp(200, "plain words")

        "/big" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"blob" => String.duplicate("x", 300 * 1024)}))

        "/slow" ->
          Process.sleep(3_000)
          json(conn, 200, %{"late" => true})

        "/repeat" ->
          conn
          |> prepend_resp_headers([{"x-many", "one"}, {"x-many", "two"}])
          |> send_resp(204, "")

        _ ->
          json(conn, 404, %{"error" => "not found"})
      end
    end

    defp json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end

    defp decode(""), do: nil

    defp decode(raw) do
      case Jason.decode(raw) do
        {:ok, decoded} -> decoded
        _ -> nil
      end
    end
  end

  defmodule OAuthStore do
    @moduledoc "One bound GitHub credential for the calling agent's group."
    def agent_oauth_context(_agent_id), do: {:ok, %{tenant: "tenant", group_id: "group"}}

    def bindings_for_group("group") do
      {:ok,
       [%{"provider" => "github", "alias" => "github", "connection_id" => "http-request-oauth"}]}
    end
  end

  setup do
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_private = Application.get_env(:salix_agent, :http_request_allow_private_hosts)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # The mock listens on loopback, which the destination policy refuses.
    Application.put_env(:salix_agent, :http_request_allow_private_hosts, true)
    start_supervised!(MockApi)

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(make_ref(), 20000)

        case start_supervised({Bandit, plug: MockApi, port: p, startup_log: false},
               id: {:bandit, p}
             ) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_backend)
      restore(:salix_agent, :http_request_allow_private_hosts, prev_private)
    end)

    # The tool itself needs only the calling Agent; the dispatcher context
    # (disclosure, runtime) is built where a test goes through dispatch.
    {:ok,
     base: "http://127.0.0.1:#{port}", ctx: %{agent_id: SalixAgent.TestSupport.new_agent_id()}}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp dispatch_ctx(agent) do
    ctx =
      %{agent_id: agent, role: "worker", runtime_kind: :script}
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx
    |> Map.put(:tool_disclosure, ToolDisclosure.materialize("worker", :script, ctx))
    |> Map.merge(%{visible_reply_phase: :clean, visible_reply_guard: :clean})
  end

  defp call(args, ctx), do: args |> HttpRequest.request(ctx) |> Jason.decode!()

  describe "registry" do
    test "is a write tool with a precise schema, disclosed to every runtime, grantable to loops" do
      entry = Tools.find_entry("web.http_request")
      assert Tools.entry_safety(entry) == "write"
      assert %{"required" => ["url"], "additionalProperties" => false} = Tools.entry_schema(entry)
      assert Tools.entry_runtimes(entry) == []
      assert "web.http_request" in SalixAgent.Loops.Capabilities.allowed_names()
    end

    test "the dispatcher deadline follows the request timeout" do
      assert Tools.tool_timeout_ms("web.http_request", %{}) == 25_000
      assert Tools.tool_timeout_ms("web.http_request", %{"timeout_ms" => 60_000}) == 65_000
      # An invalid timeout is the tool's error to raise; the deadline stays sane.
      assert Tools.tool_timeout_ms("web.http_request", %{"timeout_ms" => "soon"}) == 25_000
    end
  end

  describe "request shape" do
    test "GET sends query and headers, defaults accept and user-agent, parses JSON", %{
      base: base,
      ctx: ctx
    } do
      result =
        call(
          %{
            "url" => base <> "/echo?fixed=1",
            "query" => %{"page" => 2, "verbose" => true},
            "headers" => %{"X-Trace" => "abc"}
          },
          ctx
        )

      assert %{"status" => 200, "ok" => true, "truncated" => false} = result
      assert is_integer(result["duration_ms"])
      assert result["headers"]["content-type"] =~ "application/json"

      body = result["body"]
      assert body["method"] == "GET"
      assert body["query"] == %{"fixed" => "1", "page" => "2", "verbose" => "true"}
      assert body["headers"]["x-trace"] == "abc"
      assert body["headers"]["accept"] == "application/json"
      assert body["headers"]["user-agent"] =~ "web.http_request"
      assert body["json"] == nil
    end

    test "POST JSON-encodes an object body as application/json", %{base: base, ctx: ctx} do
      result =
        call(%{"url" => base <> "/echo", "method" => "post", "body" => %{"a" => [1, 2]}}, ctx)

      assert result["status"] == 200
      assert result["body"]["method"] == "POST"
      assert result["body"]["headers"]["content-type"] == "application/json"
      assert result["body"]["json"] == %{"a" => [1, 2]}
    end

    test "a string body is sent verbatim with the caller's content type", %{base: base, ctx: ctx} do
      result =
        call(
          %{
            "url" => base <> "/echo",
            "method" => "PUT",
            "headers" => %{"content-type" => "application/x-www-form-urlencoded"},
            "body" => "a=1&b=2"
          },
          ctx
        )

      assert result["body"]["method"] == "PUT"
      assert result["body"]["raw"] == "a=1&b=2"
      assert result["body"]["headers"]["content-type"] == "application/x-www-form-urlencoded"

      plain = call(%{"url" => base <> "/echo", "method" => "POST", "body" => "hello"}, ctx)
      assert plain["body"]["raw"] == "hello"
      assert plain["body"]["headers"]["content-type"] == "text/plain; charset=utf-8"
    end

    test "null body sends nothing", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/echo", "method" => "DELETE", "body" => nil}, ctx)
      assert result["body"]["method"] == "DELETE"
      assert result["body"]["raw"] == ""
      refute Map.has_key?(result["body"]["headers"], "content-type")
    end

    test "HEAD and empty responses carry no body field; response headers are lower-cased strings",
         %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/repeat"}, ctx)
      assert result["status"] == 204
      refute Map.has_key?(result, "body")
      refute Map.has_key?(result, "body_text")
      # A header sent more than once is joined into one string.
      assert result["headers"]["x-many"] == "one, two"

      assert Enum.all?(result["headers"], fn {k, v} ->
               k == String.downcase(k) and is_binary(v)
             end)

      head = call(%{"url" => base <> "/echo", "method" => "HEAD"}, ctx)
      assert head["status"] == 200
      refute Map.has_key?(head, "body")
    end
  end

  describe "response shape" do
    test "a non-2xx status is a result, not an error", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/fail"}, ctx)
      assert %{"status" => 503, "ok" => false, "body" => %{"error" => "down"}} = result
    end

    test "redirects are not followed", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/redirect"}, ctx)
      assert result["status"] == 302
      assert result["headers"]["location"] == "/echo"
      # Only the redirect itself was requested.
      assert %{path: "/redirect"} = MockApi.last_request()
    end

    test "a non-JSON body comes back as body_text", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/text"}, ctx)
      assert result["ok"]
      assert result["body_text"] == "plain words"
      refute Map.has_key?(result, "body")
    end

    test "an oversized body is cut at the read cap and flagged", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/big"}, ctx)
      assert result["status"] == 200
      assert result["truncated"] == true
      assert byte_size(result["body_text"]) == HttpRequest.max_response_bytes()
      refute Map.has_key?(result, "body")
    end

    test "a slow server raises after timeout_ms", %{base: base, ctx: ctx} do
      assert_raise RuntimeError, ~r/no response within 1000 ms/, fn ->
        HttpRequest.request(%{"url" => base <> "/slow", "timeout_ms" => 1_000}, ctx)
      end
    end
  end

  describe "argument validation" do
    test "url is required, absolute, http(s) and credential-free", %{ctx: ctx} do
      assert_raise RuntimeError, ~r/'url' is required/, fn -> HttpRequest.request(%{}, ctx) end

      assert_raise RuntimeError, ~r/absolute http or https/, fn ->
        HttpRequest.request(%{"url" => "ftp://example.com/x"}, ctx)
      end

      assert_raise RuntimeError, ~r/absolute http or https/, fn ->
        HttpRequest.request(%{"url" => "/relative"}, ctx)
      end

      assert_raise RuntimeError, ~r/must not carry credentials/, fn ->
        HttpRequest.request(%{"url" => "https://user:pw@example.com/"}, ctx)
      end
    end

    test "method, timeout and header rules", %{base: base, ctx: ctx} do
      assert_raise RuntimeError, ~r/method must be one of/, fn ->
        HttpRequest.request(%{"url" => base, "method" => "TRACE"}, ctx)
      end

      assert_raise RuntimeError, ~r/timeout_ms must be between/, fn ->
        HttpRequest.request(%{"url" => base, "timeout_ms" => 90_000}, ctx)
      end

      for name <- ["Host", "content-length", "Transfer-Encoding", "proxy-authorization"] do
        assert_raise RuntimeError, ~r/set by the transport/, fn ->
          HttpRequest.request(%{"url" => base, "headers" => %{name => "x"}}, ctx)
        end
      end

      assert_raise RuntimeError, ~r/invalid header name/, fn ->
        HttpRequest.request(%{"url" => base, "headers" => %{"bad name" => "x"}}, ctx)
      end

      assert_raise RuntimeError, ~r/must not contain line breaks/, fn ->
        HttpRequest.request(%{"url" => base, "headers" => %{"x-a" => "1\r\nx-b: 2"}}, ctx)
      end

      assert_raise RuntimeError, ~r/duplicate header/, fn ->
        HttpRequest.request(%{"url" => base, "headers" => %{"X-A" => "1", "x-a" => "2"}}, ctx)
      end

      assert_raise RuntimeError, ~r/headers must be an object/, fn ->
        HttpRequest.request(%{"url" => base, "headers" => ["x"]}, ctx)
      end
    end
  end

  describe "destination policy" do
    test "special-purpose addresses are blocked, global unicast is not" do
      for literal <- ~w(0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1
                       172.31.255.255 192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1
                       203.0.113.9 224.0.0.1 255.255.255.255 ::1 :: fc00::1 fd12::1 fe80::1
                       ff02::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:8.8.8.8 64:ff9b::a00:1
                       2002:c0a8:101:: 2001:db8::1) do
        {:ok, address} = :inet.parse_address(String.to_charlist(literal))
        blocked = HttpRequest.blocked_address?(address)

        assert blocked == (literal != "::ffff:8.8.8.8"),
               "#{literal} blocked? expected #{literal != "::ffff:8.8.8.8"}"
      end

      for literal <- ~w(8.8.8.8 1.1.1.1 93.184.216.34 172.32.0.1 100.128.0.1 2606:4700::1111
                       2a00:1450:4001::1) do
        {:ok, address} = :inet.parse_address(String.to_charlist(literal))
        refute HttpRequest.blocked_address?(address), "#{literal} must not be blocked"
      end
    end

    test "loopback and internal names are refused before any connection", %{base: base, ctx: ctx} do
      Application.put_env(:salix_agent, :http_request_allow_private_hosts, false)

      assert_raise RuntimeError, ~r/127\.0\.0\.1, which is not a public address/, fn ->
        HttpRequest.request(%{"url" => base <> "/echo"}, ctx)
      end

      for host <- [
            "localhost",
            "db.svc",
            "api.internal",
            "metadata.google.internal",
            "node.local",
            "x.cluster.local"
          ] do
        assert_raise RuntimeError, ~r/is not a public destination/, fn ->
          HttpRequest.request(%{"url" => "http://#{host}/"}, ctx)
        end
      end

      assert_raise RuntimeError, ~r/not a public address/, fn ->
        HttpRequest.request(%{"url" => "http://[::1]:9/"}, ctx)
      end

      assert_raise RuntimeError, ~r/not a public address/, fn ->
        HttpRequest.request(%{"url" => "http://169.254.169.254/latest/meta-data"}, ctx)
      end

      # Nothing reached the mock.
      assert MockApi.last_request() == nil
    end

    test "the connection is pinned to the resolved address while the name stays in Host", %{
      base: base,
      ctx: ctx
    } do
      # `localhost` resolves here to loopback; the tool connects to that IP
      # and still sends the name (not the IP) as the Host header, which is
      # what makes a DNS answer changing after the check irrelevant.
      port = base |> URI.parse() |> Map.fetch!(:port)
      result = call(%{"url" => "http://localhost:#{port}/echo"}, ctx)

      assert result["ok"]
      assert result["body"]["headers"]["host"] == "localhost:#{port}"

      # Resolution happens once, here, IPv4 first; the transport gets these
      # addresses and never looks the name up again.
      assert [{127, 0, 0, 1} | _] = HttpRequest.resolve_destination!("localhost")
      assert [{127, 0, 0, 1}] = HttpRequest.resolve_destination!("127.0.0.1")

      # With the policy on, the same name is refused before any connection.
      Application.put_env(:salix_agent, :http_request_allow_private_hosts, false)

      assert_raise RuntimeError, ~r/is not a public destination/, fn ->
        HttpRequest.request(%{"url" => "http://localhost:#{port}/echo"}, ctx)
      end
    end
  end

  describe "credential_env placeholders" do
    setup do
      previous = Application.get_env(:salix_agent, :oauth_store_mod)
      Application.put_env(:salix_agent, :oauth_store_mod, OAuthStore)

      on_exit(fn -> restore(:salix_agent, :oauth_store_mod, previous) end)

      :ok =
        SalixStore.OAuth.put("http-request-oauth", %{
          "access_token" => "test-oauth-token",
          "status" => "active"
        })

      :ok
    end

    @ref %{
      "env_var" => "GH_TOKEN",
      "provider" => "github",
      "alias" => "github",
      "value" => "access_token"
    }

    test "a header placeholder resolves to the bound credential without exposing it", %{
      base: base,
      ctx: ctx
    } do
      result =
        call(
          %{
            "url" => base <> "/echo",
            "headers" => %{"Authorization" => "Bearer ${GH_TOKEN}"},
            "query" => %{"token" => "${GH_TOKEN}"},
            "credential_env" => [@ref]
          },
          ctx
        )

      assert result["ok"]

      assert %{
               headers: %{"authorization" => "Bearer test-oauth-token"},
               query: %{"token" => "test-oauth-token"}
             } = MockApi.last_request()
    end

    test "a placeholder without an entry, and an unbound credential, are refused before sending",
         %{
           base: base,
           ctx: ctx
         } do
      assert_raise RuntimeError,
                   ~r/references \$\{API_KEY\} but credential_env has no entry/,
                   fn ->
                     HttpRequest.request(
                       %{"url" => base <> "/echo", "headers" => %{"x-api-key" => "${API_KEY}"}},
                       ctx
                     )
                   end

      assert_raise RuntimeError, ~r/not bound to this agent group/, fn ->
        HttpRequest.request(
          %{
            "url" => base <> "/echo",
            "headers" => %{"authorization" => "Bearer ${GH_TOKEN}"},
            "credential_env" => [%{@ref | "alias" => "elsewhere"}]
          },
          ctx
        )
      end

      assert MockApi.last_request() == nil
    end
  end

  describe "through the script host" do
    @describetag :spinfoam
    @describetag skip:
                   if(SalixAgent.SpinfoamFixture.available?(),
                     do: false,
                     else: "spinfoam binary unavailable"
                   )

    test "salix.call reaches the same tool and the program sees the decoded result", %{
      base: base,
      ctx: ctx
    } do
      call =
        Jason.encode!(%{
          "tool" => "web.http_request",
          "args" => %{"url" => base <> "/echo", "method" => "POST", "body" => %{"n" => 41}}
        })

      [result] =
        SessionToolDispatch.execute(
          [
            %{
              id: "js-http",
              name: "script.run",
              args: %{
                "source" => SalixAgent.SpinfoamFixture.script_call_program(call, pick: "body")
              }
            }
          ],
          dispatch_ctx(ctx.agent_id)
        )

      refute result.error
      assert %{"json" => %{"n" => 41}} = Jason.decode!(result.content)
      assert %{method: "POST", body: ~s|{"n":41}|} = MockApi.last_request()
    end
  end
end
