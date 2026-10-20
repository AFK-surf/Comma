defmodule SalixStore.ComputeWorkloadUpdate do
  @moduledoc """
  The per-Workload operation lock, and the stored `runtime_update` phase of a
  Workload. Runtime image updates served External Runtime Workloads only and
  are retired; a phase stored before then still pauses that Workload's input.
  """

  alias SalixStore.Repo

  def active?(%{runtime_update: %{"phase" => phase}}),
    do: phase not in ["complete", "cancelled"]

  def active?(_), do: false

  def input_paused?(%{runtime_update: %{"phase" => phase} = update} = workload),
    do: active?(workload) and (phase != "preparing" or update["input_paused"] == true)

  def input_paused?(_), do: false

  # This lock serializes provider steps of one Workload. It has no identity or
  # authorization role; a collision only serializes extra work.
  def with_lock(workload_id, fun) do
    Repo.transaction(
      fn ->
        case Repo.query!(
               "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 4412742))",
               [workload_id]
             ).rows do
          [[true]] -> fun.()
          _ -> {:error, :workload_operation_busy}
        end
      end,
      timeout: 900_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
