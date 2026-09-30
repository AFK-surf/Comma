# D: real model-generated integer C, real compiler/runtime, isolated host adapters.
# No workspace DB, real inbox, publisher, or Router Session is started.
[config_path, corpus_path, output_dir] = System.argv()
Application.ensure_all_started(:req)
Logger.configure(level: :error)
Code.require_file("compare_support.exs", __DIR__)
config = File.read!(config_path) |> Jason.decode!()
cases = File.read!(corpus_path) |> Jason.decode!() |> Map.fetch!("results")
File.mkdir_p!(output_dir)

Code.require_file("harness/d_runtime.exs", __DIR__)

{:ok, _} = SalixAgent.Loops.Host.start_link(reconciler: nil)
# Host initialize only; no product supervisors or stores.
Enum.reduce_while(1..200, nil, fn _, _ ->
  if SalixAgent.Loops.Host.status().available,
    do: {:halt, :ok},
    else:
      (
        Process.sleep(25)
        {:cont, nil}
      )
end)

trials = String.to_integer(System.get_env("MAIL_D_TRIALS", "3"))

results =
  Enum.map(1..trials, fn trial ->
    generation_config =
      Map.put(config["llm"], "experiment_trial", "#{Path.basename(output_dir)}-#{trial}")

    {:ok, source, ms} = CompareD.generate(generation_config)
    File.write!(Path.join(output_dir, "generated-#{trial}-first.c"), source)

    attempt = fn source ->
      case CompareD.compile(source) do
        {:ok, %{"state" => "succeeded", "result" => %{"elf" => encoded}}} ->
          %{compiled: true, results: CompareD.run(Base.decode64!(encoded), cases, config)}

        error ->
          %{compiled: false, error: inspect(error, limit: 30, printable_limit: 3000)}
      end
    end

    first = attempt.(source)
    failed = not first.compiled or Enum.any?(first.results, &(!&1.passed))

    repair =
      if failed do
        feedback = Jason.encode!(first)

        case CompareD.generate(generation_config, feedback, source) do
          {:ok, fixed, repair_ms} ->
            File.write!(Path.join(output_dir, "generated-#{trial}-repair.c"), fixed)
            Map.put(attempt.(fixed), :generation_ms, repair_ms)

          _ ->
            %{compiled: false, error: "repair generation failed"}
        end
      end

    result = %{trial: trial, generation_ms: ms, first: first, repair: repair}
    File.write!(Path.join(output_dir, "trial-#{trial}.json"), Jason.encode!(result, pretty: true))

    IO.puts(
      Jason.encode!(%{
        trial: trial,
        compiled: first.compiled,
        first_passes: Enum.count(first[:results] || [], & &1.passed),
        repair_passes: if(repair, do: Enum.count(repair[:results] || [], & &1.passed))
      })
    )

    result
  end)

File.write!(
  Path.join(output_dir, "results.json"),
  Jason.encode!(
    %{
      scope:
        "Actual generated C, compiler and runtime. Source/ACK/notification adapters isolated; real Jev and Router-model calls. No product durability/authorization/UI claim. Three independent generations, at most one feedback repair each; no manual source fixes.",
      trials: results
    },
    pretty: true
  )
)
