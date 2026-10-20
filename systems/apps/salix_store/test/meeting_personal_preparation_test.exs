defmodule SalixStore.MeetingPersonalPreparationTest do
  use SystemsClock.Case, async: false

  alias SalixStore.MeetingPersonalPreparation, as: Store

  setup do
    id = SystemsRuntime.Proc.unique_integer([:positive]) |> to_string()
    {:ok, identity: ["personal-group-" <> id, "personal-plan-" <> id, "revision"]}
  end

  test "research completion requires saved review outcomes, including no supported advice", %{
    identity: identity
  } do
    assert :ok = Store.ensure_roster(identity, ["a@example.com", "b@example.com"])
    assert {:ok, _} = Store.ensure(identity, [%{"user_id" => "UA"}, %{"user_id" => "UB"}], 0)
    assert {:ok, true} = Store.has_pending?(identity)
    assert {:ok, false} = Store.research_complete?(identity)

    assert {:ok, "prepared"} =
             Store.save_report(identity, "UB", %{
               "status" => "prepared",
               "text" => "B's preparation"
             })

    assert {:ok, false} = Store.research_complete?(identity)

    assert {:ok, "prepared"} =
             Store.save_report(identity, "UA", %{
               "status" => "prepared",
               "review_outcome" => "no_supported_action",
               "text" => nil
             })

    assert {:ok, false} = Store.research_complete?(identity)
    complete_group_scan(identity)
    assert {:ok, true} = Store.research_complete?(identity)

    assert {:ok, [%{"user_id" => "UA"}, %{"user_id" => "UB"}]} =
             Store.pending(identity, SystemsClock.system_time(:millisecond))

    # Later retries cannot replace either first review outcome.
    assert {:ok, "prepared"} =
             Store.save_report(identity, "UA", %{"status" => "prepared", "text" => "later draft"})

    assert {:ok, "prepared"} = Store.save_report(identity, "UB", %{"status" => "skipped"})

    assert {:ok, %{"report" => %{"text" => nil, "review_outcome" => "no_supported_action"}}} =
             Store.get_recipient(identity, "UA")

    assert {:ok, %{"report" => %{"text" => "B's preparation"}}} =
             Store.get_recipient(identity, "UB")
  end

  defp complete_group_scan(identity) do
    case Store.group_scan_page(identity) do
      {:ok, :complete} ->
        :ok

      {:ok, %{"cursor" => cursor, "next_cursor" => next_cursor}} ->
        assert :ok = Store.append_group_members(identity, cursor, next_cursor, [])
        complete_group_scan(identity)
    end
  end
end
