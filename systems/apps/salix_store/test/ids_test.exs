defmodule SalixStore.IdsTest do
  use SystemsClock.Case, async: false

  import Bitwise

  alias SalixStore.Ids

  @worker_shift 12
  @worker_mask (1 <<< 10) - 1

  test "serving ordinals and reserved workload ids generate disjoint Snowflakes" do
    worker_ids = [0, 1, 2, 1021, 1022, 1023]

    generated =
      for worker_id <- worker_ids, into: %{} do
        {:ok, state} = Ids.init(worker_id: worker_id)

        {bodies, _state} =
          Enum.map_reduce(1..256, state, fn _, current ->
            {:reply, body, next} =
              Ids.handle_call(:next_body, SystemsRuntime.Proc.self(), current)

            {body, next}
          end)

        assert Enum.all?(bodies, &(encoded_worker_id(&1) == worker_id))
        {worker_id, MapSet.new(bodies)}
      end

    all_bodies = generated |> Map.values() |> Enum.reduce(&MapSet.union/2)
    assert MapSet.size(all_bodies) == length(worker_ids) * 256
  end

  defp encoded_worker_id(body) do
    body
    |> String.to_integer()
    |> bsr(@worker_shift)
    |> band(@worker_mask)
  end
end
