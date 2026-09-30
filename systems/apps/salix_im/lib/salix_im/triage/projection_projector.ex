defmodule SalixIM.Triage.ProjectionProjector do
  @moduledoc """
  Bounded, idempotent convergence for authoritative-run query projections.

  The authoritative PostgreSQL transaction commits the terminal fence, run,
  replay and this work obligation before this projector runs. A projector
  outage can therefore delay lookups, but it cannot revoke or hide the
  authoritative result. Every derived write is create-once and safe to retry.
  """

  alias SalixIM.Triage.{Ledger, RunFence}
  alias SalixIM.Triage.RunFence.AuthorizedProjection
  alias SalixStore.{CasRecord, TriageKeys, TriageTransactions}

  @max_batch 100

  @type stats :: %{
          fetched: non_neg_integer(),
          applied: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Projects one bounded oldest-first page for an exact namespace."
  @spec converge(String.t(), pos_integer()) ::
          {:ok, stats()} | {:error, :invalid | :unavailable}
  def converge(namespace, limit)
      when is_binary(namespace) and namespace != "" and
             is_integer(limit) and limit > 0 and limit <= @max_batch do
    namespace_key = TriageKeys.namespace_key(namespace)

    with {:ok, obligations} <-
           TriageTransactions.pending_projection_obligations(namespace_key, limit) do
      stats =
        Enum.reduce(
          obligations,
          %{fetched: length(obligations), applied: 0, failed: 0},
          &project_and_settle(&1, namespace, &2)
        )

      {:ok, stats}
    end
  end

  def converge(_namespace, _limit), do: {:error, :invalid}

  defp project_and_settle(obligation, namespace, stats) do
    case project(obligation, namespace) do
      :ok ->
        case TriageTransactions.mark_projection_applied(
               obligation.namespace_key,
               obligation.run_id
             ) do
          :ok -> Map.update!(stats, :applied, &(&1 + 1))
          {:error, reason} -> fail(obligation, reason, stats)
        end

      {:error, reason} ->
        fail(obligation, reason, stats)
    end
  end

  defp project(
         %{
           namespace_key: namespace_key,
           run_id: run_id,
           payload: %{
             "schema" => "comma.triage-projection-obligation.v1",
             "namespace" => namespace,
             "fence_key" => fence_key,
             "run_id" => run_id,
             "correlations" => correlations,
             "activity_required" => activity_required,
             "time_required" => true
           }
         },
         namespace
       )
       when is_binary(fence_key) and fence_key != "" and is_list(correlations) do
    with true <- namespace_key == TriageKeys.namespace_key(namespace),
         {:ok, fence} <- CasRecord.get(fence_key),
         true <- fence["run_id"] == run_id and is_map(fence["terminal"]),
         {:ok, run} <- Ledger.fetch(namespace, run_id),
         {:ok, projection} <- authorized_projection(namespace, fence_key, fence, correlations),
         {:ok, %{activity_required: ^activity_required, time_required: true}} <-
           Ledger.projection_requirements(projection),
         :ok <- Ledger.project_derived(namespace, projection, run) do
      :ok
    else
      false -> {:error, :invalid_projection_obligation}
      {:error, _reason} = error -> error
    end
  end

  defp project(_obligation, _namespace), do: {:error, :invalid_projection_obligation}

  defp authorized_projection(
         namespace,
         fence_key,
         %{"schema" => "comma.triage-bucket-fence.v2"},
         correlations
       ) do
    with {:ok, %AuthorizedProjection{} = projection} <-
           RunFence.authorize_projection_from_key(namespace, fence_key),
         true <- projection.correlations == correlations do
      {:ok, projection}
    else
      false -> {:error, :invalid_projection_obligation}
      {:error, _reason} = error -> error
    end
  end

  defp authorized_projection(
         _namespace,
         _fence_key,
         %{"schema" => "comma.triage-bucket-fence.v1"} = fence,
         []
       ),
       do: {:ok, fence}

  defp authorized_projection(_namespace, _fence_key, _fence, _correlations),
    do: {:error, :invalid_projection_obligation}

  defp fail(obligation, reason, stats) do
    _ =
      TriageTransactions.mark_projection_failed(
        obligation.namespace_key,
        obligation.run_id,
        reason_label(reason)
      )

    Map.update!(stats, :failed, &(&1 + 1))
  end

  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(_reason), do: "projection_unavailable"
end
