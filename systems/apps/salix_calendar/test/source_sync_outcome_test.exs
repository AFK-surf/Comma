defmodule SalixCalendar.SourceSyncOutcomeTest do
  use ExUnit.Case, async: true

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

  test "retaining an older outcome sanitizes previously stored external text" do
    retained =
      SourceSyncOutcome.retain_failure(%{}, %{
        "last_outcome" => %{
          "status" => "error",
          "attempted_at" => 3,
          "reason" => %{
            "kind" => "transport",
            "class" => "Authorization: Bearer legacy-secret"
          }
        }
      })

    assert get_in(retained, ["last_outcome", "reason"]) == %{
             "kind" => "transport",
             "class" => "external_error"
           }

    refute inspect(retained) =~ "legacy-secret"
  end

  test "replacement sync state retains an unsettled attempt until settlement" do
    retained =
      SourceSyncOutcome.retain_state(%{}, %{
        "settlement_pending" => true
      })

    assert retained == %{"settlement_pending" => true}
    assert SourceSyncOutcome.unsettled?(%{"sync" => retained})

    settled = SourceSyncOutcome.clear_unsettled(retained)

    assert settled == %{}
    refute SourceSyncOutcome.unsettled?(%{"sync" => settled})
  end
end
