defmodule BridgeForTeams.ContextLifecycle.ReadBarrier do
  @moduledoc """
  Linearizable visibility fence for product-owned context reads.

  A read locks every participating bundle with `FOR SHARE` for the duration of
  its callback. Lifecycle deletion/erasure takes `FOR UPDATE` on the same row,
  so either the lifecycle request commits first and the read is rejected, or
  the already-authorized read completes before the lifecycle request returns.
  """

  import Ecto.Query

  alias BridgeForTeams.ContextLifecycle.Deadlines
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.ContextBundle

  @spec run([Ecto.UUID.t()], (-> result)) :: result | {:error, term()} when result: term()
  def run(bundle_ids, fun) when is_list(bundle_ids) and is_function(fun, 0) do
    with {:ok, bundle_ids} <- normalize_ids(bundle_ids) do
      case Repo.transaction(
             fn ->
               bundles =
                 Repo.all(
                   from(bundle in ContextBundle,
                     where: bundle.id in ^bundle_ids,
                     order_by: [asc: bundle.id],
                     lock: "FOR SHARE"
                   )
                 )

               cond do
                 length(bundles) != length(bundle_ids) ->
                   Repo.rollback(:context_lifecycle_not_ready)

                 Enum.any?(bundles, &(not ready?(&1))) ->
                   Repo.rollback(:context_lifecycle_not_ready)

                 true ->
                   fun.()
               end
             end,
             timeout: Deadlines.read_barrier_transaction_timeout_ms()
           ) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def run(_bundle_ids, _fun), do: {:error, :invalid_context_read_barrier}

  defp normalize_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, :invalid_context_bundle_id}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid_context_bundle_id}
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp ready?(bundle),
    do: bundle.lifecycle_state == "registered" and bundle.subject_index_state == "complete"
end
