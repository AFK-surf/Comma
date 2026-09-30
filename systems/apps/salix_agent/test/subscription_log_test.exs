defmodule SalixAgent.SubscriptionLogTest do
  use ExUnit.Case, async: false
  alias SalixAgent.SubscriptionLog, as: Log

  test "failed observation preserves results, exceptions, and caller metadata" do
    previous = Logger.metadata()
    result = {:error, %RuntimeError{message: "PRIVATE_ERROR"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Log.context(%{agent_id: ["PRIVATE_ID"], credentials: "PRIVATE_TOKEN"}, fn ->
                 Log.span("subscription_test", [], fn -> result end, fn ->
                   raise "PRIVATE_SINK"
                 end)
               end) == result

        assert_raise RuntimeError, "PRIVATE_BUSINESS", fn ->
          Log.context([account_id: "account-1"], fn ->
            Log.span("subscription_test", [], fn -> raise "PRIVATE_BUSINESS" end)
          end)
        end
      end)

    refute log =~ "PRIVATE_"
    assert Logger.metadata() == previous
  end
end
