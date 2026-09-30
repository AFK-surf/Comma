defmodule SalixAgent.SubscriptionStore do
  @moduledoc false
  alias SalixStore.Repo

  # The operator secret protects stored subscription material. Tenant and record
  # identity bind ciphertext to its owner, as in the previous encrypted vault.
  def seal(tenant, id, value) do
    with {:ok, key} <- key() do
      nonce = :crypto.strong_rand_bytes(12)

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
    case Application.get_env(:salix_agent, :subscription_storage_key) do
      secret when is_binary(secret) and byte_size(secret) == 32 ->
        {:ok, secret}

      _ ->
        {:error, :not_configured}
    end
  end

  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  def public(%{"credential_kind" => "provider_api_key"} = record) do
    connection = Map.take(record["connection"] || %{}, ~w(endpoint protocol auth_scheme))

    %{
      "id" => record["id"],
      "version" => record["version"],
      "credential_kind" => "provider_api_key",
      "name" => record["name"],
      "connection" => connection,
      "compatible_runtimes" => compatible_runtimes(connection["protocol"]),
      "disabled" => record["disabled"] == true,
      "saved" => true,
      "actions" => ["edit_name", "edit_connection", "disable", "delete", "view_usage"]
    }
  end

  def public(%{"credential_kind" => "subscription_oauth"} = record) do
    record
    |> Map.drop([
      "credentials",
      "prepared",
      "expires_at",
      "cooldown_until",
      "credential_revision",
      "refresh_deadline"
    ])
  end

  def public(record),
    do:
      record
      |> Map.take(["id", "version"])
      |> Map.put("credential_kind", "unknown")

  defp compatible_runtimes("anthropic_messages"), do: ["pi", "claude"]

  defp compatible_runtimes(protocol) when protocol in ["openai_completions", "openai_responses"],
    do: ["pi"]

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
               WHERE tenant_id=$1 AND value->>'provider'=$2
                 AND value->>'credential_kind'='subscription_oauth'
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
               "credential_kind" => "subscription_oauth",
               "email" => email,
               "credentials" => ciphertext,
               "credential_revision" => id(),
               "status" => "active",
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
    do: %{"id" => id(), "provider" => provider, "disabled" => false}

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

  def update(tenant, value, expected) do
    version = id()

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

  def list(tenant, after_id) do
    with {:ok, %{rows: rows}} <-
           query(
             "SELECT value,version FROM subscription_accounts WHERE tenant_id=$1 AND id>$2 ORDER BY id LIMIT 26",
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

  # A runtime may serve multiple models. Only a provider-wide exhausted window
  # blocks the whole target; an expired reset or unknown quota is not exhaustion.
  @runtime_exhausted """
  EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(value->'quota'->'windows','[]'::jsonb)) w
    WHERE COALESCE(w->>'model','')='' AND (w->>'remaining_percent')::float=0
      AND (w->>'reset_at')::timestamptz>now()
  )
  """

  def runtime_quota_exhausted?(tenant, account) do
    case query(
           "SELECT #{@runtime_exhausted} FROM subscription_accounts WHERE tenant_id=$1 AND id=$2 AND value->>'credential_kind'='subscription_oauth'",
           [tenant, account]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc "Bounded compatible account candidates for automatic Cloud VM runtime binding."
  def runtime_candidates(tenant, provider, after_id \\ "") when provider in ~w(codex claude) do
    query(
      """
      SELECT id FROM subscription_accounts
      WHERE tenant_id=$1 AND id>$3 AND value->>'disabled'='false'
        AND ((value->>'credential_kind'='subscription_oauth'
              AND value->>'provider'=$2 AND value->>'status'='active'
              AND NOT (#{@runtime_exhausted})
              AND COALESCE((value->>'cooldown_until')::timestamptz,now())<=now())
          OR ($2='claude' AND value->>'credential_kind'='provider_api_key'
              AND value->'connection'->>'protocol'='anthropic_messages'))
      ORDER BY id LIMIT 3
      """,
      [tenant, provider, after_id]
    )
    |> case do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      _ -> {:error, :account_pool_unavailable}
    end
  end

  # Discovery needs one enabled account, even when its inference quota is exhausted.
  def discovery_account(tenant, provider) do
    sql = """
    SELECT value,version FROM subscription_accounts
    WHERE tenant_id=$1 AND value->>'provider'=$2
      AND value->>'credential_kind'='subscription_oauth'
      AND value->>'disabled'='false' AND value->>'status'='active'
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
  def candidates(tenant, provider, model) do
    sql = """
    SELECT value,version FROM subscription_accounts a
    LEFT JOIN LATERAL (
      SELECT w FROM jsonb_array_elements(COALESCE(a.value->'quota'->'windows','[]'::jsonb)) w
      WHERE w->>'period' IN ('week','month') AND COALESCE(w->>'model','')=''
      ORDER BY CASE w->>'period' WHEN 'week' THEN 0 ELSE 1 END LIMIT 1
    ) q ON true
    WHERE tenant_id=$1 AND value->>'provider'=$2
      AND value->>'credential_kind'='subscription_oauth' AND value->>'disabled'='false'
      AND value->>'status'='active'
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(a.value->'quota'->'windows','[]'::jsonb)) AS blocked(item)
        WHERE (blocked.item->>'remaining_percent')::float=0 AND (blocked.item->>'reset_at')::timestamptz>now()
          AND (COALESCE(blocked.item->>'model','')='' OR strpos(lower($3),lower(blocked.item->>'model'))>0)
      )
    ORDER BY
      CASE WHEN (value->>'cooldown_until')::timestamptz>now() THEN 1 ELSE 0 END,
      CASE WHEN (value->>'cooldown_until')::timestamptz>now() THEN (value->>'cooldown_until')::timestamptz END ASC NULLS FIRST,
      CASE WHEN value->'quota'->>'observed_at' IS NULL OR (value->'quota'->>'observed_at')::timestamptz < now()-interval '15 minutes'
             OR (q.w->>'reset_at')::timestamptz<=now() OR q.w IS NULL THEN 0
           WHEN (q.w->>'reset_at')::timestamptz<now()+interval '1 day' THEN 2 ELSE 1 END DESC,
      CASE WHEN (q.w->>'reset_at')::timestamptz<now()+interval '1 day' THEN (q.w->>'reset_at')::timestamptz END ASC,
      (q.w->>'remaining_percent')::float / GREATEST(EXTRACT(EPOCH FROM ((q.w->>'reset_at')::timestamptz-now()))/86400,0.00001) DESC NULLS LAST,
      a.id ASC
    LIMIT 3
    """

    with {:ok, %{rows: rows}} <- query(sql, [tenant, provider, model || ""]) do
      {:ok, Enum.map(rows, fn [v, version] -> Map.put(v, "version", version) end)}
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
