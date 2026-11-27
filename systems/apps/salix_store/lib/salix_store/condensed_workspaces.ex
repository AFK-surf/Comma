defmodule SalixStore.CondensedWorkspaces do
  @moduledoc """
  PostgreSQL owner of each Group's Condensed Workspace: an ordered list of
  short statements about current facts that every participating Agent
  Session keeps in context (docs/agent-runtime.md#condensed-workspace).

  One row per Group. A write applies a batch of `add`, `replace` and `remove`
  operations under a row lock and advances `revision` once. A `replace` or
  `remove` of an unknown statement id fails the whole batch with the current
  content, so a writer that worked from an older list can re-read it.

  The rendered list has a hard limit of #{16 * 1024} bytes. A write that
  exceeds it keeps statements in order up to the limit and removes the rest.
  The result names the removed statement ids.
  """

  import Ecto.Query
  alias SalixStore.{Repo, StatementList}

  @hard_limit_bytes 16 * 1024
  @recommended_bytes 4 * 1024
  @max_statement_bytes 2 * 1024
  @max_operations 32

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "condensed_workspaces" do
      field(:group_id, :string, primary_key: true)
      field(:revision, :integer)
      field(:value, :map)
      field(:updated_by, :map)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def hard_limit_bytes, do: @hard_limit_bytes
  def recommended_bytes, do: @recommended_bytes
  def max_statement_bytes, do: @max_statement_bytes
  def max_operations, do: @max_operations

  @doc "The Group's workspace without a lock. An unwritten Group reads as revision 0."
  def get(group_id) when is_binary(group_id) do
    case Repo.one(from(row in Row, where: row.group_id == ^group_id)) do
      nil -> {:ok, empty(group_id)}
      row -> {:ok, view(row)}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :condensed_workspace_unavailable}
  end

  @doc """
  Applies `operations` atomically. `updated_by` records the writer, for
  example `%{"kind" => "agent", "agent_id" => ..., "session_id" => ...}` or
  `%{"kind" => "user", "user_id" => ...}`.

  Returns `{:ok, workspace, removed_ids}`, `{:error, {:invalid, message}}`,
  `{:error, {:conflict, missing_ids, workspace}}` or
  `{:error, :condensed_workspace_unavailable}`.
  """
  def apply_operations(group_id, operations, updated_by)
      when is_binary(group_id) and is_map(updated_by) do
    with {:ok, operations} <- normalize_operations(operations) do
      Repo.transaction(fn ->
        Repo.insert!(
          %Row{
            group_id: group_id,
            revision: 0,
            value: %{"statements" => [], "next_id" => 1},
            updated_by: %{"kind" => "system"},
            updated_at: SystemsClock.timestamp(:utc_datetime_usec)
          },
          on_conflict: :nothing,
          conflict_target: [:group_id]
        )

        row = Repo.one!(from(row in Row, where: row.group_id == ^group_id, lock: "FOR UPDATE"))

        case apply_to_value(row.value, operations) do
          {:ok, value, removed} ->
            row =
              row
              |> Ecto.Changeset.change(
                revision: row.revision + 1,
                value: value,
                updated_by: updated_by,
                updated_at: SystemsClock.timestamp(:utc_datetime_usec)
              )
              |> Repo.update!()

            {view(row), removed}

          {:conflict, missing} ->
            Repo.rollback({:conflict, missing, view(row)})
        end
      end)
      |> case do
        {:ok, {workspace, removed}} -> {:ok, workspace, removed}
        {:error, _} = error -> error
      end
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :condensed_workspace_unavailable}
  end

  @doc "The text every Session sees: one `- [id] text` line per statement."
  def render(statements), do: StatementList.render(statements)

  @doc "Rendered size in bytes, the unit of both limits."
  def rendered_bytes(statements), do: StatementList.rendered_bytes(statements)

  @doc false
  def apply_to_value(value, operations) do
    StatementList.apply_to_value(value, operations,
      hard_limit_bytes: @hard_limit_bytes,
      overflow_policy: :truncate,
      allow_empty_result: true
    )
  end

  @doc false
  def normalize_operations(operations) do
    StatementList.normalize_operations(operations,
      max_statement_bytes: @max_statement_bytes,
      max_operations: @max_operations,
      allow_empty_operations: false
    )
  end

  @doc false
  def view(%Row{} = row) do
    %{
      group_id: row.group_id,
      revision: row.revision,
      statements: List.wrap(row.value["statements"]),
      updated_by: row.updated_by || %{},
      updated_at: row.updated_at
    }
  end

  @doc false
  def empty(group_id),
    do: %{group_id: group_id, revision: 0, statements: [], updated_by: %{}, updated_at: nil}
end
