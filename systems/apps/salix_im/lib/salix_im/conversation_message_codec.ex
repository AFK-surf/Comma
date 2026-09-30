defmodule SalixIM.ConversationMessageCodec do
  @moduledoc """
  Pure codec and integrity contract for the canonical conversation message log.

  This module owns no storage and performs no repair. Both the conversation
  owner write path and bounded read projections use this exact contract.
  """

  alias SalixIM.{ConversationMessage, ProviderRecipientIdentity}
  alias SalixStore.{BoundedJsonl, Ids}

  @spec encode_row(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def encode_row(row, opts \\ []) when is_map(row) do
    with :ok <- validate_row(row) do
      line = Jason.encode!(row) <> "\n"

      case Keyword.get(opts, :max_bytes) do
        max when is_integer(max) and byte_size(line) > max ->
          {:error, Keyword.get(opts, :oversize_error, :message_record_too_large)}

        _max ->
          {:ok, line}
      end
    end
  end

  @spec decode_segment(binary()) :: {:ok, [map()]} | {:error, term()}
  def decode_segment(body) when is_binary(body) do
    with {:ok, rows} <- BoundedJsonl.decode_strict(body, :invalid_message_segment),
         :ok <- validate_rows(rows) do
      {:ok, rows}
    end
  end

  @spec validate_rows([map()]) :: :ok | {:error, :invalid_message_segment}
  def validate_rows(rows) when is_list(rows) do
    if Enum.all?(rows, &(validate_row(&1) == :ok)) do
      ids = Enum.map(rows, & &1["message_id"])
      seqs = Enum.map(rows, & &1["seq"])

      if length(ids) == MapSet.size(MapSet.new(ids)) and
           length(seqs) == MapSet.size(MapSet.new(seqs)),
         do: :ok,
         else: {:error, :invalid_message_segment}
    else
      {:error, :invalid_message_segment}
    end
  end

  @spec validate_row(map()) :: :ok | {:error, :invalid_message_segment}
  def validate_row(row) when is_map(row) do
    if Ids.valid_message_id?(row["message_id"]) and
         is_integer(row["seq"]) and row["seq"] > 0 and
         nonblank?(row["actor_type"]) and
         is_list(row["content"]) and
         is_map(row["metadata"]) and
         ConversationMessage.valid_owner_inline_task_refs_v1?(
           row[ConversationMessage.owner_inline_task_refs_v1_field()]
         ) and
         ProviderRecipientIdentity.valid_owner_identity?(
           row[ProviderRecipientIdentity.owner_field()]
         ) and
         nonblank?(row["request_fingerprint"]) and
         is_integer(row["created_at"]) and row["created_at"] >= 0 and
         match?({:ok, _validated}, ConversationMessage.validate(row)),
       do: :ok,
       else: {:error, :invalid_message_segment}
  end

  def validate_row(_row), do: {:error, :invalid_message_segment}

  @spec validate_pointer(map(), map() | keyword(), keyword()) ::
          :ok | {:error, :invalid_message_pointer}
  def validate_pointer(pointer, expected, opts \\ [])

  def validate_pointer(pointer, expected, opts)
      when is_map(pointer) and (is_map(expected) or is_list(expected)) do
    reservation? =
      Keyword.get(opts, :allow_reservation, false) and
        pointer["status"] == "reserved" and
        pointer["seq"] in [nil, ""] and
        pointer["segment_id"] in [nil, ""]

    final? =
      is_integer(pointer["seq"]) and pointer["seq"] > 0 and
        nonblank?(pointer["segment_id"])

    if Ids.valid_message_id?(pointer["message_id"]) and
         (reservation? or final?) and
         expected_matches?(pointer, expected),
       do: :ok,
       else: {:error, :invalid_message_pointer}
  end

  def validate_pointer(_pointer, _expected, _opts),
    do: {:error, :invalid_message_pointer}

  @spec target_row([map()], map(), map() | keyword()) ::
          {:ok, map()} | {:error, :invalid_message_pointer | :message_pointer_target_missing}
  def target_row(rows, pointer, expected)
      when is_list(rows) and is_map(pointer) and (is_map(expected) or is_list(expected)) do
    with :ok <- validate_rows(rows),
         :ok <- validate_pointer(pointer, expected),
         %{} = row <- Enum.find(rows, &(&1["seq"] == pointer["seq"])),
         true <- row["message_id"] == pointer["message_id"],
         true <- expected_matches?(row, expected) do
      {:ok, row}
    else
      nil -> {:error, :message_pointer_target_missing}
      false -> {:error, :invalid_message_pointer}
      {:error, _reason} = error -> error
    end
  end

  @spec segment_facts([map()], binary() | nil) :: map()
  def segment_facts(rows, body \\ nil) when is_list(rows) do
    seqs = Enum.map(rows, & &1["seq"])

    %{
      "start_seq" => Enum.min(seqs, &<=/2, fn -> nil end),
      "end_seq" => Enum.max(seqs, &>=/2, fn -> nil end),
      "message_count" => length(rows)
    }
    |> maybe_put("byte_size", if(is_binary(body), do: byte_size(body)))
  end

  defp expected_matches?(record, expected) do
    Enum.all?(expected, fn {field, value} -> record[to_string(field)] == value end)
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
