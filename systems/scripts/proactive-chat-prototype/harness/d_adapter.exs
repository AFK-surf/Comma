Code.require_file(System.get_env("MAIL_HARNESS_D_RUNTIME") || "d_runtime.exs", __DIR__)

defmodule MailHarness.DAdapter do
  # Frozen generated code is a regression probe, not another cold-generation trial.
  def prepare(source) do
    {:ok, _} = SalixAgent.Loops.Host.start_link(reconciler: nil)

    available =
      Enum.any?(1..200, fn _ ->
        if SalixAgent.Loops.Host.status().available,
          do: true,
          else:
            (
              Process.sleep(25)
              false
            )
      end)

    unless available, do: raise("D runtime unavailable")

    case CompareD.compile(source) do
      {:ok, %{"state" => "succeeded", "result" => %{"elf" => encoded}}} -> Base.decode64!(encoded)
      _ -> raise("D compile failed; no benchmark rows emitted")
    end
  end

  def run(elf, rows, providers, config) do
    Process.put(:mail_harness_stages, [])

    wrapped =
      Map.merge(config, %{
        on_case: fn id -> Process.put(:mail_harness_case, id) end,
        decide_fun: fn args ->
          stage = MailHarness.decide(args, providers)
          record(stage)

          if stage.status == "ok",
            do: {:ok, stage.answer, %{}},
            else: {:error, :benchmark_provider_error}
        end,
        router_fun: fn state ->
          stage = MailHarness.router(state, providers)
          record(stage)
          Map.put(stage, :choice, stage.choice || "error")
        end
      })

    # One runtime object per corpus pass: state can survive between events.
    runtime_rows = Enum.map(rows, &Map.merge(&1, %{"name" => &1["id"]}))
    results = CompareD.run(elf, runtime_rows, wrapped)
    stages = Process.get(:mail_harness_stages, []) |> Enum.reverse()
    # The runtime adapter verifies each event/source ID before it returns input.
    Enum.zip(rows, results)
    |> Enum.map(fn {row, result} ->
      own = Enum.filter(stages, &(&1.case_id == row["id"]))
      router = own |> Enum.filter(&(&1.provider == "router")) |> List.last()

      valid_flow =
        Map.get(result, :terminal) == nil and result.choice in ~w(notify quiet defer) and
          (router == nil or router.choice == result.choice) and
          result.acked == (result.notify_count > 0 or result.choice == "quiet") and
          Enum.any?(own, &(&1.provider == "jev" and &1.status == "ok")) and
          Enum.all?(own, &(&1.status == "ok"))

      final =
        cond do
          not valid_flow ->
            %{status: "error", choice: nil, error: %{kind: "runtime", code: "incomplete_flow"}}

          router ->
            router

          result.choice in ~w(quiet defer) ->
            %{status: "ok", choice: result.choice}

          true ->
            %{status: "error", choice: nil, error: %{kind: "runtime", code: "missing_publisher"}}
        end

      MailHarness.finish("d", row, final, own, result.ms, %{
        runtime: Map.take(result, [:calls, :acked, :choice, :notify_count])
      })
    end)
  end

  defp record(stage) do
    tagged = Map.put(stage, :case_id, Process.get(:mail_harness_case))
    Process.put(:mail_harness_stages, [tagged | Process.get(:mail_harness_stages, [])])
  end
end
