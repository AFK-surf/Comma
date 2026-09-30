defmodule SalixIM.ProviderObservations do
  @moduledoc false

  alias SalixStore.{CasRecord, Keys, S3}

  @scan_max_records 500

  def upsert_telegram_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_telegram_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "title" => trim(attrs["title"]),
        "username" => trim(attrs["username"]),
        "last_message_at" => attrs["last_message_at"] || now()
      })
    end
  end

  def upsert_telegram_user(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    user_id = trim(attrs["user_id"])

    if user_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_telegram_user(connect_id, user_id), %{
        "connect_id" => connect_id,
        "user_id" => user_id,
        "username" => trim(attrs["username"]),
        "display_name" => trim(attrs["display_name"]),
        "is_bot" => attrs["is_bot"] == true,
        "last_seen_at" => attrs["last_seen_at"] || now()
      })
    end
  end

  def list_telegram_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_telegram_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "title", "username"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def list_telegram_users(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_telegram_users_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["user_id", "username", "display_name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def get_telegram_chat(connect_id, chat_id),
    do: CasRecord.get(Keys.ctl_im_telegram_chat(connect_id, trim(chat_id)))

  def upsert_feishu_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_feishu_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "name" => trim(attrs["name"]),
        "last_message_at" => attrs["last_message_at"] || now()
      })
    end
  end

  def upsert_feishu_user(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    open_id = trim(attrs["open_id"])

    if open_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_feishu_user(connect_id, open_id), %{
        "connect_id" => connect_id,
        "open_id" => open_id,
        "union_id" => trim(attrs["union_id"]),
        "user_id" => trim(attrs["user_id"]),
        "name" => trim(attrs["name"]),
        "email" => trim(attrs["email"]),
        "last_seen_at" => attrs["last_seen_at"] || now()
      })
    end
  end

  def list_feishu_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_feishu_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "chat_type", "name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def list_feishu_users(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_feishu_users_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["open_id", "union_id", "user_id", "name", "email"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  defp scan_records(prefix) do
    with {:ok, %{objects: objects, next: nil}} when length(objects) <= @scan_max_records <-
           S3.list(prefix, max_keys: @scan_max_records) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
        case CasRecord.get(key, :invalid_observation_record) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:observation_record_unavailable, key, reason}}}
        end
      end)
      |> then(fn
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end)
    else
      {:ok, %{next: _continuation}} -> {:error, :observation_scan_limit_exceeded}
      {:error, _reason} = error -> error
      other -> {:error, {:observation_scan_failed, other}}
    end
  end

  defp upsert(key, attrs) do
    now = now()

    rec =
      attrs
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.put_new("created_at", now)
      |> Map.put("updated_at", now)

    CasRecord.update(key, fn
      nil ->
        rec

      current ->
        rec
        |> Map.put("created_at", current["created_at"] || now)
        |> then(&Map.merge(current, &1))
    end)
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp filter(records, query, fields) do
    query = String.downcase(trim(query))

    records
    |> Enum.sort_by(&(&1["updated_at"] || 0), :desc)
    |> Enum.filter(fn rec ->
      query == "" or
        Enum.any?(fields, fn field ->
          rec[field]
          |> trim()
          |> String.downcase()
          |> String.contains?(query)
        end)
    end)
  end

  defp clamp_limit(limit) do
    case num(limit) do
      n when n <= 0 -> 50
      n when n > 100 -> 100
      n -> n
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp num(value) when is_integer(value), do: value
  defp num(value) when is_float(value), do: trunc(value)

  defp num(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp num(_), do: 0
  defp now, do: System.system_time(:millisecond)
end
