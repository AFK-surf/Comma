defmodule SalixStore.MeetingPersonalPreparationTest do
  use ExUnit.Case, async: false

  alias SalixStore.MeetingPersonalPreparation, as: Store

  setup do
    id = System.unique_integer([:positive]) |> to_string()
    {:ok, identity: ["personal-group-" <> id, "personal-plan-" <> id, "revision"]}
  end

  test "empty recipient pages still require complete roster discovery", %{identity: identity} do
    assert {:ok, false} = Store.research_complete?(identity)
    assert :ok = Store.ensure_roster(identity, Enum.map(1..41, &"person#{&1}@example.com"))
    assert {:ok, _} = Store.ensure(identity, [], 0)
    assert {:ok, false} = Store.research_complete?(identity)
    assert {:error, :personal_preparation_page_out_of_order} = Store.ensure(identity, [], 40)
    assert {:ok, _} = Store.ensure(identity, [], 20)
    assert {:ok, false} = Store.research_complete?(identity)
    assert {:ok, _} = Store.ensure(identity, [%{"user_id" => "ULAST"}], 40)
    assert {:ok, false} = Store.research_complete?(identity)

    assert {:ok, "prepared"} =
             Store.save_report(identity, "ULAST", %{
               "status" => "prepared",
               "text" => "Read this source"
             })

    assert {:ok, false} = Store.research_complete?(identity)
    complete_group_scan(identity)
    assert {:ok, true} = Store.research_complete?(identity)
    assert {:ok, true} = Store.has_pending?(identity)
    # Re-reading an earlier page cannot reset progress or the saved report.
    assert {:ok, _} = Store.ensure(identity, [], 0)
    assert {:ok, true} = Store.research_complete?(identity)
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
             Store.pending(identity, System.system_time(:millisecond))

    # Later retries cannot replace either first review outcome.
    assert {:ok, "prepared"} =
             Store.save_report(identity, "UA", %{"status" => "prepared", "text" => "later draft"})

    assert {:ok, "prepared"} = Store.save_report(identity, "UB", %{"status" => "skipped"})

    assert {:ok, %{"report" => %{"text" => nil, "review_outcome" => "no_supported_action"}}} =
             Store.get_recipient(identity, "UA")

    assert {:ok, %{"report" => %{"text" => "B's preparation"}}} =
             Store.get_recipient(identity, "UB")
  end

  test "reminder admission drains more than a page without completing research", %{
    identity: identity
  } do
    users = Enum.map(1..29, &("U" <> String.pad_leading(to_string(&1), 2, "0")))
    assert {:ok, 0} = Store.discovery_cursor(identity)
    assert :ok = Store.ensure_roster(identity, Enum.map(users, &(&1 <> "@example.com")))

    for {page, index} <- users |> Enum.chunk_every(20) |> Enum.with_index() do
      assert {:ok, index * 20} == Store.discovery_cursor(identity)
      assert {:ok, _} = Store.ensure(identity, Enum.map(page, &%{"user_id" => &1}), index * 20)
    end

    assert {:ok, 29} = Store.discovery_cursor(identity)
    complete_group_scan(identity)
    assert {:ok, nil} = Store.discovery_cursor(identity)
    assert :ok = Store.admit_reminders(identity)
    assert {:ok, first} = Store.pending(identity, System.system_time(:millisecond))
    assert length(first) == 20

    for recipient <- first,
        do: assert(:ok = Store.settle(identity, recipient["user_id"], "queued"))

    assert {:ok, true} = Store.has_pending?(identity)
    assert :ok = Store.admit_reminders(identity)
    assert {:ok, second} = Store.pending(identity, System.system_time(:millisecond))
    assert length(second) == 9

    for recipient <- second,
        do: assert(:ok = Store.settle(identity, recipient["user_id"], "queued"))

    assert {:ok, false} = Store.has_pending?(identity)
    assert {:ok, false} = Store.research_complete?(identity)
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
