defmodule Comma.OauthIdp.RateLimitTest do
  # async: false — policies live in application config.
  use ExUnit.Case, async: false

  alias Comma.OauthIdp.RateLimit

  setup do
    previous = Application.get_env(:comma_core, :oauth_idp_rate_limit)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:comma_core, :oauth_idp_rate_limit)
        value -> Application.put_env(:comma_core, :oauth_idp_rate_limit, value)
      end
    end)

    :ok
  end

  defp set_policy(endpoint, burst, rate) do
    Application.put_env(:comma_core, :oauth_idp_rate_limit, [{endpoint, [burst: burst, rate: rate]}])
  end

  defp unique_peer, do: {:peer, make_ref()}

  test "allows up to burst then denies with a positive retry-after" do
    set_policy(:token, 3, 0.0)
    peer = unique_peer()

    assert :allow = RateLimit.check(:token, peer)
    assert :allow = RateLimit.check(:token, peer)
    assert :allow = RateLimit.check(:token, peer)
    assert {:deny, retry_after} = RateLimit.check(:token, peer)
    assert retry_after >= 1
  end

  test "separate peers have independent buckets" do
    set_policy(:token, 1, 0.0)
    exhausted = unique_peer()

    assert :allow = RateLimit.check(:token, exhausted)
    assert {:deny, _retry_after} = RateLimit.check(:token, exhausted)
    assert :allow = RateLimit.check(:token, unique_peer())
  end

  test "endpoints have independent buckets for the same peer" do
    Application.put_env(:comma_core, :oauth_idp_rate_limit,
      token: [burst: 1, rate: 0.0],
      authorize: [burst: 1, rate: 0.0]
    )

    peer = unique_peer()

    assert :allow = RateLimit.check(:token, peer)
    assert {:deny, _retry_after} = RateLimit.check(:token, peer)
    assert :allow = RateLimit.check(:authorize, peer)
  end

  test "an undecidable policy fails closed as unavailable" do
    set_policy(:token, 0, 1.0)

    assert {:unavailable, retry_after} = RateLimit.check(:token, unique_peer())
    assert retry_after >= 1
  end

  test "decisions emit the low-cardinality telemetry event" do
    handler_id = "rate-limit-test-#{inspect(make_ref())}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :oauth_idp, :rate_limit],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rate_limit_event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    set_policy(:authorize, 1, 0.0)
    peer = unique_peer()

    assert :allow = RateLimit.check(:authorize, peer)
    assert_receive {:rate_limit_event, %{count: 1}, %{endpoint: :authorize, outcome: :allow}}

    assert {:deny, _retry_after} = RateLimit.check(:authorize, peer)
    assert_receive {:rate_limit_event, %{count: 1}, %{endpoint: :authorize, outcome: :deny}}

    set_policy(:authorize, 0, 1.0)
    assert {:unavailable, _retry_after} = RateLimit.check(:authorize, unique_peer())

    assert_receive {:rate_limit_event, %{count: 1},
                    %{endpoint: :authorize, outcome: :unavailable}}
  end
end
