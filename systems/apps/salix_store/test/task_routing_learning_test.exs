defmodule SalixStore.TaskRoutingLearningTest do
  use SystemsClock.Case, async: false
  alias SalixStore.TaskRoutingLearning, as: Store

  test "concurrent feedback commits each Task once and receipts outlive the bounded evidence window" do
    group = SalixStore.Ids.new_tenant_id() |> SalixStore.Ids.new_group_id()
    initial = %{"revision" => 0, "observations" => []}
    observation = %{"outcome" => "completed"}

    update = fn state, sample ->
      %{"revision" => state["revision"] + 1, "observations" => [sample]}
    end

    results =
      1..16
      |> Task.async_stream(
        fn index ->
          Store.record(group, "generation", "task-#{rem(index, 4)}", observation, initial, update)
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))

    assert {:ok, %{"revision" => 4, "observations" => [^observation]}} =
             Store.get(group, "generation", initial)

    assert {:ok, %{duplicate: true}} =
             Store.record(group, "generation", "task-1", observation, initial, update)

    assert {:error, {:conflict, _}} =
             Store.record(
               group,
               "generation",
               "task-1",
               %{"outcome" => "timeout"},
               initial,
               update
             )

    assert {:ok, %{"revision" => 4}} = Store.get(group, "generation", initial)
    assert {:ok, ^initial} = Store.get(group, "other-generation", initial)

    assert {:error, :interrupted_update} =
             Store.record(group, "generation", "interrupted", observation, initial, fn _, _ ->
               SalixStore.Repo.rollback(:interrupted_update)
             end)

    assert {:ok, %{duplicate: false, state: %{"revision" => 5}}} =
             Store.record(group, "generation", "interrupted", observation, initial, update)

    assert :ok = Store.delete_group(group)
    assert {:ok, ^initial} = Store.get(group, "generation", initial)
  end
end
