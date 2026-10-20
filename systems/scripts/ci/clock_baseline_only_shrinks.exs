# Fails when the head baseline of `mix systems.clock_calls` admits a call that
# the base baseline did not: the baseline may only lose entries.
#
#     elixir scripts/ci/clock_baseline_only_shrinks.exs BASE_FILE HEAD_FILE
[base_file, head_file] = System.argv()
{base, _} = Code.eval_file(base_file)
{head, _} = Code.eval_file(head_file)

added =
  for {module, calls} <- Enum.sort(head),
      call <- calls,
      call not in Map.get(base, module, []),
      do: "  #{module}: #{call}"

if added != [] do
  IO.puts(:stderr, """
  The clock call baseline gained entries:

  #{Enum.join(added, "\n")}

  Read time and arm timers through SystemsClock instead of admitting a call.
  """)

  System.halt(1)
end
