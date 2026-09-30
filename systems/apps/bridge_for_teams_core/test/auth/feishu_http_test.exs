defmodule BridgeForTeams.Auth.Feishu.HTTPTest do
  @moduledoc """
  Exercises the real Feishu HTTP adapter against a local mock server. No network
  or real Feishu credentials are used.
  """
  use ExUnit.Case, async: false

  alias BridgeForTeams.Auth.Feishu.HTTP
  alias BridgeForTeams.TestBandit

  defmodule MockFeishuAuth do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/oauth/token"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      response =
        case payload do
          %{
            "grant_type" => "authorization_code",
            "client_id" => "feishu-app",
            "client_secret" => "feishu-secret",
            "code" => "good-code",
            "redirect_uri" => "https://teams.test/auth/callback"
          } ->
            %{"code" => 0, "data" => %{"access_token" => "mock-user-access-token"}}

          _ ->
            %{"code" => 190_001, "msg" => "bad request"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    def call(%{request_path: "/user_info"} = conn, _opts) do
      case get_req_header(conn, "authorization") do
        ["Bearer mock-user-access-token"] ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "user_id" => "feishu-user-http",
                "union_id" => "feishu-union-http",
                "open_id" => "feishu-open-http",
                "mobile" => "+10000000006",
                "name" => "HTTP Feishu User",
                "tenant_key" => "tenant-test"
              }
            })
          )

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"code" => 190_002}))
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  setup do
    %{url: base_url} =
      TestBandit.start_supervised!(plug: MockFeishuAuth, startup_log: false)

    %{base_url: base_url}
  end

  test "authorize_url builds a Feishu OAuth URL without a code verifier", %{base_url: base_url} do
    sso = sso(base_url)

    assert {:ok, %{url: url, state: state, code_verifier: nil}} =
             HTTP.authorize_url(sso, redirect_uri: "https://teams.test/auth/callback")

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "http"
    assert uri.host == "127.0.0.1"
    assert uri.path == "/authorize"
    assert query["client_id"] == "feishu-app"
    assert query["response_type"] == "code"
    assert query["redirect_uri"] == "https://teams.test/auth/callback"
    assert query["scope"] == "contact:user.base:readonly"
    assert query["state"] == state
  end

  test "fetch_identity exchanges code and returns a mobile-only Feishu identity", %{
    base_url: base_url
  } do
    assert {:ok, identity} =
             HTTP.fetch_identity(
               sso(base_url),
               %{"code" => "good-code"},
               redirect_uri: "https://teams.test/auth/callback"
             )

    assert identity["user_id"] == "feishu-user-http"
    assert identity["union_id"] == "feishu-union-http"
    assert identity["open_id"] == "feishu-open-http"
    assert identity["email"] == nil
    assert identity["mobile"] == "+10000000006"
    assert identity["display_name"] == "HTTP Feishu User"
    assert identity["profile"] == %{"tenant_key" => "tenant-test"}
  end

  test "fetch_identity returns structured errors without raw provider payloads", %{
    base_url: base_url
  } do
    assert {:error, {:feishu_error, 190_001}} =
             HTTP.fetch_identity(
               sso(base_url),
               %{"code" => "bad-code"},
               redirect_uri: "https://teams.test/auth/callback"
             )
  end

  defp sso(base_url) do
    %{
      client_id: "feishu-app",
      client_secret: "feishu-secret",
      provider_config: %{
        "authorize_endpoint" => base_url <> "/authorize",
        "token_endpoint" => base_url <> "/oauth/token",
        "user_info_endpoint" => base_url <> "/user_info"
      }
    }
  end
end
