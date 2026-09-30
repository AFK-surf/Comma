defmodule CommaWeb.TelegramTelemetryTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias CommaWeb.TelegramTelemetry

  @reporter Module.concat(__MODULE__, Reporter)
  @secret "test-webhook-secret-with-32-characters"

  setup do
    previous = Application.get_env(:comma_web, :telegram)

    Application.put_env(:comma_web, :telegram,
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

    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:comma_product, :operation, :stop],
      fn _, measurements, metadata, _ ->
        send(parent, {:observed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)

      if is_nil(previous),
        do: Application.delete_env(:comma_web, :telegram),
        else: Application.put_env(:comma_web, :telegram, previous)
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

      assert_receive {:observed, %{duration: duration}, metadata}
      assert duration >= 0

      assert metadata == %{
               operation: :telegram_send_message,
               provider: "telegram",
               outcome: expected
             }

      refute_receive {:observed, _, _}, 0
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(comma_product_operations_total{operation="telegram_send_message",outcome="error",provider="telegram"} 3)

    refute scrape =~ "private-message-id"
    refute scrape =~ "private-error-text"
    refute scrape =~ "private-bot-token"
  end

  test "raise, exit, and throw each emit once without changing the original failure" do
    assert_raise RuntimeError, "private-exception", fn ->
      TelegramTelemetry.observe(:telegram_webhook, fn -> raise "private-exception" end)
    end

    assert_receive {:observed, _, %{outcome: :error}}
    refute_receive {:observed, _, _}, 0

    assert catch_exit(TelegramTelemetry.observe(:telegram_webhook, fn -> exit(:private_exit) end)) ==
             :private_exit

    assert_receive {:observed, _, %{outcome: :error}}
    refute_receive {:observed, _, _}, 0

    assert catch_throw(
             TelegramTelemetry.observe(:telegram_webhook, fn -> throw(:private_throw) end)
           ) == :private_throw

    assert_receive {:observed, _, %{outcome: :error}}
    refute_receive {:observed, _, _}, 0

    refute TelemetryMetricsPrometheus.Core.scrape(@reporter) =~ "private"
  end

  test "telemetry handler failure does not change the business result" do
    handler = {__MODULE__, :broken, make_ref()}

    :telemetry.attach(
      handler,
      [:comma_product, :operation, :stop],
      fn _, _, _, _ -> raise "broken observer" end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok == TelegramTelemetry.observe(:telegram_webhook, fn -> :ok end)
    assert_receive {:observed, _, %{outcome: :ok}}
  end

  test "only authenticated webhook work contributes; public junk never fires or dilutes the signal" do
    for secret <- [nil, "wrong-secret"] do
      assert webhook(secret).status == 401
      refute_receive {:observed, _, _}, 0
    end

    assert webhook(@secret).status == 200
    assert_receive {:observed, _, %{operation: :telegram_webhook, outcome: :ok}}
    refute_receive {:observed, _, _}, 0

    assert SystemsObservability.RouteCatalog.classify(
             "comma_product_api",
             "/v1/comma/integrations/telegram/webhook"
           ) == "/v1/comma/integrations/*"
  end

  test "an absent reporter does not change webhook or send results" do
    stop_supervised!(@reporter)
    assert :ok == TelegramTelemetry.observe(:telegram_webhook, fn -> :ok end)
    failure = {:error, {:telegram_http_error, 503}}
    assert TelegramTelemetry.observe(:telegram_send_message, fn -> failure end) == failure
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
