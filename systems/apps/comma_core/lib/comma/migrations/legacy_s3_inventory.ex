defmodule Comma.Migrations.LegacyS3Inventory do
  @moduledoc """
  Read-only access to the retired Comma S3 snapshot for inventory and audit.

  PostgreSQL owns all Comma product serving state. This module deliberately
  exposes no write, cache, lock, counter, or point-read API.
  """

  @spec all(atom() | String.t()) :: {:ok, [term()]} | {:error, term()}
  def all(bucket) do
    with {:ok, rows} <- all_with_metadata(bucket) do
      {:ok, Enum.map(rows, & &1.value)}
    end
  end

  @spec all_with_metadata(atom() | String.t()) ::
          {:ok, [%{id: String.t(), value: term(), last_modified: term()}]} | {:error, term()}
  def all_with_metadata(bucket) do
    prefix = prefix(bucket)

    with {:ok, objects} <- SalixStore.S3.list_all(prefix) do
      Enum.reduce_while(objects, {:ok, []}, fn
        %{key: key, last_modified: last_modified}, {:ok, acc} ->
          case SalixStore.S3.get(key) do
            {:ok, %{body: body}} ->
              case Jason.decode(body) do
                {:ok, value} ->
                  row = %{
                    id: key |> String.trim_leading(prefix) |> URI.decode(),
                    value: value,
                    last_modified: last_modified
                  }

                  {:cont, {:ok, [row | acc]}}

                {:error, reason} ->
                  {:halt,
                   {:error, {:unavailable, {:invalid_json, key, Exception.message(reason)}}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:unavailable, {:listed_object_unavailable, key, reason}}}}
          end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, _} = error -> error
      end
    else
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  end

  defp prefix(bucket), do: "comma/" <> to_string(bucket) <> "/"
end
