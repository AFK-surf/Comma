defmodule Comma.MiniApps.Documents do
  @moduledoc """
  App storage without a backend (design §6.4): the `app` scope (all viewers of
  one app) and the `user` scope (one viewer of one app, keyed by the pairwise
  viewer ID). The `device` scope is the client core's.

  Layout follows `SalixWeb.SiteDocuments`: one object per key under the
  scope's prefix (`Comma.MiniApps.Blobs.docs_prefix/2` + `d/<key>`), so S3
  LIST order is key order and `prefix` / `after` page by prefix narrowing and
  `start-after`. Writes are compare-and-swap on the object's ETag. Each
  document carries a `version` that increments per write; `if_version`
  (0 for "does not exist") makes a write conditional (`version_conflict`).

  Quotas: 1 MiB per value; 100 MiB per app (`app`) and 10 MiB per viewer per
  app (`user`), counted in one CAS-updated `usage.json` per scope. A write
  reserves its growth before it lands and releases it if it does not, so a
  failure between the two steps can only over-count.
  """

  alias Comma.MiniApps.Blobs
  alias SalixStore.S3

  @key ~r/\A[a-zA-Z0-9][a-zA-Z0-9._\/\-]{0,255}\z/
  @mib 1024 * 1024
  @value_max @mib
  @quota %{app: 100 * @mib, user: 10 * @mib}
  @retries 5
  @page_default 100
  @page_max 100

  def limits,
    do: %{value_bytes: @value_max, app_bytes: @quota.app, user_bytes: @quota.user}

  def valid_key?(key), do: is_binary(key) and Regex.match?(@key, key)

  @doc "One page of documents: `%{\"data\" => [doc], \"has_more\" => bool}`."
  def list(app_id, scope, params) do
    base = Blobs.docs_prefix(app_id, scope) <> "d/"
    prefix = string(params["prefix"])
    after_key = string(params["after"])

    with {:ok, limit} <- limit(params["limit"]),
         :ok <-
           if(prefix == "" or String.length(prefix) <= 256, do: :ok, else: {:error, :invalid}),
         opts =
           [max_keys: limit + 1] ++
             if(after_key != "", do: [start_after: base <> after_key], else: []),
         {:ok, %{objects: objects}} <- S3.list(base <> prefix, opts) do
      {page, rest} = Enum.split(objects, limit)

      docs =
        page
        |> Enum.map(fn %{key: key} -> read(key) end)
        |> Enum.flat_map(fn
          {:ok, doc, _etag} -> [public(doc)]
          _ -> []
        end)

      {:ok, %{"data" => docs, "has_more" => rest != []}}
    else
      {:error, :invalid} -> {:error, :invalid}
      {:error, _reason} -> {:error, :temporarily_unavailable}
    end
  end

  def get(app_id, scope, key) do
    with :ok <- key(key) do
      case read(doc_key(app_id, scope, key)) do
        {:ok, doc, _etag} -> {:ok, public(doc)}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} -> {:error, :temporarily_unavailable}
      end
    end
  end

  @doc """
  Writes a document: `{:ok, doc}`, or `{:error, :version_conflict |
  :quota_exceeded | :value_too_large | :invalid}`.
  """
  def put(app_id, scope, key, value, if_version \\ nil) do
    with :ok <- key(key),
         :ok <- if(is_nil(value), do: {:error, :invalid}, else: :ok),
         :ok <- if_version(if_version),
         encoded = Jason.encode!(value),
         :ok <- if(byte_size(encoded) <= @value_max, do: :ok, else: {:error, :value_too_large}) do
      write(app_id, scope, key, value, byte_size(encoded), if_version, 0)
    end
  end

  def delete(app_id, scope, key) do
    with :ok <- key(key) do
      object = doc_key(app_id, scope, key)

      case read(object) do
        {:ok, doc, etag} ->
          case S3.delete(object, if_match: etag) do
            :ok ->
              release(app_id, scope, doc["size"] || 0)
              :ok

            {:error, :not_found} ->
              :ok

            {:error, :precondition_failed} ->
              delete(app_id, scope, key)

            {:error, _} ->
              {:error, :temporarily_unavailable}
          end

        {:error, :not_found} ->
          :ok

        {:error, _} ->
          {:error, :temporarily_unavailable}
      end
    end
  end

  defp write(_app_id, _scope, _key, _value, _size, _if_version, attempt) when attempt >= @retries,
    do: {:error, :temporarily_unavailable}

  defp write(app_id, scope, key, value, size, if_version, attempt) do
    object = doc_key(app_id, scope, key)

    {existing, etag} =
      case read(object) do
        {:ok, doc, etag} -> {doc, etag}
        {:error, :not_found} -> {nil, nil}
        {:error, _} -> {:error, nil}
      end

    current = if is_map(existing), do: existing["version"] || 1, else: 0
    old_size = if is_map(existing), do: existing["size"] || 0, else: 0
    delta = size - old_size

    cond do
      existing == :error ->
        {:error, :temporarily_unavailable}

      is_integer(if_version) and if_version != current ->
        {:error, :version_conflict}

      true ->
        with :ok <- reserve(app_id, scope, max(delta, 0)) do
          doc = %{
            "key" => key,
            "value" => value,
            "version" => current + 1,
            "size" => size,
            "updated_at" => SystemsClock.utc_now() |> DateTime.to_iso8601()
          }

          condition = if etag, do: [if_match: etag], else: [if_none_match: "*"]

          case S3.put(object, Jason.encode!(doc), [content_type: "application/json"] ++ condition) do
            {:ok, _} ->
              if delta < 0, do: release(app_id, scope, -delta)
              {:ok, public(doc)}

            {:error, :precondition_failed} ->
              release(app_id, scope, max(delta, 0))
              write(app_id, scope, key, value, size, if_version, attempt + 1)

            {:error, _} ->
              release(app_id, scope, max(delta, 0))
              {:error, :temporarily_unavailable}
          end
        end
    end
  end

  defp reserve(_app_id, _scope, 0), do: :ok
  defp reserve(app_id, scope, bytes), do: change_usage(app_id, scope, bytes, 0)

  defp release(_app_id, _scope, 0), do: :ok
  defp release(app_id, scope, bytes), do: change_usage(app_id, scope, -bytes, 0)

  defp change_usage(_app_id, _scope, _delta, attempt) when attempt >= @retries,
    do: {:error, :temporarily_unavailable}

  defp change_usage(app_id, scope, delta, attempt) do
    key = Blobs.docs_prefix(app_id, scope) <> "usage.json"

    {used, condition} =
      case S3.get(key) do
        {:ok, %{body: body, etag: etag}} ->
          {case Jason.decode(body) do
             {:ok, %{"bytes" => bytes}} when is_integer(bytes) -> bytes
             _ -> 0
           end, [if_match: etag]}

        {:error, :not_found} ->
          {0, [if_none_match: "*"]}

        {:error, _} ->
          {nil, nil}
      end

    next = max((used || 0) + delta, 0)

    cond do
      is_nil(used) ->
        {:error, :temporarily_unavailable}

      delta > 0 and next > quota(scope) ->
        {:error, :quota_exceeded}

      true ->
        case S3.put(key, Jason.encode!(%{"bytes" => next}), condition) do
          {:ok, _} -> :ok
          {:error, :precondition_failed} -> change_usage(app_id, scope, delta, attempt + 1)
          {:error, _} -> {:error, :temporarily_unavailable}
        end
    end
  end

  @doc "Bytes counted against a scope."
  def usage(app_id, scope) do
    case S3.get(Blobs.docs_prefix(app_id, scope) <> "usage.json") do
      {:ok, %{body: body}} -> body |> Jason.decode!() |> Map.get("bytes", 0)
      _ -> 0
    end
  end

  defp quota(:app), do: @quota.app
  defp quota({:user, _viewer}), do: @quota.user

  defp read(object) do
    case S3.get(object) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, %{} = doc} -> {:ok, doc, etag}
          _ -> {:error, :corrupt}
        end

      {:error, _} = error ->
        error
    end
  end

  defp public(doc), do: Map.take(doc, ["key", "value", "version", "updated_at"])

  defp doc_key(app_id, scope, key), do: Blobs.docs_prefix(app_id, scope) <> "d/" <> key

  defp key(key), do: if(valid_key?(key), do: :ok, else: {:error, :invalid})

  defp if_version(nil), do: :ok
  defp if_version(v) when is_integer(v) and v >= 0, do: :ok
  defp if_version(_v), do: {:error, :invalid}

  defp limit(nil), do: {:ok, @page_default}
  defp limit(n) when is_integer(n) and n in 1..@page_max, do: {:ok, n}

  defp limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} -> limit(n)
      _ -> {:error, :invalid}
    end
  end

  defp limit(_n), do: {:error, :invalid}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""
end
