defmodule SalixStore.TaskLabels do
  @moduledoc """
  PostgreSQL owner for each Group's bounded label catalog, approval policy and
  proposal decisions. A row lock serializes human and Router decisions; no
  Conversation RPC runs while that lock is held.
  """

  import Ecto.Query
  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "task_label_catalogs" do
      field(:group_id, :string, primary_key: true)
      field(:value, :map)
    end
  end

  @doc "Reads one Group's catalog without a lock; `{:ok, nil}` when unseeded."
  def get(group_id) do
    case Repo.one(from(row in Row, where: row.group_id == ^group_id)) do
      nil -> {:ok, nil}
      row -> {:ok, row.value}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :task_labels_unavailable}
  end

  def update(group_id, seed, fun) do
    Repo.transaction(fn ->
      Repo.insert!(%Row{group_id: group_id, value: seed.()},
        on_conflict: :nothing,
        conflict_target: [:group_id]
      )

      row = Repo.one!(from(row in Row, where: row.group_id == ^group_id, lock: "FOR UPDATE"))

      case fun.(row.value) do
        {:error, reason} ->
          Repo.rollback(reason)

        value when is_map(value) ->
          if value != row.value do
            row |> Ecto.Changeset.change(value: value) |> Repo.update!()
          end

          value
      end
    end)
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :task_labels_unavailable}
  end
end
