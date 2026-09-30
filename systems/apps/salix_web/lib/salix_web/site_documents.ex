defmodule SalixWeb.SiteDocuments do
  @moduledoc """
  Per-site JSON document storage — the Salix port of willow's
  `internal/api/site_documents.go`.

  Willow gives each site a dedicated mvsqlite namespace registered in the
  agent DB's `site_doc_namespaces` table (max 10 per agent, lazily created on
  first PUT). Salix keeps the same observable contract on S3:

    * documents live one-object-per-key under
      `sitedocs/{agent}/sites/{site}/{doc_key}` — S3 LIST is
      lexicographically ordered, which matches willow's `ORDER BY key ASC`
      and gives `prefix` / `after` paging via prefix-narrowing and
      `start-after`;
    * the namespace registry is one CAS-updated object
      (`sitedocs/{agent}/ns.json`); the 10-namespace cap is enforced
      atomically by the CAS retry loop, counting registered sites *excluding*
      the current one (willow's concurrent-same-site rule);
    * document upserts preserve `doc_id` / `created_at` across updates via a
      CAS read-modify-write (willow's `RetryTx`).

  Error responses are willow's HTML site error pages with the same status
  texts; success payloads match willow's JSON shapes.
  """

  alias SalixStore.{Keys, S3}
  alias SalixWeb.Site

  @max_namespaces_per_agent 10
  @doc_key_re ~r|^[a-zA-Z0-9][a-zA-Z0-9._/\-]{0,255}$|
  @cas_retries 5

  import Plug.Conn

  # ---- GET /_api/documents ----

  def list(conn, agent_id, site_name) do
    limit = parse_limit(conn.query_params["limit"])
    after_key = conn.query_params["after"] || ""
    prefix = conn.query_params["prefix"] || ""

    if not namespace_exists?(agent_id, site_name) do
      send_json(conn, 200, %{"data" => [], "has_more" => false})
    else
      base = Keys.site_docs_prefix(agent_id, site_name)
      list_prefix = base <> prefix

      start_after =
        cond do
          after_key == "" -> nil
          # `after` keys narrower than the listed prefix still apply (key > after).
          true -> base <> after_key
        end

      case list_docs(list_prefix, start_after, limit + 1) do
        {:ok, keys} ->
          docs =
            keys
            |> Enum.take(limit + 1)
            |> Enum.map(&fetch_doc_object/1)
            |> Enum.reject(&is_nil/1)

          has_more = length(docs) > limit
          docs = Enum.take(docs, limit)
          send_json(conn, 200, %{"data" => docs, "has_more" => has_more})

        {:error, _} ->
          Site.site_error(conn, 500, "Internal server error")
      end
    end
  end

  defp parse_limit(nil), do: 100

  defp parse_limit(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 and n <= 1000 -> n
      _ -> 100
    end
  end

  defp list_docs(prefix, start_after, want) do
    do_list_docs(prefix, start_after, want, nil, [])
  end

  defp do_list_docs(_prefix, _start_after, want, _token, acc) when length(acc) >= want,
    do: {:ok, Enum.take(acc, want)}

  defp do_list_docs(prefix, start_after, want, token, acc) do
    opts =
      [max_keys: want]
      |> then(fn o -> if token, do: Keyword.put(o, :continuation_token, token), else: o end)
      |> then(fn o ->
        if start_after && !token, do: Keyword.put(o, :start_after, start_after), else: o
      end)

    case S3.list(prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        acc = acc ++ Enum.map(objects, & &1.key)

        if next && length(acc) < want do
          do_list_docs(prefix, start_after, want, next, acc)
        else
          {:ok, Enum.take(acc, want)}
        end

      err ->
        err
    end
  end

  defp fetch_doc_object(key) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, doc} -> doc
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ---- GET /_api/documents/{key} ----

  def get(conn, agent_id, site_name, doc_key) do
    cond do
      not valid_doc_key?(doc_key) ->
        Site.site_error(conn, 400, "Invalid document key")

      not namespace_exists?(agent_id, site_name) ->
        Site.site_error(conn, 404, "Document not found")

      true ->
        case S3.get(Keys.site_doc(agent_id, site_name, doc_key)) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, doc} -> send_json(conn, 200, doc)
              _ -> Site.site_error(conn, 500, "Internal server error")
            end

          {:error, :not_found} ->
            Site.site_error(conn, 404, "Document not found")

          {:error, _} ->
            Site.site_error(conn, 500, "Internal server error")
        end
    end
  end

  # ---- PUT /_api/documents/{key} ----

  def put(conn, agent_id, site_name, doc_key, cfg) do
    max_size =
      SalixWeb.SiteAPI.effective_max_value_size(SalixWeb.SiteAPI.match_storage_rule(cfg, doc_key))

    cond do
      not valid_doc_key?(doc_key) ->
        Site.site_error(conn, 400, "Invalid document key")

      true ->
        case read_body_capped(conn, max_size) do
          {:too_large, conn} ->
            Site.site_error(conn, 413, "Value too large")

          {:error, conn} ->
            Site.site_error(conn, 400, "Failed to read body")

          {:ok, body, conn} ->
            case Jason.decode(body) do
              {:ok, %{"value" => value}} when not is_nil(value) ->
                put_decoded(conn, agent_id, site_name, doc_key, value)

              {:ok, %{"value" => _}} ->
                Site.site_error(conn, 400, "Value required")

              {:ok, _} ->
                Site.site_error(conn, 400, "Value required")

              {:error, _} ->
                Site.site_error(conn, 400, "Invalid JSON body")
            end
        end
    end
  end

  defp put_decoded(conn, agent_id, site_name, doc_key, value) do
    case authorize_storage(agent_id, site_name, "site_doc_namespace_write", doc_key) do
      :ok ->
        do_put_decoded(conn, agent_id, site_name, doc_key, value)

      {:error, {:billing_unavailable, _decision}} ->
        Site.site_error(conn, 402, "Billing unavailable")

      {:error, _} ->
        Site.site_error(conn, 500, "Internal server error")
    end
  end

  defp do_put_decoded(conn, agent_id, site_name, doc_key, value) do
    case ensure_namespace(agent_id, site_name) do
      :ok ->
        case authorize_storage(agent_id, site_name, "site_doc_write", doc_key) do
          :ok -> upsert_doc(agent_id, site_name, doc_key, value)
          {:error, _} = err -> err
        end
        |> case do
          {:ok, doc} ->
            send_json(conn, 200, doc)

          {:error, {:billing_unavailable, _decision}} ->
            Site.site_error(conn, 402, "Billing unavailable")

          {:error, _} ->
            Site.site_error(conn, 500, "Internal server error")
        end

      {:error, :too_many_namespaces} ->
        Site.site_error(conn, 409, "too many site document namespaces")

      {:error, _} ->
        Site.site_error(conn, 500, "Internal server error")
    end
  end

  # ---- DELETE /_api/documents/{key} ----

  def delete(conn, agent_id, site_name, doc_key) do
    cond do
      not valid_doc_key?(doc_key) ->
        Site.site_error(conn, 400, "Invalid document key")

      not namespace_exists?(agent_id, site_name) ->
        Site.site_error(conn, 404, "Document not found")

      true ->
        key = Keys.site_doc(agent_id, site_name, doc_key)

        case S3.get(key) do
          {:ok, _} ->
            case authorize_storage(agent_id, site_name, "site_doc_delete", doc_key) do
              :ok -> S3.delete(key, [])
              {:error, _} = err -> err
            end
            |> case do
              {:error, {:billing_unavailable, _decision}} ->
                Site.site_error(conn, 402, "Billing unavailable")

              {:error, reason} when reason != :not_found ->
                Site.site_error(conn, 500, "Internal server error")

              _ ->
                send_json(conn, 200, %{"status" => "deleted"})
            end

          {:error, :not_found} ->
            Site.site_error(conn, 404, "Document not found")

          {:error, _} ->
            Site.site_error(conn, 500, "Internal server error")
        end
    end
  end

  # ---- internals ----

  def valid_doc_key?(key), do: is_binary(key) and Regex.match?(@doc_key_re, key)

  defp namespace_exists?(agent_id, site_name) do
    case read_namespaces(agent_id) do
      {:ok, ns, _etag} -> Map.has_key?(ns, site_name)
      _ -> false
    end
  end

  defp read_namespaces(agent_id) do
    case S3.get(Keys.site_doc_namespaces(agent_id)) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, ns} when is_map(ns) -> {:ok, ns, etag}
          _ -> {:ok, %{}, etag}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Lazy namespace registration with the 10-cap enforced atomically by the
  # CAS retry loop. The count excludes the current site name so a concurrent
  # winner for the SAME site never causes a false cap violation (willow).
  defp ensure_namespace(agent_id, site_name, attempt \\ 0)

  defp ensure_namespace(_agent_id, _site_name, attempt) when attempt >= @cas_retries,
    do: {:error, :cas_conflict}

  defp ensure_namespace(agent_id, site_name, attempt) do
    with {:ok, ns, etag} <- read_namespaces(agent_id) do
      cond do
        Map.has_key?(ns, site_name) ->
          :ok

        ns |> Map.keys() |> Enum.count(&(&1 != site_name)) >= @max_namespaces_per_agent ->
          {:error, :too_many_namespaces}

        true ->
          entry = %{
            "doc_namespace" => "site_" <> agent_id <> "_" <> site_name,
            "created_at" => System.os_time(:second)
          }

          body = Jason.encode!(Map.put(ns, site_name, entry))

          write_opts = if etag, do: [if_match: etag], else: [if_none_match: "*"]

          case S3.put(Keys.site_doc_namespaces(agent_id), body, write_opts) do
            {:ok, _} -> :ok
            {:error, :precondition_failed} -> ensure_namespace(agent_id, site_name, attempt + 1)
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  # CAS read-modify-write upsert preserving doc_id/created_at (willow RetryTx).
  defp upsert_doc(agent_id, site_name, doc_key, value, attempt \\ 0)

  defp upsert_doc(_agent_id, _site_name, _doc_key, _value, attempt) when attempt >= @cas_retries,
    do: {:error, :cas_conflict}

  defp upsert_doc(agent_id, site_name, doc_key, value, attempt) do
    key = Keys.site_doc(agent_id, site_name, doc_key)
    now = System.os_time(:second)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        existing =
          case Jason.decode(body) do
            {:ok, doc} when is_map(doc) -> doc
            _ -> %{}
          end

        doc = %{
          "doc_id" => existing["doc_id"] || new_doc_id(),
          "key" => doc_key,
          "value" => value,
          "created_at" => existing["created_at"] || now,
          "updated_at" => now
        }

        case S3.put(key, Jason.encode!(doc), if_match: etag) do
          {:ok, _} ->
            {:ok, doc}

          {:error, :precondition_failed} ->
            upsert_doc(agent_id, site_name, doc_key, value, attempt + 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        doc = %{
          "doc_id" => new_doc_id(),
          "key" => doc_key,
          "value" => value,
          "created_at" => now,
          "updated_at" => now
        }

        case S3.put(key, Jason.encode!(doc), if_none_match: "*") do
          {:ok, _} ->
            {:ok, doc}

          {:error, :precondition_failed} ->
            upsert_doc(agent_id, site_name, doc_key, value, attempt + 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp new_doc_id do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> =
      :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.map(&Base.encode16(&1, case: :lower))
    |> Enum.join("-")
  end

  defp read_body_capped(conn, max_size) do
    case Plug.Conn.read_body(conn, length: max_size + 1, read_length: max_size + 1) do
      {:ok, body, conn} when byte_size(body) > max_size -> {:too_large, conn}
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:too_large, conn}
      {:error, _} -> {:error, conn}
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp authorize_storage(agent_id, site_name, type, doc_key) do
    SalixAgent.StorageAuthorization.authorize_write(%{
      agent_id: agent_id,
      events: [
        %{
          "type" => type,
          "site_name" => site_name,
          "doc_key" => doc_key
        }
      ],
      entrypoint: "site_documents",
      actor_type: "external_user"
    })
  end
end
