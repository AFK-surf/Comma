defmodule SalixStore.IdsTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SalixStore.Ids

  @worker_shift 12
  @worker_mask (1 <<< 10) - 1

  test "tool result refs are opaque canonical ids" do
    ref = Ids.new_tool_result_ref()

    assert String.starts_with?(ref, "trf1_")
    assert Ids.valid_tool_result_ref?(ref)
    refute Ids.valid_tool_result_ref?("trf1_not-a-snowflake")
    refute Ids.valid_tool_result_ref?(Ids.new_session_id())
  end

  test "serving ordinals and reserved workload ids generate disjoint Snowflakes" do
    worker_ids = [0, 1, 2, 1021, 1022, 1023]

    generated =
      for worker_id <- worker_ids, into: %{} do
        {:ok, state} = Ids.init(worker_id: worker_id)

        {bodies, _state} =
          Enum.map_reduce(1..256, state, fn _, current ->
            {:reply, body, next} = Ids.handle_call(:next_body, self(), current)
            {body, next}
          end)

        assert Enum.all?(bodies, &(encoded_worker_id(&1) == worker_id))
        {worker_id, MapSet.new(bodies)}
      end

    all_bodies = generated |> Map.values() |> Enum.reduce(&MapSet.union/2)
    assert MapSet.size(all_bodies) == length(worker_ids) * 256
  end

  test "missing, unknown, and out-of-range worker ids fail closed" do
    previous = Application.get_env(:salix_store, :snowflake_worker_id)
    Application.delete_env(:salix_store, :snowflake_worker_id)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_store, :snowflake_worker_id),
        else: Application.put_env(:salix_store, :snowflake_worker_id, previous)
    end)

    assert_raise ArgumentError, "SALIX_SNOWFLAKE_WORKER_ID is required", fn ->
      Ids.init([])
    end

    for invalid <- ["unknown", -1, 1024] do
      assert_raise ArgumentError, fn -> Ids.init(worker_id: invalid) end
    end
  end

  defp encoded_worker_id(body) do
    body
    |> String.to_integer()
    |> bsr(@worker_shift)
    |> band(@worker_mask)
  end
end
