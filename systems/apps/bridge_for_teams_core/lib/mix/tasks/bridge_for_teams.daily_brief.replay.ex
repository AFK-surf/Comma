defmodule Mix.Tasks.BridgeForTeams.DailyBrief.Replay do
  @moduledoc """
  Replays recorded personal daily brief cases offline through `BridgeForTeams.DailyBrief.Replay`.

      mix bridge_for_teams.daily_brief.replay CASE.json [CASE2.json ...]
        [--runs 2] [--out report.json] [--judge-cmd "claude -p --model sonnet"]
  """
  @shortdoc "Replay recorded personal daily brief cases"

  use Mix.Task

  alias BridgeForTeams.DailyBrief.Replay

  @switches [
    runs: :integer,
    out: :string,
    judge_cmd: :string
  ]

  @impl true
  def run(args) do
    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")

    if paths == [] do
      Mix.raise(
        "usage: mix bridge_for_teams.daily_brief.replay CASE.json [--runs N] [--judge-cmd CMD]"
      )
    end

    judge = judge_fn(opts)
    runs = opts[:runs] || 1

    reports =
      for path <- paths, kase = Replay.load!(path), run_idx <- 1..runs do
        %{
          "case" => kase["name"] || Path.basename(path),
          "run" => run_idx,
          "scenarios" => Replay.run(kase, judge)
        }
      end

    Enum.each(reports, &print_report/1)
    if opts[:out], do: File.write!(opts[:out], Jason.encode!(reports, pretty: true))

    failed = for r <- reports, s <- r["scenarios"], c <- s["checks"] || [], not c["pass"], do: c
    Mix.shell().info("\n#{length(failed)} failed check(s)")
  end

  defp print_report(report) do
    Mix.shell().info("\n== #{report["case"]} (run #{report["run"]})")

    Enum.each(report["scenarios"], fn scenario ->
      Mix.shell().info("-- #{scenario["scenario"]}")
      if scenario["error"], do: Mix.shell().info("   error: #{scenario["error"]}")

      Mix.shell().info(
        "   items: #{scenario["item_count"] || 0}, mine: #{length(scenario["mine"] || [])}"
      )

      Enum.each(scenario["checks"] || [], fn check ->
        mark = if check["pass"], do: "PASS", else: "FAIL"
        Mix.shell().info("   #{mark} #{check["check"]}")
      end)
    end)
  end

  defp judge_fn(opts) do
    case opts[:judge_cmd] do
      cmd when is_binary(cmd) ->
        fn %{view: view, input: input} ->
          path =
            Path.join(
              System.tmp_dir!(),
              "bft-brief-replay-#{SystemsRuntime.Proc.unique_integer([:positive])}.json"
            )

          File.write!(path, Jason.encode!(%{"view" => view, "input" => input}))

          try do
            case System.cmd("sh", ["-c", "#{cmd} < #{path}"], stderr_to_stdout: false) do
              {text, 0} -> {:ok, text}
              {text, status} -> {:error, {:judge_exit, status, String.slice(text, 0, 400)}}
            end
          after
            File.rm(path)
          end
        end

      nil ->
        fn %{view: view} ->
          if view == :mine, do: {:ok, ~s({"items":[]})}, else: {:ok, "replay ok"}
        end
    end
  end
end
