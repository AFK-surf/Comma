defmodule SalixStore.TaskRoutingLearning do
  @moduledoc "Atomic Group routing evidence and durable one-sample-per-Task receipts."
  import Ecto.Query
  alias SalixStore.Repo

  defmodule State do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "task_routing_learning" do
      field(:group_id, :string, primary_key: true)
      field(:generation, :string, primary_key: true)
      field(:value, :map)
    end
  end

  defmodule Receipt do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "task_routing_feedback" do
      field(:group_id, :string, primary_key: true)
      field(:conversation_id, :string, primary_key: true)
      field(:generation, :string)
      field(:value, :map)
    end
  end

  def get(group, generation, initial) do
    case Repo.get_by(State, group_id: group, generation: generation) do
      nil -> {:ok, initial}
      row -> {:ok, row.value}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :routing_learning_unavailable}
  end

  @doc "The states of at most a table's routes, by generation, in one read."
  def get_many(group, generations) when is_list(generations) and length(generations) <= 64 do
    {:ok,
     Repo.all(
       from(s in State,
         where: s.group_id == ^group and s.generation in ^generations,
         select: {s.generation, s.value}
       )
     )
     |> Map.new()}
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :routing_learning_unavailable}
  end

  def recorded?(group, conversation) do
    {:ok,
     Repo.exists?(
       from(r in Receipt, where: r.group_id == ^group and r.conversation_id == ^conversation)
     )}
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :routing_learning_unavailable}
  end

  def record(group, generation, conversation, observation, initial, update) do
    Repo.transaction(fn ->
      Repo.insert!(%State{group_id: group, generation: generation, value: initial},
        on_conflict: :nothing
      )

      row =
        Repo.one!(
          from(s in State,
            where: s.group_id == ^group and s.generation == ^generation,
            lock: "FOR UPDATE"
          )
        )

      case Repo.get_by(Receipt, group_id: group, conversation_id: conversation) do
        nil ->
          Repo.insert!(%Receipt{
            group_id: group,
            conversation_id: conversation,
            generation: generation,
            value: observation
          })

          value = update.(row.value, observation)
          Repo.update!(Ecto.Changeset.change(row, value: value))
          %{state: value, duplicate: false}

        %{generation: ^generation, value: ^observation} ->
          %{state: row.value, duplicate: true}

        _ ->
          Repo.rollback({:conflict, "Task already has different routing feedback"})
      end
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :routing_learning_unavailable}
  end

  def delete_group(group) do
    Repo.transaction(fn ->
      Repo.delete_all(from(r in Receipt, where: r.group_id == ^group))
      Repo.delete_all(from(s in State, where: s.group_id == ^group))
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :routing_learning_unavailable}
  end
end
