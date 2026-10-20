defmodule SalixCalendar.SourceSyncOutcomeTest do
  use SystemsClock.Case, async: true

  alias SalixCalendar.SourceSyncOutcome

  test "persisted provider classifications never retain uncontrolled text" do
    quota =
      SourceSyncOutcome.failure(
        {:google_calendar_rate_limited, 403,
         ["userRateLimitExceeded", "Authorization: Bearer secret"]},
        1
      )

    transport = SourceSyncOutcome.failure({:transport, "Authorization: Bearer secret"}, 2)

    assert get_in(quota, ["reason", "reasons"]) == ["userRateLimitExceeded"]
    assert get_in(transport, ["reason"]) == %{"kind" => "transport", "class" => "external_error"}
    refute inspect([quota, transport]) =~ "Bearer secret"
  end
end
