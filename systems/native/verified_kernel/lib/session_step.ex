defmodule SalixVerifiedKernel.SessionStep do
  @moduledoc """
  The host side of the held values of the session driver (`session_step`,
  `VerifiedKernel.Session.Drive`). The host keeps the large values of a round
  (the loop state and the input of the last loop step that emitted a commit)
  in the machine's `"held"` map. A step receives the machine without them and
  reads one with `{:held, key}`, answered in the external term format: a held
  value can carry host data, such as tool timing structs, that an observation
  cannot. The step returns the held values it changed; they merge into the
  others. An idle machine holds nothing.
  """

  @doc """
  One `session_step` through `query`, a function that runs the query with
  its arguments and a reader. `read` answers the reads other than `{:held,
  key}`. Returns `{machine, effect}`.
  """
  def run(query, machine, event, read) when is_function(query, 2) and is_function(read, 1) do
    {held, sent} = split(machine)

    reader = fn
      {:held, key} -> :erlang.term_to_binary(Map.get(held, key), minor_version: 2)
      request -> read.(request)
    end

    {next, effect} = query.({sent, event, nil}, reader)
    {keep(next, held), effect}
  end

  defp split(nil), do: {%{}, nil}
  defp split(machine), do: Map.pop(machine, "held", %{})

  defp keep(%{"phase" => "idle"} = machine, _held), do: Map.delete(machine, "held")

  defp keep(machine, held),
    do: Map.put(machine, "held", Map.merge(held, Map.get(machine, "held", %{})))
end
