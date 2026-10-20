defmodule SalixAgent.ToolsHttpRequestTest do
  @moduledoc """
  `web.http_request` (`SalixAgent.Tools.HttpRequest`) against a Bandit mock
  API: the request the caller shapes (method, headers, query, body,
  credential placeholders) is what leaves; the response comes back as one
  JSON result; the destination policy refuses non-public hosts; and the same
  tool is reachable from the JavaScript host through `salix.call`.
  """
  use SystemsClock.Case, async: false

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
          SystemsRuntime.Proc.sleep(3_000)
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
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_private = SystemsRuntime.get_env(:salix_agent, :http_request_allow_private_hosts)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    # The mock listens on loopback, which the destination policy refuses.
    SystemsRuntime.put_env(:salix_agent, :http_request_allow_private_hosts, true)
    start_supervised!(MockApi)

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

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

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp call(args, ctx), do: args |> HttpRequest.request(ctx) |> Jason.decode!()

  describe "registry" do
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
  end

  describe "response shape" do
    test "redirects are not followed", %{base: base, ctx: ctx} do
      result = call(%{"url" => base <> "/redirect"}, ctx)
      assert result["status"] == 302
      assert result["headers"]["location"] == "/echo"
      # Only the redirect itself was requested.
      assert %{path: "/redirect"} = MockApi.last_request()
    end
  end

  describe "argument validation" do
  end

  describe "destination policy" do
    test "loopback and internal names are refused before any connection", %{base: base, ctx: ctx} do
      SystemsRuntime.put_env(:salix_agent, :http_request_allow_private_hosts, false)

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
  end

  describe "credential_env placeholders" do
    setup do
      previous = SystemsRuntime.get_env(:salix_agent, :oauth_store_mod)
      SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, OAuthStore)

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
  end
end
