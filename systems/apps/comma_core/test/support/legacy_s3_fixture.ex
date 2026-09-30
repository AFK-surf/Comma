defmodule Comma.Migrations.LegacyS3Fixture do
  @moduledoc false

  def reset! do
    case SalixStore.S3.list_all("comma/") do
      {:ok, objects} -> Enum.each(objects, &SalixStore.S3.delete(&1.key))
      {:error, _reason} -> :ok
    end

    :ok
  end

  def put(bucket, id, value) do
    case SalixStore.S3.put(key(bucket, id), Jason.encode!(value)) do
      {:ok, _metadata} -> {:ok, value}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  def get(bucket, id) do
    case SalixStore.S3.get(key(bucket, id)) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  def delete(bucket, id) do
    case SalixStore.S3.delete(key(bucket, id)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  def all(bucket) do
    case Comma.Migrations.LegacyS3Inventory.all(bucket) do
      {:ok, values} -> values
      {:error, _reason} -> []
    end
  end

  def now, do: System.system_time(:second)

  defp key(bucket, id) do
    "comma/" <> to_string(bucket) <> "/" <> URI.encode(to_string(id), &(&1 not in [?/]))
  end
end
