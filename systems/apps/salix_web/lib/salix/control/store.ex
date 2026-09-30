defmodule Salix.Control.Store do
  @moduledoc false

  alias SalixStore.S3

  @list_read_concurrency 8

  def list_records(prefix) do
    prefix
    |> list_keyed_records()
    |> Enum.map(&elem(&1, 1))
  end

  def list_keyed_records(prefix, opts \\ []) do
    case S3.list_all(prefix, opts) do
      {:ok, objects} ->
        context = SystemsObservability.Context.capture()

        objects
        |> Task.async_stream(
          fn %{key: key} ->
            SystemsObservability.Context.run(context, fn ->
              case get_record(key) do
                {:ok, rec} -> [{key, rec}]
                _ -> []
              end
            end)
          end,
          max_concurrency: @list_read_concurrency,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, records} -> records end)

      {:error, _} ->
        []
    end
  end

  # Inside a `SalixStore.ReadScope` (one delivery, one activation, one
  # provider callback) a control record is read once; every write below
  # forgets it first.
  def get_record(key) do
    SalixStore.ReadScope.fetch({:record, key}, fn ->
      case S3.get(key) do
        {:ok, %{body: body}} -> Jason.decode(body)
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp put_record_bytes(key, record, opts) do
    SalixStore.ReadScope.invalidate({:record, key})
    S3.put(key, Jason.encode!(record), opts)
  end

  def put_new(key, rec) do
    case put_record_bytes(key, rec, if_none_match: "*") do
      {:ok, _} -> {:ok, rec}
      {:error, :precondition_failed} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_record(key, new_rec, update_fun), do: upsert_record(key, new_rec, update_fun, 5)

  def upsert_record(_key, _new_rec, _update_fun, 0), do: {:error, :precondition_failed}

  def upsert_record(key, new_rec, update_fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, rec} <- Jason.decode(body),
             updated <- update_fun.(rec),
             {:ok, _} <- put_record_bytes(key, updated, if_match: etag) do
          {:ok, updated}
        else
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        case put_new(key, new_rec) do
          {:error, :exists} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_record(key, fun), do: update_record(key, fun, 5)

  def update_record(_key, _fun, 0), do: {:error, :precondition_failed}

  def update_record(key, fun, attempts) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, rec} <- Jason.decode(body),
         updated <- fun.(rec),
         {:ok, _} <- put_record_bytes(key, updated, if_match: etag) do
      {:ok, updated}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :precondition_failed} -> update_record(key, fun, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_record(key) do
    case S3.head(key) do
      {:ok, %{etag: etag}} ->
        SalixStore.ReadScope.invalidate({:record, key})
        S3.delete(key, if_match: etag)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def trim(nil), do: ""
  def trim(value) when is_binary(value), do: String.trim(value)
  def trim(value), do: value |> to_string() |> String.trim()

  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(value), do: not is_nil(value)

  def random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  def now, do: System.system_time(:second)
end
