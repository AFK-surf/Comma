defmodule SalixIM.ConversationArchive do
  @moduledoc false

  alias SalixIM.ConversationMessageCodec
  alias SalixStore.{Keys, S3}
  alias SalixStore.S3.Settle

  @max_records 1_000
  @max_bytes 1_000_000

  def delete_objects(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case S3.delete(key) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def prepare(scope, snapshots, revision) do
    with {:ok, selected, body} <- encode_cut(snapshots),
         {:ok, expected_rows} <- ConversationMessageCodec.decode_segment(body),
         first = hd(selected).seq,
         key =
           Keys.ctl_group_conversation_message_segment(
             scope.group_id,
             scope.conversation_id,
             (first |> Integer.to_string() |> String.pad_leading(18, "0")) <> "-r#{revision}"
           ),
         {:ok, landed} <- put_once(key, body),
         {:ok, rows} <- ConversationMessageCodec.decode_segment(landed),
         true <- rows != [],
         true <- length(rows) <= @max_records and hd(rows)["seq"] == first,
         true <- Enum.map(rows, & &1["seq"]) == Enum.sort(Enum.map(rows, & &1["seq"])),
         last = List.last(rows)["seq"],
         true <- last <= List.last(selected).seq do
      landed_by_seq = Map.new(rows, &{&1["seq"], optional_identity(&1)})

      candidates =
        for {candidate, expected} <- Enum.zip(selected, expected_rows),
            landed_by_seq[expected["seq"]] == optional_identity(expected),
            do: candidate

      {:ok,
       %{
         first_seq: first,
         last_seq: last,
         object_key: key,
         encoding: "jsonl",
         candidates: candidates
       }}
    else
      false -> {:error, :archive_conflict}
      error -> error
    end
  end

  defp optional_identity(row),
    do: row |> Map.put_new("request_identity", nil) |> Map.put_new("request_fingerprint", nil)

  def hydrate_many(snapshots) do
    Enum.reduce_while(snapshots, {:ok, [], %{}}, fn snapshot, {:ok, messages, cache} ->
      case hydrate(snapshot, cache) do
        {:ok, message, cache} -> {:cont, {:ok, [message | messages], cache}}
        {:error, :message_deleted} -> {:cont, {:ok, messages, cache}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages, _cache} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  def hydrate(snapshot) do
    case hydrate(snapshot, %{}) do
      {:ok, message, _cache} -> {:ok, message}
      error -> error
    end
  end

  defp hydrate(%{tombstone: true}, _cache), do: {:error, :message_deleted}

  defp hydrate(%{archive_first_seq: first} = snapshot, cache) when not is_nil(first) do
    with true <- is_binary(snapshot.object_key) and snapshot.encoding == "jsonl",
         {:ok, rows, cache} <- read_segment(snapshot.object_key, cache),
         %{} = body <- Enum.find(rows, &(&1["seq"] == snapshot.seq)),
         true <- body["message_id"] == snapshot.message_id do
      {:ok, overlay(body, snapshot), cache}
    else
      false -> {:error, :archive_incomplete}
      nil -> {:error, :archive_incomplete}
      error -> error
    end
  end

  defp hydrate(%{payload: payload} = snapshot, cache) when is_binary(payload),
    do: {:ok, overlay(:erlang.binary_to_term(payload, [:safe]), snapshot), cache}

  defp hydrate(_snapshot, _cache), do: {:error, :archive_incomplete}

  defp overlay(body, snapshot),
    do:
      Map.merge(body, %{
        "seq" => snapshot.seq,
        "message_id" => snapshot.message_id,
        "request_identity" => snapshot.request_identity,
        "request_fingerprint" => snapshot.request_fingerprint
      })

  defp read_segment(key, cache) do
    case Map.fetch(cache, key) do
      {:ok, rows} ->
        {:ok, rows, cache}

      :error ->
        with {:ok, %{body: body}} <- S3.get(key),
             {:ok, rows} <- ConversationMessageCodec.decode_segment(body) do
          {:ok, rows, Map.put(cache, key, rows)}
        else
          {:error, :not_found} -> {:error, :archive_incomplete}
          {:error, :invalid_message_segment} -> {:error, :archive_incomplete}
          {:error, _} -> {:error, :archive_unreadable}
        end
    end
  end

  defp put_once(key, body) do
    case Settle.create_once(key, body, Settle.byte_settle(body)) do
      result when result in [:created, :landed] -> {:ok, body}
      {:exists, %{body: landed}} -> {:ok, landed}
      error -> error
    end
  end

  defp encode_cut(snapshots) do
    Enum.reduce_while(snapshots, {:ok, [], [], 0, %{}}, fn snapshot,
                                                           {:ok, selected, lines, bytes, cache} ->
      with {:ok, body, cache} <- hydrate(snapshot, cache),
           {:ok, line} <- ConversationMessageCodec.encode_row(body) do
        if bytes + byte_size(line) > @max_bytes and selected != [] do
          {:halt, {:ok, selected, lines, bytes, cache}}
        else
          {:cont, {:ok, [snapshot | selected], [line | lines], bytes + byte_size(line), cache}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [], _, _, _} ->
        {:error, :archive_empty}

      {:ok, selected, lines, _, _} ->
        {:ok, Enum.reverse(selected), lines |> Enum.reverse() |> IO.iodata_to_binary()}

      error ->
        error
    end
  end
end
