defmodule SalixSignal.Service.ResponseTest do
  # Status handling from CRS-01 sections 12 to 14 and CRS-15 sections 2, 5 and 6.
  use ExUnit.Case, async: true

  alias SalixSignal.Service.{Backoff, Response}

  defp response(status, headers \\ [], body \\ ""),
    do: %Response{status: status, headers: headers, body: body}

  test "a 428 gives the challenge token and the known proofs" do
    body = ~s({"token":"t-1","options":["captcha","pushChallenge","somethingNew"]})

    assert Response.outcome(response(428, [{"retry-after", "30"}], body)) ==
             {:challenge_required,
              %{token: "t-1", options: [:captcha, :push_challenge], retry_after: 30}}

    assert Response.outcome(response(428, [], "not json")) ==
             {:challenge_required, %{token: nil, options: [], retry_after: nil}}
  end

  test "Retry-After is read only as whole seconds" do
    assert Response.outcome(response(429, [{"retry-after", "17"}])) == {:rate_limited, 17}
    assert Response.outcome(response(429)) == {:rate_limited, nil}

    assert Response.outcome(response(429, [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}])) ==
             {:rate_limited, nil}
  end

  # Owner decision: a honoured Retry-After is at most one hour, so one bad
  # header cannot park the account's socket or sends for a day.
  test "a Retry-After longer than one hour is honoured for one hour" do
    assert Response.outcome(response(429, [{"retry-after", "86400"}])) == {:rate_limited, 3_600}
    assert Response.outcome(response(429, [{"retry-after", "3600"}])) == {:rate_limited, 3_600}

    assert {:challenge_required, %{retry_after: 3_600}} =
             Response.outcome(response(428, [{"retry-after", "999999"}], "{}"))

    assert Backoff.honor_retry_after(400, 86_400) == 3_600_000
  end

  test "deprecation, rejection and server failures are told apart" do
    assert Response.outcome(response(204)) == :ok
    assert Response.outcome(response(499)) == :client_deprecated
    assert Response.outcome(response(498)) == :use_websocket
    assert Response.outcome(response(508)) == :rejected
    assert Response.outcome(response(503)) == {:server_error, 503}
    assert Response.outcome(response(409)) == {:http_error, 409}
  end

  test "a response without X-Signal-Timestamp did not come from the service" do
    assert Response.server_time_ms(response(403, [{"x-signal-timestamp", "1758790000789"}])) ==
             1_758_790_000_789

    assert Response.server_time_ms(response(403)) == nil
  end

  test "backoff grows to its cap with jitter and never undercuts Retry-After" do
    opts = [base_ms: 100, max_ms: 1_000]
    assert Backoff.delay_ms(0, opts, 0.0) == 50
    assert Backoff.delay_ms(0, opts, 0.999) in 50..100
    assert Backoff.delay_ms(3, opts, 0.0) == 400
    assert Backoff.delay_ms(50, opts, 0.999) in 500..1_000
    assert Backoff.honor_retry_after(400, 2) == 2_000
    assert Backoff.honor_retry_after(400, nil) == 400
  end
end
