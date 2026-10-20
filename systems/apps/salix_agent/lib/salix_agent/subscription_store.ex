defmodule SalixAgent.SubscriptionStore do
  @moduledoc false
  alias SalixStore.Repo

  # The operator secret protects stored subscription material. Tenant and record
  # identity bind ciphertext to its owner, as in the previous encrypted vault.
  def seal(tenant, id, value) do
    with {:ok, key} <- key() do
      nonce = SystemsRuntime.Proc.random_bytes(12)

      {body, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          Jason.encode!(value),
          tenant <> ":" <> id,
          true
        )

      {:ok, Base.encode64(nonce <> tag <> body)}
    end
  end

  def open(tenant, id, encoded) do
    with {:ok, key} <- key(),
         {:ok, <<nonce::binary-size(12), tag::binary-size(16), body::binary>>} <-
           Base.decode64(encoded),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             body,
             tenant <> ":" <> id,
             tag,
             false
           ),
         {:ok, value} <- Jason.decode(plain) do
      {:ok, value}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp key do
    case SystemsRuntime.get_env(:salix_agent, :subscription_storage_key) do
      secret when is_binary(secret) and byte_size(secret) == 32 ->
        {:ok, secret}

      _ ->
        {:error, :not_configured}
    end
  end

  # URL-safe base64 has no ".": an id is always a whole edition (see `edition/1`).
  def id, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)

  # Records are stored as the shared Profile (SalixAgent.Profiles). The API
  # keeps its earlier shape: `credential_kind`, `provider`, `connection`, the
  # status words and the allowance as remaining percent with ISO times.
  def public(%{"credential" => "api_key"} = record) do
    connection = connection(record)

    %{
      "id" => record["id"],
      "version" => record["version"],
      "credential_kind" => "provider_api_key",
      # A key has no sign-in to expire; whether it works shows on use.
      "status" => "active",
      "source" => record["source"] || "custom",
      "name" => record["name"],
      "key_hint" => record["key_hint"],
      "models" => record["models"],
      "model_info" => record["model_info"] || %{},
      "disabled_models" => record["disabled_models"] || [],
      "connection" => connection,
      "compatible_runtimes" => compatible_runtimes(connection["protocol"]),
      "disabled" => record["disabled"] == true,
      "saved" => true,
      "actions" => ["edit_name", "edit_connection", "disable", "delete", "view_usage"]
    }
  end

  def public(%{"credential" => "subscription"} = record) do
    record
    |> Map.drop([
      "credential",
      "credentials",
      "prepared",
      "expires_at",
      "cooldown_until",
      "credential_revision",
      "refresh_deadline"
    ])
    |> Map.merge(%{
      "credential_kind" => "subscription_oauth",
      "provider" => record["source"],
      "status" => public_status(record["status"])
    })
    |> Map.put_new("name", record["email"])
    |> Map.put_new("disabled_models", [])
    |> then(fn view ->
      if is_map(record["quota"]),
        do: Map.put(view, "quota", public_quota(record["quota"])),
        else: view
    end)
  end

  def public(record),
    do:
      record
      |> Map.take(["id", "version"])
      |> Map.put("credential_kind", "unknown")

  @doc "A key's address as the runtimes are given it: `endpoint`, `protocol`, `auth_scheme`."
  def connection(record) do
    %{
      "endpoint" => record["endpoint"],
      "protocol" => wire_protocol(record["protocol"]),
      "auth_scheme" => record["auth"]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  @doc "How a runtime delivery names a record's credential (`credential_kind`)."
  def wire_kind(%{"credential" => "api_key"}), do: "provider_api_key"
  def wire_kind(%{"credential" => "subscription"}), do: "subscription_oauth"
  def wire_kind(_), do: nil

  @doc "The stored credential for a delivery's `credential_kind`."
  def stored_kind("provider_api_key"), do: "api_key"
  def stored_kind("subscription_oauth"), do: "subscription"
  def stored_kind(_), do: nil

  def wire_protocol("anthropic"), do: "anthropic_messages"
  def wire_protocol("chat_completions"), do: "openai_completions"
  def wire_protocol("responses"), do: "openai_responses"
  def wire_protocol(_), do: nil

  def stored_protocol("anthropic_messages"), do: "anthropic"
  def stored_protocol("openai_completions"), do: "chat_completions"
  def stored_protocol("openai_responses"), do: "responses"
  def stored_protocol(_), do: nil

  defp public_status("ok"), do: "active"
  defp public_status("login"), do: "reauthorization_required"
  defp public_status(other), do: other

  defp public_quota(quota) do
    quota
    |> Map.drop(["observed_at", "windows"])
    |> Map.merge(%{
      "observed_at" => iso(quota["observed_at"]),
      "windows" =>
        Enum.map(quota["windows"] || [], fn w ->
          %{
            "period" => period(w["minutes"]),
            "remaining_percent" => 100 - (w["used_percent"] || 0),
            "reset_at" => iso(w["resets_at"]),
            "model" => w["model"]
          }
          |> Map.reject(fn {_, v} -> is_nil(v) end)
        end)
    })
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  # The API's words for a window's length: a plan's short window, its week, its month.
  defp period(minutes) when is_integer(minutes) and minutes > 8 * 24 * 60, do: "month"
  defp period(minutes) when is_integer(minutes) and minutes > 24 * 60, do: "week"
  defp period(_), do: "short"

  defp iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp iso(_), do: nil

  defp compatible_runtimes("anthropic_messages"), do: ["claude"]
  defp compatible_runtimes(_), do: []

  def get(tenant, id) do
    case query("SELECT value, version FROM subscription_accounts WHERE tenant_id=$1 AND id=$2", [
           tenant,
           id
         ]) do
      {:ok, %{rows: [[value, version]]}} -> {:ok, Map.put(value, "version", version)}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  def create(tenant, value) do
    version = id()

    case query(
           "INSERT INTO subscription_accounts (tenant_id,id,value,version) VALUES ($1,$2,$3,$4)",
           [tenant, value["id"], value, version]
         ) do
      {:ok, _} -> {:ok, Map.put(value, "version", version)}
      error -> error
    end
  end

  def connect(tenant, provider, email, credentials) do
    email_key = if is_binary(email), do: email |> String.trim() |> String.downcase(), else: ""

    Repo.transaction(fn ->
      with {:ok, _} <- query("SET LOCAL lock_timeout = '5s'", []),
           # This lock serializes tenant imports across nodes. Hash collisions
           # only serialize unrelated tenants. They do not identify accounts.
           {:ok, _} <-
             query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
               "subscription-connect:" <> tenant
             ]),
           {:ok, %{rows: rows}} <-
             query(
               """
               SELECT value,version FROM subscription_accounts
               WHERE tenant_id=$1 AND value->>'source'=$2
                 AND value->>'credential'='subscription'
                 AND lower(btrim(value->>'email'))=$3 AND $3<>''
               ORDER BY id LIMIT 1 FOR UPDATE
               """,
               [tenant, provider, email_key]
             ),
           record = connected_record(rows, provider),
           {:ok, ciphertext} <- seal(tenant, record["id"], credentials),
           value =
             record
             |> Map.drop(["version", "quota", "expires_at", "cooldown_until", "reset_attempt"])
             |> Map.merge(%{
               "credential" => "subscription",
               "email" => email,
               "credentials" => ciphertext,
               "credential_revision" => id(),
               "status" => "ok",
               "prepared" => false
             }),
           {:ok, saved} <- save_connection(tenant, value, record["version"]) do
        saved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp connected_record([], provider),
    do: %{"id" => id(), "source" => provider, "disabled" => false}

  defp connected_record([[value, version]], _provider),
    do: Map.put(value, "version", version)

  defp save_connection(tenant, value, nil), do: create(tenant, value)

  defp save_connection(tenant, value, version) do
    with {:ok, saved} <- update(tenant, value, version),
         {:ok, _} <-
           query(
             "UPDATE subscription_accounts SET poll_delay_seconds=0,next_poll_at=now() WHERE tenant_id=$1 AND id=$2",
             [tenant, value["id"]]
           ) do
      {:ok, saved}
    end
  end

  # A version is `EDITION` or `EDITION.WRITE`. A write that a user asks for
  # (`update/3`) starts a new edition; a background write
  # (`update_background/3`: quota, credential refresh, cooldown, reset
  # bookkeeping) keeps the edition of the version it replaces. Two versions
  # of one account with the same edition differ only by background writes, so
  # the fields a user edits are the same in both. Versions written before
  # editions existed have no dot: each is its own edition.
  def update(tenant, value, expected), do: write(tenant, value, expected, id())

  @doc "Writes as `update/3`, keeping the edition of `expected`: a background write."
  def update_background(tenant, value, expected) when is_binary(expected),
    do: write(tenant, value, expected, edition(expected) <> "." <> id())

  def update_background(_tenant, _value, _expected), do: {:error, :conflict}

  @doc "The edition of an account version."
  def edition(version) when is_binary(version),
    do: version |> String.split(".", parts: 2) |> hd()

  defp write(tenant, value, expected, version) do
    case query(
           "UPDATE subscription_accounts SET value=$3,version=$4 WHERE tenant_id=$1 AND id=$2 AND version=$5",
           [tenant, value["id"], Map.delete(value, "version"), version, expected]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, Map.put(value, "version", version)}
      {:ok, _} -> {:error, :conflict}
      error -> error
    end
  end

  def delete(tenant, id, version) do
    case query("DELETE FROM subscription_accounts WHERE tenant_id=$1 AND id=$2 AND version=$3", [
           tenant,
           id,
           version
         ]) do
      {:ok, %{num_rows: 1}} -> {:ok, nil}
      {:ok, _} -> {:error, :conflict}
      error -> error
    end
  end

  @doc """
  Applies a user's change to the account as it is now. `expected` is the
  version the user saw: the current one, or one that only background writes
  have replaced since (same edition). Any other version is a conflict, as is a
  user write in between. The row stays locked from the check to the write, so
  a background write in between waits and then fails its own check.
  """
  def update_edition(tenant, id, expected, update, require_unbound \\ false)
      when is_function(update, 1) do
    locked_account(tenant, id, fn record ->
      cond do
        not is_binary(expected) or edition(record["version"]) != edition(expected) ->
          {:error, :conflict}

        require_unbound and binding_exists?(tenant, id) ->
          {:error, :account_in_use}

        true ->
          update.(record)
      end
    end)
  end

  @doc """
  Writes back the result of background work that called out after reading
  the account (a credential refresh, a quota or reset answer, a cooldown).
  Under the row lock, `change` is applied to the account as it is now when
  `still?` holds for it; otherwise the result is dropped as a conflict. A
  user's change made meanwhile is kept, and a replacement or a deletion is
  never overwritten or brought back.
  """
  def apply_background(tenant, id, still?, change)
      when is_function(still?, 1) and is_function(change, 1) do
    locked_account(tenant, id, fn current ->
      if still?.(current),
        do: update_background(tenant, change.(current), current["version"]),
        else: {:error, :conflict}
    end)
  end

  def update_locked(tenant, id, expected, update, require_unbound \\ false)
      when is_function(update, 1) do
    locked_account(tenant, id, fn record ->
      cond do
        record["version"] != expected ->
          {:error, :conflict}

        require_unbound and binding_exists?(tenant, id) ->
          {:error, :account_in_use}

        true ->
          update.(record)
      end
    end)
  end

  @doc """
  Deletes the account a user saw at `expected`, as `update_edition/5`
  applies a change: background writes since do not make it a conflict.
  """
  def delete_edition(tenant, id, expected, require_unbound \\ false) do
    locked_account(tenant, id, fn record ->
      cond do
        not is_binary(expected) or edition(record["version"]) != edition(expected) ->
          {:error, :conflict}

        require_unbound and binding_exists?(tenant, id) ->
          {:error, :account_in_use}

        true ->
          delete(tenant, id, record["version"])
      end
    end)
  end

  def delete_locked(tenant, id, expected) do
    locked_account(tenant, id, fn record ->
      cond do
        record["version"] != expected -> {:error, :conflict}
        binding_exists?(tenant, id) -> {:error, :account_in_use}
        true -> delete(tenant, id, expected)
      end
    end)
  end

  def locked_account(tenant, id, operation) when is_function(operation, 1) do
    Repo.transaction(fn ->
      with {:ok, %{rows: [[value, version]]}} <-
             query(
               "SELECT value,version FROM subscription_accounts WHERE tenant_id=$1 AND id=$2 FOR UPDATE",
               [tenant, id]
             ),
           result <- operation.(Map.put(value, "version", version)) do
        case result do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:ok, %{rows: []}} -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def binding_exists?(tenant, id) do
    case query(
           "SELECT EXISTS(SELECT 1 FROM runtime_subscription_bindings WHERE tenant_id=$1 AND account_id=$2)",
           [tenant, id]
         ) do
      {:ok, %{rows: [[exists]]}} -> exists
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def list_bindings(tenant, account_id, after_id \\ 0) do
    with true <- is_integer(after_id) and after_id >= 0,
         {:ok, %{rows: rows}} <-
           query(
             """
             SELECT id,project_id,workload_id,group_id,device_id,device_runtime_id,enabled,status
             FROM runtime_subscription_bindings
             WHERE tenant_id=$1 AND account_id=$2 AND id>$3
             ORDER BY id LIMIT 26
             """,
             [tenant, account_id, after_id]
           ) do
      bindings =
        rows
        |> Enum.take(25)
        |> Enum.map(fn [id, project, workload, group, device, runtime, enabled, status] ->
          %{
            "id" => id,
            "project_id" => project,
            "workload_id" => workload,
            "group_id" => group,
            "device_id" => device,
            "device_runtime_id" => runtime,
            "enabled" => enabled,
            "status" => status
          }
        end)

      {:ok,
       %{
         "bindings" => bindings,
         "next" => if(length(rows) > 25, do: List.last(bindings)["id"], else: nil)
       }}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  # API-key Profiles a request may use. A tenant connects a handful; the cap
  # keeps one dispatch bounded however many are saved.
  @doc "Whether one of the tenant's Custom Profiles lists the model id."
  def custom_model?(tenant, model), do: match?({:ok, _}, custom_model_info(tenant, model))

  @doc """
  A Custom Profile of the tenant that lists `model`: `{:ok, info}`, with what
  that Profile says of the model in `model_info` (`%{}` when nothing), or
  `:error` when none lists it.
  """
  def custom_model_info(tenant, model) when is_binary(model) do
    case query(
           """
           SELECT value->'model_info'->$2 FROM subscription_accounts
           WHERE tenant_id=$1 AND value->>'credential'='api_key'
             AND value->>'source'='custom' AND value->'models' ? $2
           ORDER BY (value->'model_info' ? $2) DESC, id
           LIMIT 1
           """,
           [tenant, model]
         ) do
      {:ok, %{rows: [[info]]}} when is_map(info) -> {:ok, info}
      {:ok, %{rows: [_]}} -> {:ok, %{}}
      _ -> :error
    end
  end

  def custom_model_info(_, _), do: :error

  def usable_api_keys(tenant) do
    with {:ok, %{rows: rows}} <-
           query(
             """
             SELECT value,version FROM subscription_accounts
             WHERE tenant_id=$1 AND value->>'credential'='api_key'
               AND value->>'disabled'='false'
             ORDER BY id LIMIT 50
             """,
             [tenant]
           ) do
      {:ok, Enum.map(rows, fn [value, version] -> Map.put(value, "version", version) end)}
    end
  end

  @serving_profile_limit 100

  @doc """
  Up to 100 Profiles that can serve Agent requests now: enabled API keys and
  enabled, signed-in subscriptions. `truncated` is true when more exist.
  """
  def serving_profiles(tenant) do
    with {:ok, %{rows: rows}} <-
           query(
             """
             SELECT value,version FROM subscription_accounts
             WHERE tenant_id=$1 AND value->>'disabled'='false'
               AND (value->>'credential'='api_key'
                 OR (value->>'credential'='subscription' AND value->>'status'='ok'))
             ORDER BY id LIMIT $2
             """,
             [tenant, @serving_profile_limit + 1]
           ) do
      {:ok,
       %{
         profiles:
           rows
           |> Enum.take(@serving_profile_limit)
           |> Enum.map(fn [value, version] -> Map.put(value, "version", version) end),
         truncated: length(rows) > @serving_profile_limit
       }}
    end
  end

  # Comma apps released before Profiles parse only Codex and Claude
  # subscriptions and fail the whole page on any other account.
  @legacy_view "AND value->>'credential'='subscription' AND value->>'source' IN ('codex','claude')"

  @doc """
  One page of accounts. `:legacy` lists only Codex and Claude subscriptions,
  the accounts that Comma apps released before Profiles can show.
  """
  def list(tenant, after_id, view \\ :all) do
    filter = if view == :legacy, do: @legacy_view, else: ""

    with {:ok, %{rows: rows}} <-
           query(
             "SELECT value,version FROM subscription_accounts WHERE tenant_id=$1 AND id>$2 #{filter} ORDER BY id LIMIT 26",
             [tenant, after_id]
           ) do
      accounts =
        Enum.take(rows, 25)
        |> Enum.map(fn [value, version] -> value |> Map.put("version", version) |> public() end)

      {:ok,
       %{
         "accounts" => accounts,
         "next" => if(length(rows) > 25, do: List.last(accounts)["id"], else: "")
       }}
    end
  end

  # A runtime may serve multiple models. Only a provider-wide window used up
  # blocks the whole target (SalixAgent.Profiles: a refill due is whole again).
  def runtime_quota_exhausted?(tenant, account) do
    case get(tenant, account) do
      {:ok, %{"credential" => "subscription"} = record} -> SalixAgent.Profiles.exhausted?(record)
      _ -> false
    end
  end

  @runtime_candidate_scan 50

  @doc "Bounded compatible account candidates for automatic Cloud VM runtime binding."
  def runtime_candidates(tenant, provider, after_id \\ "") when provider in ~w(codex claude) do
    now = SystemsClock.system_time(:millisecond)

    query(
      """
      SELECT value,version FROM subscription_accounts
      WHERE tenant_id=$1 AND id>$3 AND value->>'disabled'='false'
        AND ((value->>'credential'='subscription' AND value->>'source'=$2 AND value->>'status'='ok')
          OR ($2='claude' AND value->>'credential'='api_key' AND value->>'protocol'='anthropic'))
      ORDER BY id LIMIT #{@runtime_candidate_scan}
      """,
      [tenant, provider, after_id]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.map(fn [value, _version] -> value end)
         |> Enum.filter(fn record ->
           record["credential"] == "api_key" or
             (not SalixAgent.Profiles.exhausted?(record) and
                (record["cooldown_until"] || 0) <= now)
         end)
         |> Enum.take(3)
         |> Enum.map(& &1["id"])}

      _ ->
        {:error, :account_pool_unavailable}
    end
  end

  @station_accounts 50

  @doc """
  The enabled accounts a Workload's station can run Claude or Codex with: their
  subscriptions, and API keys of the Anthropic protocol (Claude's). First
  #{@station_accounts}, by id.
  """
  def station_accounts(tenant) do
    query(
      """
      SELECT value,version FROM subscription_accounts
      WHERE tenant_id=$1 AND value->>'disabled'='false'
        AND ((value->>'credential'='subscription' AND value->>'source' IN ('claude','codex'))
          OR (value->>'credential'='api_key' AND value->>'protocol'='anthropic'))
      ORDER BY id LIMIT #{@station_accounts}
      """,
      [tenant]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [value, version] -> Map.put(value, "version", version) end)}

      _ ->
        {:error, :account_pool_unavailable}
    end
  end

  # Discovery needs one enabled account, even when its inference quota is exhausted.
  def discovery_account(tenant, provider) do
    sql = """
    SELECT value,version FROM subscription_accounts
    WHERE tenant_id=$1 AND value->>'source'=$2
      AND value->>'credential'='subscription'
      AND value->>'disabled'='false' AND value->>'status'='ok'
    ORDER BY id LIMIT 1
    """

    case query(sql, [tenant, provider]) do
      {:ok, %{rows: [[value, version]]}} -> {:ok, Map.put(value, "version", version)}
      {:ok, %{rows: []}} -> {:error, :model_discovery_no_account}
      {:error, reason} -> {:error, reason}
    end
  end

  # Indexed tenant lookup; ranking is performed in the database and returns only
  # three candidates. The request path never loads a whole pool into the caller.
  # `only`: one account id (a pin), which then passes the same filter.
  # `exclude`: accounts this request already tried.
  # `catalog_model`: the catalog id served; an account that turned it off is skipped.
  # A tenant's accounts of one provider are few: all are read, and the
  # Profiles' pool (SalixAgent.Profiles, the one a station runs) orders them.
  @candidate_scan 200

  def candidates(tenant, provider, model, only \\ nil, exclude \\ [], catalog_model \\ nil) do
    sql = """
    SELECT value,version FROM subscription_accounts a
    WHERE tenant_id=$1 AND value->>'source'=$2
      AND value->>'credential'='subscription' AND value->>'disabled'='false'
      AND value->>'status'='ok'
      AND ($3::text IS NULL OR a.id=$3)
      AND NOT (a.id = ANY($4::text[]))
    ORDER BY a.id LIMIT #{@candidate_scan}
    """

    with {:ok, %{rows: rows}} <- query(sql, [tenant, provider, only, exclude]) do
      records = Enum.map(rows, fn [v, version] -> Map.put(v, "version", version) end)

      {:ok,
       records
       |> SalixAgent.Profiles.rank(model: catalog_model, provider_model: model)
       |> Enum.take(3)}
    end
  end

  def query(sql, args) do
    result = Repo.query(sql, args, log: false)

    if match?({:error, _}, result) do
      SalixAgent.SubscriptionLog.emit("subscription_storage_failure",
        outcome: "error",
        error_code: "storage_error"
      )
    end

    result
  end
end
