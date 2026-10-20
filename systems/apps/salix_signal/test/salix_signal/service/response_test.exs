defmodule SalixSignal.Service.ResponseTest do
  # Status handling from CRS-01 sections 12 to 14 and CRS-15 sections 2, 5 and 6.
  use SystemsClock.Case, async: true

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
end
