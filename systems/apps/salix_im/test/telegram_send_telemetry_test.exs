defmodule SalixIM.TelegramSendTelemetryTest do
  use ExUnit.Case, async: false

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
            Process.sleep(100)
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
    previous = Application.get_env(:salix_im, :telegram_api_base_url)
    previous_req = Req.default_options()
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, measurements, metadata, _ ->
        if metadata[:operation] == "telegram_send_message",
          do: send(parent, {:observed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Req.default_options(previous_req)

      if is_nil(previous),
        do: Application.delete_env(:salix_im, :telegram_api_base_url),
        else: Application.put_env(:salix_im, :telegram_api_base_url, previous)
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

  test "actual send results classify 401, 403, 429 and 5xx and retain the provider return", %{
    connect: connect
  } do
    for {response, outcome} <- [
          {"ok", :ok},
          {"401", :error},
          {"403", :rejected},
          {"429", :error},
          {"503", :error},
          {"blocked-body", :rejected},
          {"401-blocked-body", :error}
        ] do
      result = send_message(connect, response)

      if response == "ok",
        do: assert(result == {:ok, %{"message_id" => 1}}),
        else: assert(result == {:error, "private-provider-error"})

      assert_receive {:observed, %{duration: duration}, metadata}
      assert duration >= 0

      assert metadata == %{
               component: "salix_im",
               operation: "telegram_send_message",
               surface: "comma",
               outcome: outcome
             }

      refute_receive {:observed, _, _}, 0
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_operations_total{component="salix_im",operation="telegram_send_message",outcome="error",surface="comma"} 4)

    refute scrape =~ "private"
  end

  test "transport timeout is observable and authorization rejection never sends", %{
    connect: connect
  } do
    Req.default_options(Keyword.put(Req.default_options(), :receive_timeout, 20))
    assert {:error, _} = send_message(connect, "timeout")
    assert_receive {:observed, _, %{outcome: :timeout}}
    refute_receive {:observed, _, _}, 0

    assert {:error, _} =
             Telegram.call("agent", connect, "telegram.send_message", %{
               "chat_id" => "other-peer",
               "text" => "ok"
             })

    refute_receive {:observed, _, _}, 0
  end

  test "HTTP success without a Telegram result remains a protocol failure", %{connect: connect} do
    assert {:error, reason} = send_message(connect, "missing-result")
    assert reason =~ "provider HTTP 200"
    assert_receive {:observed, _, %{outcome: :error}}
    refute_receive {:observed, _, _}, 0
  end

  test "broken telemetry handlers leave successful provider delivery unchanged", %{
    connect: connect
  } do
    handler = {__MODULE__, :broken, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, _, _, _ -> throw(:broken_observer) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, %{"message_id" => 1}} = send_message(connect, "ok")
  end

  defp send_message(connect, text),
    do:
      Telegram.call("agent", connect, "telegram.send_message", %{
        "chat_id" => "private-peer",
        "text" => text
      })
end
