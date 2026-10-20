defmodule CommaWeb.TelegramTelemetryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  import Plug.Conn
  import Plug.Test

  alias CommaWeb.TelegramTelemetry

  @reporter Module.concat(__MODULE__, Reporter)
  @secret "test-webhook-secret-with-32-characters"

  setup do
    previous = SystemsRuntime.get_env(:comma_web, :telegram)

    SystemsRuntime.put_env(:comma_web, :telegram,
      enabled: true,
      bot_token: "private-bot-token",
      bot_username: "comma_test_bot",
      public_base_url: "https://comma.test",
      webhook_secret: @secret
    )

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: CommaProduct.Telemetry.metrics(), start_async: false}
    )

    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      handler,
      [:comma_product, :operation, :stop],
      fn _, measurements, metadata, _ ->
        SystemsRuntime.Proc.send(parent, {:observed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(handler)

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:comma_web, :telegram),
        else: SystemsRuntime.put_env(:comma_web, :telegram, previous)
    end)

    :ok
  end

  test "provider failures preserve their result, classify safely, and reach the shared scrape" do
    for {result, expected} <- [
          {{:ok, %{"message_id" => "private-message-id"}}, :ok},
          {{:error, {:telegram_http_error, 401}}, :error},
          {{:error, {:telegram_http_error, 403}}, :rejected},
          {{:error, {:telegram_http_error, 429}}, :rate_limited},
          {{:error, {:telegram_http_error, 503}}, :error},
          {{:error, :timeout}, :timeout},
          {{:error, :telegram_unavailable}, :unavailable},
          {{:error, "private-error-text"}, :error}
        ] do
      assert TelegramTelemetry.observe(:telegram_send_message, fn -> result end) == result

      settle_receive({:observed, %{duration: duration}, metadata})
      assert duration >= 0

      assert metadata == %{
               operation: :telegram_send_message,
               provider: "telegram",
               outcome: expected
             }

      settle_refute_receive({:observed, _, _}, 0)
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(comma_product_operations_total{operation="telegram_send_message",outcome="error",provider="telegram"} 3)

    refute scrape =~ "private-message-id"
    refute scrape =~ "private-error-text"
    refute scrape =~ "private-bot-token"
  end

  defp webhook(secret) do
    request =
      conn(:post, "/v1/comma/integrations/telegram/webhook", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")

    request =
      if secret,
        do: put_req_header(request, "x-telegram-bot-api-secret-token", secret),
        else: request

    CommaWeb.Router.call(request, CommaWeb.Router.init([]))
  end
end
