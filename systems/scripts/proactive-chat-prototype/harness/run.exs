# Run only fictional corpora. No app supervision trees or publisher are started.
Code.require_file("core.exs", __DIR__)
Code.require_file("providers.exs", __DIR__)

{opts, _, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      config: :string,
      corpus: :string,
      output: :string,
      rounds: :integer,
      variants: :string,
      d_source: :string
    ]
  )

if invalid != [], do: raise("unknown options")

corpus =
  opts
  |> Keyword.fetch!(:corpus)
  |> File.read!()
  |> Jason.decode!()
  |> MailHarness.validate_corpus!()

variants = String.split(opts[:variants] || "a,b,c", ",")

unless Enum.all?(variants, &(&1 in ~w(a b c b_context d))) and
         length(Enum.uniq(variants)) == length(variants),
       do: raise("invalid variants")

rounds = opts[:rounds] || 1
unless rounds in 1..5, do: raise("rounds must be 1-5")
output = Keyword.fetch!(opts, :output)
# Refuse overwrite: failed and successful runs remain separate.
File.mkdir!(output)
File.write!(Path.join(output, "corpus.json"), Jason.encode!(corpus, pretty: true))
config = opts |> Keyword.fetch!(:config) |> File.read!() |> Jason.decode!()
{:ok, _} = Application.ensure_all_started(:req)
Logger.configure(level: :error)
providers = MailHarness.Providers.live(config)

manifest = %{
  version: 1,
  started_at: DateTime.utc_now(),
  prompts: MailHarness.prompts(),
  models: %{jev: config["decide"]["model"], router: config["llm"]["model"]},
  router_options: %{max_tokens: 1024, reasoning_effort: "low", transport_retry: false},
  variants: variants,
  rounds: rounds,
  per_trial_timeout_ms: 60_000,
  scope:
    "Synthetic decision benchmark; output contract is experimental, not product delivery. No application retries. Cache state uncontrolled. D uses frozen generated source, not cold generation."
}

File.write!(Path.join(output, "manifest.json"), Jason.encode!(manifest, pretty: true))

elf =
  if "d" in variants do
    Code.require_file("d_adapter.exs", __DIR__)
    source = File.read!(Keyword.fetch!(opts, :d_source))
    File.write!(Path.join(output, "d-source.c"), source)
    MailHarness.DAdapter.prepare(source)
  end

cases = corpus["cases"]

rows =
  for round <- 1..rounds, reduce: [] do
    accumulated ->
      # Rotate variant order and reverse cases every other round to reduce order bias.
      ordered = if rem(round, 2) == 0, do: Enum.reverse(cases), else: cases
      names = Enum.reject(variants, &(&1 == "d"))

      trials =
        for {row, index} <- Enum.with_index(ordered),
            name <-
              Enum.drop(names, rem(index + round - 1, max(length(names), 1))) ++
                Enum.take(names, rem(index + round - 1, max(length(names), 1))),
            do: {row, name}

      regular =
        trials
        |> Task.async_stream(fn {row, name} -> MailHarness.run(name, row, providers) end,
          max_concurrency: 2,
          timeout: 60_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(trials)
        |> Enum.map(fn {reply, {row, name}} ->
          result =
            case reply do
              {:ok, value} ->
                value

              {:exit, _} ->
                MailHarness.finish(
                  name,
                  row,
                  %{
                    status: "error",
                    choice: nil,
                    error: %{kind: "harness", code: "trial_timeout_or_exit"}
                  },
                  [],
                  60_000
                )
            end

          result = Map.put(result, :round, round)
          File.write!(Path.join(output, "rows.jsonl"), Jason.encode!(result) <> "\n", [:append])
          result
        end)

      d =
        if elf do
          MailHarness.DAdapter.run(elf, ordered, providers, config)
          |> Enum.map(fn row ->
            row = Map.put(row, :round, round)
            File.write!(Path.join(output, "rows.jsonl"), Jason.encode!(row) <> "\n", [:append])
            row
          end)
        else
          []
        end

      accumulated ++ regular ++ d
  end

summary = MailHarness.summary(rows)
File.write!(Path.join(output, "summary.json"), Jason.encode!(summary, pretty: true))

File.write!(
  Path.join(output, "drafts.json"),
  Jason.encode!(
    Enum.map(
      rows,
      &Map.take(&1, [:case_id, :round, :variant, :expected, :choice, :output, :score])
    ),
    pretty: true
  )
)

File.write!(
  Path.join(output, "completed.json"),
  Jason.encode!(
    %{
      finished_at: DateTime.utc_now(),
      expected_rows: length(cases) * rounds * length(variants),
      actual_rows: length(rows),
      all_trials_settled: true
    },
    pretty: true
  )
)

IO.puts(Jason.encode!(summary, pretty: true))
if Enum.any?(rows, &(&1.status == "error")), do: System.halt(2)
# A valid, scored quality failure is data, not a harness crash. Inspect summary.
