defmodule SalixIM.Triage.WorkerSelection do
  @moduledoc """
  Assigns ordinary intake to its frozen dedicated Worker.

  The source projection resolves the domain-owned Worker before freezing.
  Historical model decisions retain alias restoration from their sealed roster.
  Admission still checks current project and Agent authority.
  """

  @kind "available_investigation_worker"

  def kind, do: @kind

  def refs(memory) when is_map(memory) do
    memory
    |> Map.get("facts", [])
    |> Enum.filter(&(&1["kind"] == @kind))
    |> Enum.map(& &1["source_ref"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def refs(_memory), do: []

  def validate(decision, memory) when is_map(decision) do
    available = refs(memory)

    if Enum.all?(decision["delegations"] || [], &(&1["worker_ref"] in available)),
      do: :ok,
      else: {:error, :invalid_investigation_worker}
  end

  # Fresh ordinary batches always reach a Worker. Historical decisions and
  # scheduled reminder settlement keep their frozen decision contract.
  def intake?(context) when is_map(context) do
    mode = get_in(context, ["identity_context", "source_mode"])

    mode in ~w(callback clickhouse_etl periodic_patrol) and
      SalixIM.Triage.ProductDecision.target_route(context["slack_context"], mode) == "none"
  end

  def intake?(_), do: false

  # Ordinary intake has one domain-owned Worker. The Worker decides whether
  # to participate after reading the current source; no model selects an Agent.
  def assignment(%{"snapshot" => context}) do
    with true <- intake?(context),
         [worker_ref] <- refs(context["team_project_memory"]),
         %{"source_ref" => source_ref} when is_binary(source_ref) <-
           get_in(context, ["slack_context", "decision_target"]) do
      {:ok,
       %{
         "schema" => "comma.triage-product-decision.v2",
         "communication" => pending_communication(),
         "companion_reaction" => nil,
         "context_candidates" => [],
         "delegations" => [
           %{
             "task" =>
               "Read the current source and decide whether to reply, react, investigate, follow up, or remain silent.",
             "worker_ref" => worker_ref,
             "source_refs" => [source_ref]
           }
         ],
         "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
       }}
    else
      _ -> {:error, :triage_worker_unavailable}
    end
  end

  def assignment(_), do: {:error, :triage_worker_unavailable}

  def pending_communication do
    %{
      "kind" => "silence",
      "reason" => "worker_pending",
      "explanation" => "The assigned Worker owns the participation decision.",
      "source_refs" => []
    }
  end

  def validate_intake(decision, context) do
    if intake?(context) do
      with [_] <- decision["delegations"],
           true <- decision["communication"] == pending_communication(),
           nil <- decision["companion_reaction"],
           [] <- decision["context_candidates"],
           :ok <- validate(decision, context["team_project_memory"]) do
        :ok
      else
        _ -> {:error, :invalid_triage_worker_assignment}
      end
    else
      :ok
    end
  end

  def restore(delegations, raw_memory, aliases) do
    available = refs(raw_memory)
    by_alias = Map.new(aliases, fn {raw, projected} -> {projected, raw} end)

    Enum.reduce_while(delegations, {:ok, []}, fn delegation, {:ok, acc} ->
      # Already committed decisions predate Worker selection. New model output
      # must have a closed Worker ref before it reaches this materializer.
      case Map.fetch(delegation, "worker_ref") do
        :error ->
          {:cont, {:ok, [delegation | acc]}}

        {:ok, selected} ->
          case Map.fetch(by_alias, selected) do
            {:ok, "comma-agent://" <> worker_id = ref} when worker_id != "" ->
              if ref in available,
                do: {:cont, {:ok, [Map.put(delegation, "worker_ref", ref) | acc]}},
                else: {:halt, {:error, :invalid_investigation_worker}}

            _ ->
              {:halt, {:error, :invalid_investigation_worker}}
          end
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      error -> error
    end
  end
end
