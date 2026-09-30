defmodule BridgeForTeams.Outbox do
  @moduledoc """
  Transactional-outbox writer (design §4.2). Domain contexts call `enqueue/4`
  *inside* their own `Repo.transaction/1` so the reconcile row commits atomically
  with the domain mutation. The `BridgeForTeams.Salix.Reconciler` (salix slice)
  drains these rows `FOR UPDATE SKIP LOCKED` and applies them to Salix.

  This is a plain `Repo.insert` of `BridgeForTeams.Schema.ReconcileOutbox` — it must
  run on the same connection/transaction as the mutation, so it deliberately does
  *not* go through the reconciler GenServer.
  """
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.ReconcileOutbox

  @doc """
  Insert a pending outbox row. Call within the enclosing domain transaction.
  `aggregate_id` is stringified (outbox stores it as text).
  """
  @spec enqueue(String.t(), term(), String.t(), map(), keyword()) ::
          {:ok, ReconcileOutbox.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(aggregate, aggregate_id, op, payload, opts \\ []) do
    %ReconcileOutbox{}
    |> ReconcileOutbox.changeset(%{
      "aggregate" => aggregate,
      "aggregate_id" => to_string(aggregate_id),
      "op" => op,
      "payload" => payload,
      "status" => "pending"
    })
    |> maybe_put_created_at(opts[:created_at])
    |> Repo.insert()
  end

  defp maybe_put_created_at(changeset, nil), do: changeset

  defp maybe_put_created_at(changeset, %DateTime{} = created_at) do
    Ecto.Changeset.put_change(changeset, :created_at, created_at)
  end
end
