defmodule SalixIM.TelegramSendTelemetryTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Telegram
  alias SalixIM.TestSupport.BanditServer

  @reporter Module.concat(__MODULE__, Reporter)

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      %{"text" => response, "parse_mode" => "HTML"} = Jason.decode!(raw)

      {status, body} =
        case response do
          "ok" ->
            {200, %{"ok" => true, "result" => %{"message_id" => 1}}}

          "missing-result" ->
            {200, %{"ok" => true}}

          "timeout" ->
            SystemsRuntime.Proc.sleep(100)
            {200, %{"ok" => true, "result" => %{}}}

          "blocked-body" ->
            {200,
             %{"ok" => false, "error_code" => 403, "description" => "private-provider-error"}}

          "401-blocked-body" ->
            {401,
             %{"ok" => false, "error_code" => 403, "description" => "private-provider-error"}}

          code ->
            {String.to_integer(code), %{"ok" => false, "description" => "private-provider-error"}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_im, :telegram_api_base_url)
    previous_req = Req.default_options()
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, measurements, metadata, _ ->
        if metadata[:operation] == "telegram_send_message",
          do: SystemsRuntime.Proc.send(parent, {:observed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(handler)
      Req.default_options(previous_req)

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_im, :telegram_api_base_url),
        else: SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, previous)
    end)

    %{
      connect: %{
        "provider" => "telegram",
        "status" => "connected",
        "managed_by" => "comma_product",
        "managed_peer_id" => "private-peer",
        "bot_token" => "private-token"
      }
    }
  end

  test "broken telemetry handlers leave successful provider delivery unchanged", %{
    connect: connect
  } do
    handler = {__MODULE__, :broken, SystemsRuntime.Proc.make_ref()}

    SystemsRuntime.Telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, _, _, _ -> throw(:broken_observer) end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    assert {:ok, %{"message_id" => 1}} = send_message(connect, "ok")
  end

  defp send_message(connect, text),
    do:
      Telegram.call("agent", connect, "telegram.send_message", %{
        "chat_id" => "private-peer",
        "text" => text
      })
end
