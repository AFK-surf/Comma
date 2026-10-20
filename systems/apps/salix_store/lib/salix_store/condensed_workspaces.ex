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
  alias SalixStore.Repo

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
  def render([]), do: "(empty)"

  def render(statements) when is_list(statements),
    do: Enum.map_join(statements, "\n", &line/1)

  @doc "Rendered size in bytes, the unit of both limits."
  def rendered_bytes(statements) when is_list(statements),
    do: statements |> Enum.map(&(byte_size(line(&1)) + 1)) |> Enum.sum()

  @doc false
  def apply_to_value(value, operations) do
    statements = List.wrap(value["statements"])
    next_id = value["next_id"] || 1
    known = MapSet.new(statements, & &1["id"])

    missing =
      operations
      |> Enum.filter(&(&1["op"] in ["replace", "remove"]))
      |> Enum.map(& &1["id"])
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.uniq()

    if missing != [] do
      {:conflict, missing}
    else
      {statements, next_id} = Enum.reduce(operations, {statements, next_id}, &apply_operation/2)
      {kept, removed} = truncate(statements)
      {:ok, %{"statements" => kept, "next_id" => next_id}, Enum.map(removed, & &1["id"])}
    end
  end

  defp apply_operation(%{"op" => "add", "text" => text}, {statements, next_id}),
    do: {statements ++ [%{"id" => "s#{next_id}", "text" => text}], next_id + 1}

  defp apply_operation(%{"op" => "replace", "id" => id, "text" => text}, {statements, next_id}) do
    {Enum.map(statements, &if(&1["id"] == id, do: %{&1 | "text" => text}, else: &1)), next_id}
  end

  # A remove of a statement that an earlier operation of the same batch
  # already removed is a no-op, not a conflict.
  defp apply_operation(%{"op" => "remove", "id" => id}, {statements, next_id}),
    do: {Enum.reject(statements, &(&1["id"] == id)), next_id}

  defp truncate(statements) do
    {kept, removed, _bytes} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {kept, removed, bytes} ->
        size = byte_size(line(statement)) + 1

        if removed == [] and bytes + size <= @hard_limit_bytes,
          do: {[statement | kept], removed, bytes + size},
          else: {kept, [statement | removed], bytes}
      end)

    {Enum.reverse(kept), Enum.reverse(removed)}
  end

  @doc false
  def normalize_operations(operations) when is_list(operations) do
    cond do
      operations == [] ->
        {:error, {:invalid, "operations must contain at least one operation"}}

      length(operations) > @max_operations ->
        {:error, {:invalid, "operations accepts at most #{@max_operations} operations"}}

      true ->
        operations
        |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
          case normalize_operation(operation) do
            {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end
    end
  end

  def normalize_operations(_operations),
    do: {:error, {:invalid, "operations must be a list"}}

  defp normalize_operation(%{"op" => "add"} = operation) do
    with :ok <- only_keys(operation, ~w(op text)),
         {:ok, text} <- statement_text(operation["text"]) do
      {:ok, %{"op" => "add", "text" => text}}
    end
  end

  defp normalize_operation(%{"op" => "replace"} = operation) do
    with :ok <- only_keys(operation, ~w(op id text)),
         {:ok, id} <- statement_id(operation["id"]),
         {:ok, text} <- statement_text(operation["text"]) do
      {:ok, %{"op" => "replace", "id" => id, "text" => text}}
    end
  end

  defp normalize_operation(%{"op" => "remove"} = operation) do
    with :ok <- only_keys(operation, ~w(op id)),
         {:ok, id} <- statement_id(operation["id"]) do
      {:ok, %{"op" => "remove", "id" => id}}
    end
  end

  defp normalize_operation(_operation),
    do: {:error, {:invalid, "each operation needs op add, replace or remove"}}

  defp only_keys(operation, allowed) do
    case Map.keys(operation) -- allowed do
      [] -> :ok
      extra -> {:error, {:invalid, "unsupported operation fields: #{Enum.join(extra, ", ")}"}}
    end
  end

  defp statement_id(id) when is_binary(id) do
    if Regex.match?(~r/\As[1-9][0-9]{0,9}\z/, id),
      do: {:ok, id},
      else: {:error, {:invalid, "id must be a statement id such as s3"}}
  end

  defp statement_id(_id), do: {:error, {:invalid, "id must be a statement id such as s3"}}

  # One statement is one line: line breaks would let a statement look like
  # several, so they become spaces.
  defp statement_text(text) when is_binary(text) do
    text = text |> String.replace(~r/\s*[\r\n]+\s*/, " ") |> String.trim()

    cond do
      text == "" ->
        {:error, {:invalid, "text must not be empty"}}

      not String.valid?(text) ->
        {:error, {:invalid, "text must be UTF-8"}}

      byte_size(text) > @max_statement_bytes ->
        {:error, {:invalid, "a statement holds at most #{@max_statement_bytes} bytes"}}

      true ->
        {:ok, text}
    end
  end

  defp statement_text(_text), do: {:error, {:invalid, "text must be a string"}}

  defp line(%{"id" => id, "text" => text}), do: "- [#{id}] #{text}"

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
