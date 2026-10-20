defmodule Mix.Tasks.Comma.Proactive.Replay do
  @moduledoc """
  Replays recorded proactive cases through the production collection and
  attention code (`CommaWeb.ProactiveReplay`) and prints each scenario's
  outcome and checks.

      mix comma.proactive.replay [CASE.json ...] [--runs 3] [--out report.json]
        [--baseline earlier.json]
        [--judge-cmd "claude -p --model sonnet"]
        [--base-url URL --model MODEL --api-key-env VAR]

  Without a case path, every case under
  `apps/comma_web/test/fixtures/proactive_replay` runs. A judgment calls the
  model through `--judge-cmd`, which reads the prompt on stdin and prints the
  answer, or through an OpenAI-compatible `--base-url`. Without a judge, a
  scenario that needs a judgment reports `no_judge`.
  """
  @shortdoc "Replay recorded proactive cases"

  use Mix.Task

  alias CommaWeb.ProactiveReplay

  @switches [
    runs: :integer,
    out: :string,
    baseline: :string,
    judge_cmd: :string,
    base_url: :string,
    model: :string,
    api_key_env: :string
  ]

  @impl true
  def run(args) do
    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    paths = if paths == [], do: default_cases(), else: paths
    judge = judge(opts)
    runs = opts[:runs] || 1

    reports =
      for path <- paths, kase = ProactiveReplay.load!(path), run <- 1..runs do
        %{"case" => kase["name"], "run" => run, "scenarios" => ProactiveReplay.run(kase, judge)}
      end

    baseline = if opts[:baseline], do: opts[:baseline] |> File.read!() |> Jason.decode!()
    Enum.each(reports, &print(&1, baseline))
    if opts[:out], do: File.write!(opts[:out], Jason.encode!(reports, pretty: true))

    bytes =
      for r <- reports, s <- r["scenarios"], b = get_in(s, ["judgment", "prompt_bytes"]), do: b

    if bytes != [] do
      Mix.shell().info(
        "\njudgment prompts: #{length(bytes)}, mean #{div(Enum.sum(bytes), length(bytes))} bytes, max #{Enum.max(bytes)} bytes"
      )
    end

    failed = for r <- reports, s <- r["scenarios"], c <- s["checks"] || [], not c["pass"], do: c
    Mix.shell().info("\n#{length(failed)} failed check(s)")
  end

  defp default_cases do
    Path.wildcard(Path.join(app_dir(), "test/fixtures/proactive_replay/*.json")) |> Enum.sort()
  end

  defp app_dir, do: Path.expand("../../..", __DIR__)

  defp print(report, baseline) do
    Mix.shell().info("\n== #{report["case"]} (run #{report["run"]})")

    Enum.each(report["scenarios"], fn scenario ->
      judgment = scenario["judgment"] || %{}

      Mix.shell().info("-- #{scenario["scenario"]}")

      if scenario["error"], do: Mix.shell().info("   error: #{scenario["error"]}")

      unrecorded = for q <- scenario["queries"] || [], not q["recorded"], do: q["query"]

      Mix.shell().info(
        "   queries: #{length(scenario["queries"] || [])} (unrecorded: #{inspect(unrecorded)})"
      )

      Mix.shell().info("   collected: #{inspect(scenario["collected"])}")
      Mix.shell().info("   pending: #{inspect(scenario["pending"])}")
      Mix.shell().info("   judgment: #{inspect(Map.drop(judgment, ["message", "linked"]))}")
      if judgment["message"], do: Mix.shell().info("   message: #{judgment["message"]}")

      Enum.each(scenario["checks"] || [], fn check ->
        mark = if check["pass"], do: "PASS", else: "FAIL"
        before = baseline_check(baseline, report, scenario, check)
        Mix.shell().info("   #{mark} #{check["check"]}#{before}")
      end)
    end)
  end

  defp baseline_check(nil, _report, _scenario, _check), do: ""

  defp baseline_check(baseline, report, scenario, check) do
    earlier =
      for r <- baseline,
          r["case"] == report["case"] and r["run"] == report["run"],
          s <- r["scenarios"],
          s["scenario"] == scenario["scenario"],
          c <- s["checks"] || [],
          c["check"] == check["check"],
          do: c["pass"]

    pass = check["pass"]

    case earlier do
      [^pass] -> " (unchanged)"
      [true] -> " (was PASS)"
      [false] -> " (was FAIL)"
      _ -> " (new)"
    end
  end

  defp judge(opts) do
    cond do
      opts[:judge_cmd] -> &command_judge(opts[:judge_cmd], &1)
      opts[:base_url] -> &http_judge(opts, &1)
      true -> fn _messages -> {:error, :no_judge} end
    end
  end

  # The command reads one prompt on stdin: the system and user messages.
  defp command_judge(command, messages) do
    path =
      Path.join(
        System.tmp_dir!(),
        "comma-replay-#{SystemsRuntime.Proc.unique_integer([:positive])}.txt"
      )

    prompt =
      Enum.map_join(messages, "\n\n", fn %{role: role, content: content} ->
        String.upcase(role) <> ":\n" <> content
      end)

    File.write!(path, prompt)

    try do
      case System.cmd("sh", ["-c", "#{command} < #{path}"], stderr_to_stdout: false) do
        {text, 0} -> {:ok, text}
        {text, status} -> {:error, {:judge_exit, status, String.slice(text, 0, 400)}}
      end
    after
      File.rm(path)
    end
  end

  defp http_judge(opts, messages) do
    key = opts[:api_key_env] && System.get_env(opts[:api_key_env])

    Req.post(String.trim_trailing(opts[:base_url], "/") <> "/chat/completions",
      json: %{model: opts[:model], messages: messages},
      auth: key && {:bearer, key},
      receive_timeout: 120_000
    )
    |> case do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:judge_http, status, String.slice(inspect(body), 0, 400)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
