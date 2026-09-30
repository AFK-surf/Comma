defmodule SalixVerifiedKernel.SessionStepHeldTest do
  use ExUnit.Case, async: true

  alias SalixVerifiedKernel.SessionStep

  # A stand-in for `session_step`: it records the machine it receives, reads
  # the held keys that `reads` names, and returns `reply`.
  defp query(reads, reply) do
    fn {machine, _event, nil}, read ->
      send(self(), {:sent, machine})
      send(self(), {:read, Map.new(reads, &{&1, :erlang.binary_to_term(read.({:held, &1}))})})
      reply
    end
  end

  test "held values stay on the host, answer later reads, and end with the idle machine" do
    read = fn :clock -> 1 end

    changed = %{"phase" => "loop_io", "held" => %{"loop" => :state1, "loop_in" => :input1}}
    {machine, :notify} = SessionStep.run(query([], {changed, :notify}), nil, :start, read)
    assert machine["held"] == %{"loop" => :state1, "loop_in" => :input1}

    # The next step receives the machine without the held values, reads them
    # from the host, and changes one of them.
    next = %{"phase" => "loop_io", "held" => %{"loop" => :state2}}

    {machine, :commit} =
      SessionStep.run(query(["loop_in"], {next, :commit}), machine, :done, read)

    assert_received {:sent, %{"phase" => "loop_io"} = sent}
    refute Map.has_key?(sent, "held")
    assert_received {:read, %{"loop_in" => :input1}}
    assert machine["held"] == %{"loop" => :state2, "loop_in" => :input1}

    # A step that reads no held value leaves them as they are.
    same = %{"phase" => "loop_io"}
    {machine, :notify} = SessionStep.run(query([], {same, :notify}), machine, :done, read)
    assert machine["held"] == %{"loop" => :state2, "loop_in" => :input1}

    {idle, :idle} =
      SessionStep.run(query([], {%{"phase" => "idle"}, :idle}), machine, :done, read)

    refute Map.has_key?(idle, "held")
  end

  test "other reads go to the host's reader" do
    reply = {%{"phase" => "idle"}, :idle}

    query = fn {nil, :start, nil}, read ->
      send(self(), {:clock, read.(:clock)})
      reply
    end

    assert {%{"phase" => "idle"}, :idle} = SessionStep.run(query, nil, :start, fn :clock -> 7 end)
    assert_received {:clock, 7}
  end
end
