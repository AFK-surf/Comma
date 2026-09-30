Code.require_file("core.exs", __DIR__)
[input, output] = System.argv()
File.mkdir!(output)
corpus = File.read!(Path.join(input, "corpus.json")) |> Jason.decode!()
cases = Map.new(corpus["cases"], &{&1["id"], &1})

atom_keys = fn map ->
  Map.new(map, fn {k, v} -> {if(is_atom(k), do: k, else: String.to_existing_atom(k)), v} end)
end

rows =
  File.read!(Path.join(input, "rows.jsonl"))
  |> String.split("\n", trim: true)
  |> Enum.map(fn line ->
    raw = Jason.decode!(line)
    row = atom_keys.(raw)

    stages =
      Enum.map(row.stages, fn raw_stage ->
        stage = atom_keys.(raw_stage)
        evidence_usage = get_in(raw_stage, ["provider_evidence", "usage"])

        stage =
          if stage.usage == nil and is_map(evidence_usage) do
            Map.put(stage, :usage, %{
              input_tokens: evidence_usage["input_tokens"],
              output_tokens: evidence_usage["output_tokens"],
              cached_input_tokens: nil
            })
          else
            stage
          end

        if is_map(stage.usage), do: Map.put(stage, :usage, atom_keys.(stage.usage)), else: stage
      end)

    error = if row.error, do: atom_keys.(row.error)

    %{
      row
      | stages: stages,
        error: error,
        score:
          MailHarness.score(
            cases[row.case_id],
            %{status: row.status, choice: row.choice},
            row.output
          )
    }
  end)

File.cp!(Path.join(input, "corpus.json"), Path.join(output, "corpus.json"))

manifest =
  File.read!(Path.join(input, "manifest.json"))
  |> Jason.decode!()
  |> Map.put("rescore", %{
    source: input,
    reason:
      "Clock numerals 三点/3点 are equivalent. Retain usage from rejected responses when captured. No labels, model requests or responses changed."
  })

File.write!(Path.join(output, "manifest.json"), Jason.encode!(manifest, pretty: true))
File.write!(Path.join(output, "rows.jsonl"), Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")

File.write!(
  Path.join(output, "summary.json"),
  Jason.encode!(MailHarness.summary(rows), pretty: true)
)
