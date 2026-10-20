defmodule BridgeForTeams.Auth.Lark.HTTPTest do
  @moduledoc """
  Exercises the Lark HTTP adapter against a local mock server. No network or
  real Lark credentials are used.
  """
  use SystemsClock.Case, async: false

  alias BridgeForTeams.Auth.Lark.HTTP
  alias BridgeForTeams.TestBandit

  @redirect_uri "https://teams.test/auth/callback"

  defmodule MockLarkAuth do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # The token endpoint of Lark answers with the token beside `code`.
    def call(%{request_path: "/oauth/token"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      response =
        case Jason.decode!(body) do
          %{
            "grant_type" => "authorization_code",
            "client_id" => "cli_lark_app",
            "client_secret" => "lark-secret",
            "code" => "good-code",
            "redirect_uri" => "https://teams.test/auth/callback",
            "code_verifier" => verifier
          } ->
            %{"code" => 0, "access_token" => "token-for-" <> verifier, "token_type" => "Bearer"}

          %{"code" => "denied-code"} ->
            :denied

          _ ->
            %{"code" => 20_003, "error" => "invalid_grant"}
        end

      case response do
        :denied -> json(conn, 400, %{"code" => 20_010, "error" => "access_denied"})
        response -> json(conn, 200, response)
      end
    end

    def call(%{request_path: "/user_info"} = conn, _opts) do
      case get_req_header(conn, "authorization") do
        ["Bearer token-for-the-verifier"] ->
          json(conn, 200, %{
            "code" => 0,
            "data" => %{
              "union_id" => "on-lark-union",
              "open_id" => "ou-lark-open",
              "name" => "HTTP Lark User",
              "en_name" => "HTTP Lark User",
              "tenant_key" => "lark-tenant",
              "avatar_url" => "https://lark.test/avatar.png"
            }
          })

        _ ->
          json(conn, 401, %{"code" => 99_991_668})
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    %{url: base_url} = TestBandit.start_supervised!(plug: MockLarkAuth, startup_log: false)
    %{base_url: base_url}
  end

  test "authorize_url goes to the Lark accounts host with PKCE and no scope by default" do
    sso = %{client_id: "cli_lark_app", client_secret: "lark-secret", provider_config: %{}}

    assert {:ok, %{url: url, state: state, code_verifier: verifier}} =
             HTTP.authorize_url(sso, redirect_uri: @redirect_uri)

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "accounts.larksuite.com"
    assert uri.path == "/open-apis/authen/v1/authorize"
    assert query["client_id"] == "cli_lark_app"
    assert query["response_type"] == "code"
    assert query["redirect_uri"] == @redirect_uri
    assert query["state"] == state
    assert query["code_challenge_method"] == "S256"

    assert query["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    refute Map.has_key?(query, "scope")
  end

  test "authorize_url requests the scope of the connection", %{base_url: base_url} do
    sso =
      put_in(sso(base_url), [:provider_config, "scope"], "contact:user.email:readonly")

    assert {:ok, %{url: url}} = HTTP.authorize_url(sso, redirect_uri: @redirect_uri)

    uri = URI.parse(url)
    assert uri.host == "127.0.0.1"
    assert uri.path == "/authorize"
    assert URI.decode_query(uri.query)["scope"] == "contact:user.email:readonly"
  end

  test "authorize_url needs an App ID" do
    assert {:error, :missing_client_id} =
             HTTP.authorize_url(%{client_id: ""}, redirect_uri: @redirect_uri)
  end

  test "fetch_identity sends the code verifier and returns a Lark identity without email",
       %{base_url: base_url} do
    assert {:ok, identity} =
             HTTP.fetch_identity(
               sso(base_url),
               %{"code" => "good-code"},
               redirect_uri: @redirect_uri,
               code_verifier: "the-verifier"
             )

    assert identity == %{
             "union_id" => "on-lark-union",
             "open_id" => "ou-lark-open",
             "display_name" => "HTTP Lark User",
             "profile" => %{
               "tenant_key" => "lark-tenant",
               "avatar_url" => "https://lark.test/avatar.png",
               "en_name" => "HTTP Lark User"
             }
           }
  end

  test "fetch_identity returns the Lark error code and no raw response", %{base_url: base_url} do
    opts = [redirect_uri: @redirect_uri, code_verifier: "the-verifier"]

    assert {:error, {:lark_error, 20_003}} =
             HTTP.fetch_identity(sso(base_url), %{"code" => "bad-code"}, opts)

    assert {:error, {:lark_token_http_status, 400}} =
             HTTP.fetch_identity(sso(base_url), %{"code" => "denied-code"}, opts)

    assert {:error, :missing_code} = HTTP.fetch_identity(sso(base_url), %{}, opts)

    assert {:error, :missing_client_secret} =
             HTTP.fetch_identity(
               %{sso(base_url) | client_secret: nil},
               %{"code" => "good-code"},
               opts
             )
  end

  defp sso(base_url) do
    %{
      client_id: "cli_lark_app",
      client_secret: "lark-secret",
      provider_config: %{
        "authorize_endpoint" => base_url <> "/authorize",
        "token_endpoint" => base_url <> "/oauth/token",
        "user_info_endpoint" => base_url <> "/user_info"
      }
    }
  end
end
