defmodule CommaWeb.TelegramCommandSetupTest do
  use SystemsClock.Case, async: false

  alias CommaWeb.{TelegramBot, TelegramCommands, TelegramCommandSetup}
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn

    def init(state), do: state

    def call(conn, state) do
      {:ok, body, conn} = read_body(conn)
      params = Jason.decode!(body)
      ["botsetup-test-token", method] = conn.path_info

      result =
        Agent.get_and_update(state, fn data ->
          data = Map.update!(data, :calls, &(&1 ++ [{method, params}]))

          case method do
            "getMe" ->
              {%{"username" => data.username}, data}

            "setMyCommands" ->
              {true, put_in(data.commands[params["language_code"]], params)}

            "getMyCommands" ->
              commands = data.commands[params["language_code"]]["commands"]
              {if(data.drift, do: [], else: commands), data}

            "setChatMenuButton" ->
              {true, Map.put(data, :menu, params["menu_button"])}

            "getChatMenuButton" ->
              {data.menu, data}

            "sendMessage" ->
              {%{"error_code" => 403}, data}
          end
        end)

      response =
        if method == "sendMessage",
          do: Map.put(result, "ok", false),
          else: %{"ok" => true, "result" => result}

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    state =
      start_supervised!(
        {Agent,
         fn -> %{calls: [], commands: %{}, drift: false, username: "comma_product_bot"} end}
      )

    port = BanditServer.start!(fn port -> {Bandit, plug: {API, state}, port: port} end)
    previous = SystemsRuntime.get_env(:comma_web, :telegram)

    SystemsRuntime.put_env(:comma_web, :telegram,
      enabled: true,
      bot_token: "setup-test-token",
      bot_username: "comma_product_bot",
      public_base_url: "https://comma.test",
      webhook_secret: "setup-test-webhook-secret-32-bytes",
      bot_adapter: CommaWeb.TelegramBot.Req,
      api_base_url: "http://127.0.0.1:#{port}"
    )

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:comma_web, :telegram),
        else: SystemsRuntime.put_env(:comma_web, :telegram, previous)
    end)

    %{state: state}
  end

  test "dry-run makes no API call; apply converges and reads back all private-chat language menus",
       %{state: state} do
    assert {:ok, %{"dry_run" => true} = plan} = TelegramCommandSetup.apply()
    assert Agent.get(state, & &1.calls) == []
    assert plan["scope"] == %{"type" => "all_private_chats"}

    for _attempt <- 1..2 do
      assert {:ok, %{"dry_run" => false}} = TelegramCommandSetup.apply(dry_run: false)
    end

    data = Agent.get(state, & &1)
    assert data.menu == %{"type" => "commands"}

    for language <- ["", "en", "zh"] do
      assert Enum.map(data.commands[language]["commands"], & &1["command"]) ==
               ["start", "help", "status", "devices", "tasks", "disconnect"]

      assert data.commands[language] == %{
               "scope" => %{"type" => "all_private_chats"},
               "language_code" => language,
               "commands" => TelegramCommands.menu(language)
             }
    end

    assert Enum.all?(data.calls, fn {method, _params} -> method != "setWebhook" end)
  end
end
