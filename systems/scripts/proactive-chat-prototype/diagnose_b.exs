# Repeat fixed B cases with bounded, content-free wire diagnostics.
[config_path, corpus_path, output] = System.argv()
Application.ensure_all_started(:req)
Logger.configure(level: :error)
Code.require_file("compare_support.exs", __DIR__)
config = File.read!(config_path) |> Jason.decode!()
cases = File.read!(corpus_path) |> Jason.decode!() |> Map.fetch!("results")
rounds = String.to_integer(System.get_env("MAIL_COMPARE_REPEATS", "3"))
rows = for round <- 1..rounds, row <- cases, do: {round, row}

results =
  rows
  |> Task.async_stream(
    fn {round, row} ->
      gate = CompareMail.jev(Map.delete(row["input"], "home"), config["decide"])

      result =
        if gate.choice == "notify",
          do: CompareMail.router(row["input"], config["llm"]),
          else: %{choice: gate.choice, ms: 0, text: ""}

      %{
        round: round,
        name: row["name"],
        expected: row["expected"],
        gate: gate,
        result: result,
        passed: result.choice == row["expected"]
      }
    end,
    max_concurrency: 2,
    timeout: 120_000,
    ordered: true
  )
  |> Enum.map(fn {:ok, r} -> r end)

File.write!(
  output,
  Jason.encode!(%{max_tokens: System.get_env("MAIL_COMPARE_MAX_TOKENS", "512"), results: results},
    pretty: true
  )
)

IO.puts(
  Jason.encode!(
    %{
      total: length(results),
      passed: Enum.count(results, & &1.passed),
      failures: Enum.reject(results, & &1.passed)
    },
    pretty: true
  )
)
