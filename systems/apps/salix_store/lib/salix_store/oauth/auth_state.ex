defmodule SalixStore.OAuth.AuthState do
  @moduledoc """
  Short-lived OAuth authorization state records (port of willow
  `internal/control/oauth.go` — `oauth_auth_states` table: CreateOAuthAuthState,
  ConsumeOAuthAuthState, GetOAuthAuthState, RecordOAuthAuthStateCompletion,
  RecordOAuthAuthStateFailure, MarkOAuthAuthStateExpired,
  PurgeExpiredOAuthAuthStates).

  A record lives at `ctl/oauth/auth_states/{state}.json` and carries string
  keys: `state, tenant, group_id, agent_id, session_id, provider, alias,
  scopes, code_verifier, redirect_uri, redirect_after, origin
  ("agent"|"web"), status ("pending"|"consumed"|"completed"|"failed"|
  "expired"), error, binding_id, connection_id, provider_account_name,
  expires_at (ms), created_at (ms)`.

  Lifecycle: `create/1` is create-once (`If-None-Match: *`), `consume/1` is
  the callback's atomic claim (CAS `pending → consumed`, so a replayed
  callback loses), `record_completion/2` / `record_failure/2` write the
  terminal outcome the agent-side completion tool polls for, `get/1` lazily
  flips (and persists) `pending → expired` past `expires_at`, and
  `purge_expired/1` is the GC sweep.

  Intentional divergences from willow:

    * S3 CAS records instead of SQLite rows; the consume claim is an etag
      CAS write, not an `UPDATE ... WHERE status = 'pending'`.
    * "consumed" is an explicit `status` value; willow models consumption as
      `consumed_at` set on a still-`pending` row. Willow's
      ConsumeOAuthAuthState collapses missing / expired / already-consumed
      into one not-found error; here they are distinct (`:not_found`,
      `:expired`, `:already_consumed`) and the HTTP callback maps all three
      back to willow's "authorization session expired" message.
    * No `consumed_at` column: `purge_expired/1` keys the 24h terminal-row
      retention off `expires_at` instead of `consumed_at` (records expire
      600s after creation, so retention shifts by at most the TTL).
      "consumed" rows whose flow crashed mid-callback get the terminal
      retention rather than willow's immediate pending-bucket purge.
    * Timestamps are unix milliseconds (willow uses seconds).
    * Lazy expiry happens on `get/1`; willow exposes an explicit
      MarkOAuthAuthStateExpired the completion tool calls.
  """

  alias SalixStore.{Ids, S3}

  @prefix "ctl/oauth/auth_states/"
  @default_ttl_ms 600_000
  @terminal_retention_ms 24 * 60 * 60 * 1000
  @max_error_len 512
  @cas_attempts 5

  @type rec :: %{optional(String.t()) => any()}

  @doc "S3 key for an auth-state id."
  @spec key(String.t()) :: String.t()
  def key(state_id), do: @prefix <> state_id <> ".json"

  @doc """
  Insert a pending authorization-state record (create-once). Mirrors willow's
  CreateOAuthAuthState validation: `state`, `tenant`, `group_id`, `provider`,
  and `alias` are required; `status`/`origin`/`created_at`/`expires_at`
  default to `"pending"` / `"web"` / now / created_at + 600s.
  """
  @spec create(rec()) :: :ok | {:error, :already_exists | term()}
  def create(record) when is_map(record) do
    state = string_or_nil(record["state"])
    agent_id = string_or_nil(record["agent_id"])
    session_id = string_or_nil(record["session_id"])

    cond do
      is_nil(state) ->
        {:error, {:invalid, "state is required"}}

      Enum.any?(~w(tenant group_id provider alias), &is_nil(string_or_nil(record[&1]))) ->
        {:error, {:invalid, "tenant, group_id, provider, and alias are required"}}

      not is_nil(session_id) and
          (not Ids.valid_agent_id?(agent_id) or not Ids.valid_session_id?(session_id)) ->
        {:error, {:invalid, "agent session identity is invalid"}}

      true ->
        now = System.system_time(:millisecond)

        rec =
          record
          |> Map.put_new("status", "pending")
          |> Map.put_new("origin", "web")
          |> Map.put_new("created_at", now)
          |> then(&Map.put_new(&1, "expires_at", &1["created_at"] + @default_ttl_ms))

        case S3.put(key(state), Jason.encode!(rec), if_none_match: "*") do
          {:ok, _} -> :ok
          {:error, :precondition_failed} -> {:error, :already_exists}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Load a record without consuming it (the completion tool's poll). A pending
  record past `expires_at` is flipped to `"expired"` and persisted
  (best-effort) before being returned.
  """
  @spec get(String.t(), keyword()) :: {:ok, rec()} | {:error, :not_found | term()}
  def get(state_id, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)

    case read(state_id) do
      {:ok, rec, etag} ->
        if pending_expired?(rec, now) do
          expired = Map.put(rec, "status", "expired")

          case cas_put(state_id, expired, etag) do
            :ok ->
              {:ok, expired}

            {:error, :precondition_failed} ->
              # Lost the race to a concurrent consume/expire — report theirs.
              case read(state_id) do
                {:ok, current, _etag} -> {:ok, current}
                {:error, reason} -> {:error, reason}
              end

            {:error, _reason} ->
              # Persisting the flip is best-effort; the caller still sees expired.
              {:ok, expired}
          end
        else
          {:ok, rec}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Atomically claim a pending record (`pending → "consumed"`), willow's
  ConsumeOAuthAuthState. Exactly one caller wins under concurrent callbacks;
  losers observe `:already_consumed`. A pending record past `expires_at` is
  flipped to expired and `{:error, :expired}` is returned.
  """
  @spec consume(String.t(), keyword()) ::
          {:ok, rec()} | {:error, :not_found | :expired | :already_consumed | term()}
  def consume(state_id, opts \\ []), do: do_consume(state_id, opts, @cas_attempts)

  @doc "Cancel only an unclaimed authorization. A browser exchange already in progress wins."
  def cancel_pending(state_id) do
    SalixStore.CasRecord.update(
      key(state_id),
      fn rec ->
        cond do
          rec["status"] == "failed" and rec["error"] == "user_declined" ->
            {:unchanged, rec}

          rec["status"] == "pending" ->
            rec |> Map.put("status", "failed") |> Map.put("error", "user_declined")

          true ->
            {:error, :already_consumed}
        end
      end,
      create: false
    )
  end

  defp do_consume(_state_id, _opts, 0), do: {:error, :precondition_failed}

  defp do_consume(state_id, opts, attempts) do
    now = opts[:now] || System.system_time(:millisecond)

    case read(state_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, rec, etag} ->
        cond do
          pending_expired?(rec, now) ->
            _ = cas_put(state_id, Map.put(rec, "status", "expired"), etag)
            {:error, :expired}

          rec["status"] == "pending" ->
            consumed = Map.put(rec, "status", "consumed")

            case cas_put(state_id, consumed, etag) do
              :ok -> {:ok, consumed}
              {:error, :precondition_failed} -> do_consume(state_id, opts, attempts - 1)
              {:error, reason} -> {:error, reason}
            end

          rec["status"] == "expired" ->
            {:error, :expired}

          true ->
            {:error, :already_consumed}
        end
    end
  end

  @doc """
  Mark the record completed and link the resulting binding / connection /
  provider account (willow's RecordOAuthAuthStateCompletion). Idempotent.
  """
  @spec record_completion(String.t(), rec()) :: :ok | {:error, term()}
  def record_completion(state_id, attrs) when is_map(attrs) do
    update(state_id, fn rec ->
      rec
      |> Map.put("status", "completed")
      |> Map.put("binding_id", attrs["binding_id"])
      |> Map.put("connection_id", attrs["connection_id"])
      |> Map.put("provider_account_name", attrs["provider_account_name"])
      |> Map.put("error", nil)
    end)
  end

  @doc """
  Mark the record failed with a bounded reason (willow's
  RecordOAuthAuthStateFailure, 512-char cap).
  """
  @spec record_failure(String.t(), String.t()) :: :ok | {:error, term()}
  def record_failure(state_id, error_message) do
    reason =
      error_message
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_error_len)

    update(state_id, fn rec ->
      rec
      |> Map.put("status", "failed")
      |> Map.put("error", reason)
      |> Map.put("binding_id", nil)
    end)
  end

  @doc """
  GC sweep (willow's PurgeExpiredOAuthAuthStates): deletes pending/expired
  records past `expires_at` and terminal (consumed/completed/failed) records
  older than the 24h retention window. Returns the deleted count.
  """
  @spec purge_expired(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired(now_ms) when is_integer(now_ms) do
    case S3.list_all(@prefix) do
      {:ok, objects} ->
        count =
          objects
          |> Enum.reject(&recently_written?(&1, now_ms))
          |> Enum.reduce(0, fn %{key: obj_key}, acc ->
            with {:ok, %{body: body, etag: etag}} <- S3.get(obj_key),
                 {:ok, rec} <- Jason.decode(body),
                 true <- purgeable?(rec, now_ms),
                 :ok <- S3.delete(obj_key, if_match: etag) do
              acc + 1
            else
              _ -> acc
            end
          end)

        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # LIST-metadata prefilter: skip the per-object GET while the object's last
  # write is younger than one TTL. A skip can only defer a deletion, never
  # lose one — a record stops being rewritten once terminal, so LastModified
  # ages past the window and a later pass does the full read. Purge is
  # retention housekeeping, not a correctness path; deferring an individual
  # record by up to one TTL after its last write is an accepted trade for not
  # re-reading the whole 24h-retention corpus on every pass. An unparseable
  # LastModified fails open into the GET path.
  defp recently_written?(%{last_modified: lm}, now_ms) when is_binary(lm) do
    case DateTime.from_iso8601(lm) do
      {:ok, dt, _offset} -> now_ms - DateTime.to_unix(dt, :millisecond) < @default_ttl_ms
      _ -> false
    end
  end

  defp recently_written?(_object, _now_ms), do: false

  # ---- internals ----

  defp purgeable?(rec, now) do
    expires_at = rec["expires_at"] || 0

    case rec["status"] do
      status when status in ["pending", "expired"] ->
        expires_at < now

      status when status in ["consumed", "completed", "failed"] ->
        expires_at < now - @terminal_retention_ms

      _ ->
        false
    end
  end

  defp pending_expired?(rec, now),
    do: rec["status"] == "pending" and is_integer(rec["expires_at"]) and rec["expires_at"] < now

  defp read(state_id) do
    case S3.get(key(state_id)) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, rec} -> {:ok, rec, etag}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cas_put(state_id, rec, etag) do
    case S3.put(key(state_id), Jason.encode!(rec), if_match: etag) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update(state_id, fun, attempts \\ @cas_attempts)

  defp update(_state_id, _fun, 0), do: {:error, :precondition_failed}

  defp update(state_id, fun, attempts) do
    case read(state_id) do
      {:ok, rec, etag} ->
        case cas_put(state_id, fun.(rec), etag) do
          :ok -> :ok
          {:error, :precondition_failed} -> update(state_id, fun, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil
end
