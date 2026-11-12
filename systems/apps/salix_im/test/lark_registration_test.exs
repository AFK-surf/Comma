defmodule SalixIM.LarkRegistrationTest do
  @moduledoc """
  One-click app creation against a fake accounts service of each platform,
  answering `init`, `begin` and `poll` as Lark and Feishu do.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Lark.Registration
  alias SalixIM.TestSupport.BanditServer

  defmodule Accounts do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, brand: brand, polls: polls}) do
      {:ok, raw, conn} = read_body(conn)
      form = URI.decode_query(raw)
      SystemsRuntime.Proc.send(test, {:accounts, brand, form})

      body =
        case form["action"] do
          "init" ->
            %{"supported_auth_methods" => ["client_secret", "private_key_jwt"]}

          "begin" ->
            %{
              "device_code" => "dc-1",
              "user_code" => "ABCD-1234",
              "verification_uri_complete" =>
                "https://open.#{brand}.test/page/launcher?user_code=ABCD-1234",
              "interval" => 5,
              "expires_in" => 3600
            }

          "poll" ->
            Agent.get_and_update(polls, fn
              [next | rest] -> {next, rest}
              [] -> {%{"error" => "authorization_pending"}, []}
            end)
        end

      case body do
        # The platform's gateway throttles with a bare 429.
        :throttled ->
          send_resp(conn, 429, "Too Many Requests")

        body ->
          conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
      end
    end
  end

  setup context do
    {:ok, polls} = Agent.start_link(fn -> Map.get(context, :polls, []) end)
    test = SystemsRuntime.Proc.self()

    urls = %{
      "feishu" => BanditServer.serve!(Accounts, %{test: test, brand: "feishu", polls: polls}),
      "lark" => BanditServer.serve!(Accounts, %{test: test, brand: "lark", polls: polls})
    }

    SystemsRuntime.put_env(:salix_im, :lark_registration_base_urls, urls)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :lark_registration_base_urls) end)
    :ok
  end

  test "begins on Feishu and links Lark's page with the app's name and what the connect needs" do
    assert {:ok, begun} = Registration.begin("lark", "Comma for Ada")

    # The protocol always begins on Feishu; Lark people confirm on Lark's page.
    assert_received {:accounts, "feishu", %{"action" => "init"}}
    assert_received {:accounts, "feishu", %{"action" => "begin"} = form}
    assert form["archetype"] == "PersonalAgent"
    assert form["auth_method"] == "client_secret"
    assert form["request_user_info"] == "open_id tenant_brand"
    refute_received {:accounts, "lark", _form}

    assert begun.device_code == "dc-1"
    assert begun.interval_s == 5 and begun.expires_in_s == 3600

    url = URI.parse(begun.url)
    assert url.scheme == "https" and url.host == "open.larksuite.com" and url.path == "/page/cli"
    query = URI.decode_query(url.query)
    assert query["user_code"] == "ABCD-1234"
    assert query["name"] == "Comma for Ada"

    addons =
      query["addons"] |> Base.url_decode64!(padding: false) |> :zlib.gunzip() |> Jason.decode!()

    assert "im:message.group_msg" in addons["scopes"]["tenant"]
    assert "im.message.receive_v1" in addons["events"]["items"]["tenant"]
    assert "vc:meeting.bot.join:write" in addons["scopes"]["tenant"]
    assert "vc:meeting.message:write" in addons["scopes"]["tenant"]
    assert "vc.bot.meeting_invited_v1" in addons["events"]["items"]["tenant"]
    assert addons["callbacks"]["items"] == ["card.action.trigger"]
  end

  test "a Feishu registration links Feishu's page" do
    assert {:ok, begun} = Registration.begin("feishu", "Comma")
    assert %URI{host: "open.feishu.cn", path: "/page/cli"} = URI.parse(begun.url)
  end

  @tag polls: [
         %{"error" => "authorization_pending", "user_info" => %{"tenant_brand" => "lark"}},
         %{
           "client_id" => "cli_new",
           "client_secret" => "new-secret",
           "user_info" => %{"open_id" => "ou_ada", "tenant_brand" => "lark"}
         }
       ]
  test "asks on Lark once the tenant says it is Lark, and gives the app with its creator" do
    assert {:pending, "lark"} = Registration.poll("feishu", "dc-1")
    assert_received {:accounts, "feishu", %{"action" => "poll", "device_code" => "dc-1"}}

    assert {:ok, app} = Registration.poll("lark", "dc-1")
    assert_received {:accounts, "lark", %{"action" => "poll"}}

    assert app == %{
             app_id: "cli_new",
             app_secret: "new-secret",
             open_id: "ou_ada",
             brand: "lark",
             domain: "lark"
           }
  end

  @tag polls: [
         %{"error" => "slow_down"},
         :throttled,
         %{"error" => "access_denied"},
         %{"error" => "expired_token"},
         %{"error" => "invalid_request", "error_description" => "bad code"}
       ]
  test "says how a registration goes on or ends" do
    assert {:slow_down, "feishu"} = Registration.poll("feishu", "dc-1")
    assert {:slow_down, "feishu"} = Registration.poll("feishu", "dc-1")
    assert {:error, :denied} = Registration.poll("feishu", "dc-1")
    assert {:error, :expired} = Registration.poll("feishu", "dc-1")
    assert {:error, "invalid_request bad code"} = Registration.poll("feishu", "dc-1")
  end

  @tag polls: [
         %{
           "client_id" => "cli_feishu",
           "client_secret" => "secret",
           "user_info" => %{"open_id" => "ou_ada", "tenant_brand" => "feishu"}
         }
       ]
  test "a Feishu account's app is not a Lark bot" do
    assert {:error, "This is a Feishu account. Connect it to Feishu."} =
             SalixIM.ProviderConnects.poll_lark_registration("feishu", "dc-1")
  end

  @tag polls: [%{"client_id" => "cli_nobody", "client_secret" => "secret"}]
  test "an owner's bot is not connected when Lark does not say who made it" do
    assert {:error, "Lark did not say who made the app"} =
             SalixIM.ProviderConnects.finish_lark_registration(
               "tenant-x",
               "group-x",
               "feishu",
               "dc-1",
               owner: true
             )
  end
end
