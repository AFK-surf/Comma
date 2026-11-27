defmodule SalixStore.StatementList do
  @moduledoc """
  Pure normalization, atomic operation application, and rendering for ordered
  statement lists (`add`, `replace`, `remove` with monotonic `s<N>` ids).

  Shared by `SalixStore.CondensedWorkspaces` (16 KiB hard limit with
  drop-from-end truncation, non-empty batches) and `SalixStore.SessionHandoffs`
  (8 KiB hard limit with whole-batch rejection, empty batches permitted).
  """

  @default_hard_limit_bytes 16 * 1024
  @default_max_statement_bytes 2 * 1024
  @default_max_operations 32

  @doc "The text representation with statement ids: one `- [id] text` line per statement."
  @spec render([map()]) :: String.t()
  def render([]), do: "(empty)"

  def render(statements) when is_list(statements),
    do: Enum.map_join(statements, "\n", &line/1)

  @doc "Rendered size in UTF-8 bytes, including the trailing newline per line."
  @spec rendered_bytes([map()]) :: non_neg_integer()
  def rendered_bytes(statements) when is_list(statements),
    do: statements |> Enum.map(&(byte_size(line(&1)) + 1)) |> Enum.sum()

  @doc "Formats one statement as `- [id] text`."
  @spec line(map()) :: String.t()
  def line(%{"id" => id, "text" => text}), do: "- [#{id}] #{text}"

  @doc """
  Validates and normalizes a batch of statement operations.

  Options:
    * `:max_statement_bytes` - max UTF-8 bytes per statement (default #{@default_max_statement_bytes})
    * `:max_operations` - max operations per batch (default #{@default_max_operations})
    * `:allow_empty_operations` - whether `[]` is valid (default `false`)
    * `:transform_text` - optional `(String.t() -> String.t())` applied before size check
  """
  @spec normalize_operations(term(), keyword()) ::
          {:ok, [map()]} | {:error, {:invalid, String.t()}}
  def normalize_operations(operations, opts \\ [])

  def normalize_operations(operations, opts) when is_list(operations) do
    max_ops = Keyword.get(opts, :max_operations, @default_max_operations)
    allow_empty = Keyword.get(opts, :allow_empty_operations, false)

    cond do
      operations == [] and not allow_empty ->
        {:error, {:invalid, "operations must contain at least one operation"}}

      length(operations) > max_ops ->
        {:error, {:invalid, "operations accepts at most #{max_ops} operations"}}

      true ->
        operations
        |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
          case normalize_operation(operation, opts) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end
    end
  end

  def normalize_operations(_operations, _opts),
    do: {:error, {:invalid, "operations must be a list"}}

  @doc """
  Applies normalized `operations` to `value` (`%{"statements" => [...], "next_id" => n}`).

  Options:
    * `:hard_limit_bytes` - max rendered bytes (default #{@default_hard_limit_bytes})
    * `:overflow_policy` - `:truncate` (default, drops from end) or `:reject`
    * `:allow_empty_result` - whether a non-empty list may become empty (default `true`)
    * `:require_non_empty` - whether the final list must be non-empty (default `false`)
  """
  @spec apply_to_value(map(), [map()], keyword()) ::
          {:ok, map(), [String.t()]}
          | {:conflict, [String.t()]}
          | {:error, {:overflow, non_neg_integer(), pos_integer()}}
          | {:error, {:invalid, String.t()}}
  def apply_to_value(value, operations, opts \\ []) do
    hard_limit = Keyword.get(opts, :hard_limit_bytes, @default_hard_limit_bytes)
    overflow_policy = Keyword.get(opts, :overflow_policy, :truncate)
    allow_empty_result = Keyword.get(opts, :allow_empty_result, true)
    require_non_empty = Keyword.get(opts, :require_non_empty, false)

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
      {updated, next_id} = Enum.reduce(operations, {statements, next_id}, &apply_operation/2)

      cond do
        require_non_empty and updated == [] ->
          {:error, {:invalid, "statement list must not be empty"}}

        not allow_empty_result and statements != [] and updated == [] ->
          {:error, {:invalid, "cannot empty a non-empty statement list"}}

        overflow_policy == :reject ->
          bytes = rendered_bytes(updated)

          if bytes > hard_limit do
            {:error, {:overflow, bytes, hard_limit}}
          else
            {:ok, %{"statements" => updated, "next_id" => next_id}, []}
          end

        true ->
          {kept, removed} = truncate(updated, hard_limit)
          {:ok, %{"statements" => kept, "next_id" => next_id}, Enum.map(removed, & &1["id"])}
      end
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

  defp truncate(statements, hard_limit) do
    {kept, removed, _bytes} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {kept, removed, bytes} ->
        size = byte_size(line(statement)) + 1

        if removed == [] and bytes + size <= hard_limit,
          do: {[statement | kept], removed, bytes + size},
          else: {kept, [statement | removed], bytes}
      end)

    {Enum.reverse(kept), Enum.reverse(removed)}
  end

  defp normalize_operation(%{"op" => "add"} = operation, opts) do
    with :ok <- only_keys(operation, ~w(op text)),
         {:ok, text} <- statement_text(operation["text"], opts) do
      {:ok, %{"op" => "add", "text" => text}}
    end
  end

  defp normalize_operation(%{"op" => "replace"} = operation, opts) do
    with :ok <- only_keys(operation, ~w(op id text)),
         {:ok, id} <- statement_id(operation["id"]),
         {:ok, text} <- statement_text(operation["text"], opts) do
      {:ok, %{"op" => "replace", "id" => id, "text" => text}}
    end
  end

  defp normalize_operation(%{"op" => "remove"} = operation, _opts) do
    with :ok <- only_keys(operation, ~w(op id)),
         {:ok, id} <- statement_id(operation["id"]) do
      {:ok, %{"op" => "remove", "id" => id}}
    end
  end

  defp normalize_operation(_operation, _opts),
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
  defp statement_text(text, opts) when is_binary(text) do
    max_bytes = Keyword.get(opts, :max_statement_bytes, @default_max_statement_bytes)
    transform = Keyword.get(opts, :transform_text)

    if not String.valid?(text) do
      {:error, {:invalid, "text must be UTF-8"}}
    else
      text = text |> String.replace(~r/\s*[\r\n]+\s*/, " ") |> String.trim()
      text = if is_function(transform, 1), do: transform.(text) |> String.trim(), else: text

      cond do
        text == "" ->
          {:error, {:invalid, "text must not be empty"}}

        byte_size(text) > max_bytes ->
          {:error, {:invalid, "a statement holds at most #{max_bytes} bytes"}}

        true ->
          {:ok, text}
      end
    end
  end

  defp statement_text(_text, _opts), do: {:error, {:invalid, "text must be a string"}}
end
