defmodule SalixAgent.AccountPool do
  @moduledoc "Salix-owned subscription accounts and SDK dispatch."
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixAgent.SubscriptionLog, as: Log

  def connection(tenant) when is_binary(tenant) do
    key = Application.get_env(:salix_agent, :subscription_storage_key)

    if SalixStore.Ids.valid_tenant_id?(tenant) and is_binary(key) and byte_size(key) == 32,
      do: :ok,
      else: {:error, :not_configured}
  end

  def connection(_), do: {:error, :not_configured}

  def adapter(tenant, path, body, request_opts \\ []) do
    with :ok <- connection(tenant) do
      opts =
        cond do
          path == "/prepare" and body["force_refresh"] == true -> [timeout: 8_000]
          path == "/subscription/seal" -> [timeout: 2_000]
          path in ["/oauth/device/begin", "/oauth/device/poll"] -> [timeout: 30_000]
          true -> []
        end

      case SalixAgent.SubscriptionWorker.request(
             path,
             body,
             %{},
             Keyword.merge(opts, request_opts)
           ) do
        {:ok, data} ->
          Jason.decode(data)

        {:error, status, _, _} when status in [400, 422] ->
          {:error, :invalid_input}

        {:error, status, code, _} ->
          if SalixAgent.SubscriptionWorker.rejected_before_execution?(status, code),
            do: {:error, {:worker_rejected, status, code}},
            else: {:error, :unavailable}

        _ ->
          {:error, :unavailable}
      end
    end
  end

  @doc "Codex access-only projection for trusted runtime delivery. The pool owns refresh."
  def codex_access(tenant, id, rejected_revision \\ nil) do
    with :ok <- connection(tenant),
         {:ok, record} <- Store.get(tenant, id),
         true <- usable_codex?(record),
         {:ok, credentials} <- Store.open(tenant, id, record["credentials"]),
         {:ok, record, credentials} <-
           runtime_prepare(tenant, record, credentials, rejected_revision),
         {:ok, current} <- Store.get(tenant, id),
         true <- usable_codex?(current) and current["credentials"] == record["credentials"],
         access when is_binary(access) and byte_size(access) > 0 <- credentials["access_token"],
         account when is_binary(account) and byte_size(account) > 0 <- credentials["account_id"],
         {:ok, expires, _} <- DateTime.from_iso8601(credentials["expired"] || ""),
         true <- DateTime.diff(expires, DateTime.utc_now()) > 30 do
      {:ok,
       %{
         "credential_kind" => "subscription_oauth",
         "subscription_account_id" => id,
         "access_token" => access,
         "chatgpt_account_id" => account,
         "expires_at" => DateTime.to_unix(expires),
         "credential_revision" => record["credential_revision"] || record["version"],
         "account_version" => current["version"]
       }}
    else
      _ -> {:error, :subscription_access_unavailable}
    end
  end

  @doc "Typed runtime credential projection for one authoritative native target."
  def runtime_access(tenant, id, provider, rejected_revision \\ nil)

  def runtime_access(tenant, id, "codex", rejected_revision),
    do: codex_access(tenant, id, rejected_revision)

  def runtime_access(tenant, id, "claude", rejected_revision) do
    with {:ok, record} <- Store.get(tenant, id) do
      if record["credential_kind"] == "subscription_oauth" do
        claude_oauth_access(tenant, record, rejected_revision)
      else
        provider_key_access(tenant, id, "claude")
      end
    end
  end

  def runtime_access(tenant, id, "pi", _rejected_revision),
    do: provider_key_access(tenant, id, "pi")

  def runtime_access(_, _, _, _), do: {:error, :subscription_access_unavailable}

  defp provider_key_access(tenant, id, provider) do
    with :ok <- connection(tenant),
         {:ok, record} <- Store.get(tenant, id),
         true <- record["credential_kind"] == "provider_api_key",
         true <- record["disabled"] == false,
         true <- provider in compatible_runtimes(record["connection"]["protocol"]),
         {:ok, %{"api_key" => api_key}} <- Store.open(tenant, id, record["credentials"]),
         true <- is_binary(api_key) and byte_size(api_key) > 0 do
      {:ok,
       %{
         "credential_kind" => "provider_api_key",
         "subscription_account_id" => id,
         "connection" => Map.take(record["connection"], ~w(endpoint protocol auth_scheme)),
         "api_key" => api_key,
         "account_version" => record["version"]
       }}
    else
      _ -> {:error, :subscription_access_unavailable}
    end
  end

  defp claude_oauth_access(tenant, record, rejected) do
    id = record["id"]

    with :ok <- connection(tenant),
         true <-
           record["provider"] == "claude" and record["status"] == "active" and
             record["disabled"] == false,
         {:ok, credentials} <- Store.open(tenant, id, record["credentials"]),
         {:ok, record, credentials} <- runtime_prepare(tenant, record, credentials, rejected),
         {:ok, current} <- Store.get(tenant, id),
         true <-
           current["disabled"] == false and current["status"] == "active" and
             current["credentials"] == record["credentials"],
         token when is_binary(token) and byte_size(token) > 0 <- credentials["access_token"],
         {:ok, expires, _} <- DateTime.from_iso8601(credentials["expired"] || ""),
         true <- DateTime.diff(expires, DateTime.utc_now()) > 30 do
      {:ok,
       %{
         "credential_kind" => "subscription_oauth",
         "subscription_account_id" => id,
         "access_token" => token,
         "expires_at" => DateTime.to_unix(expires),
         "credential_revision" => record["credential_revision"] || record["version"],
         "account_version" => current["version"]
       }}
    else
      _ -> {:error, :subscription_access_unavailable}
    end
  end

  def compatible_runtimes("anthropic_messages"), do: ["pi", "claude"]

  def compatible_runtimes(protocol) when protocol in ["openai_completions", "openai_responses"],
    do: ["pi"]

  def compatible_runtimes(_), do: []

  defp usable_codex?(record),
    do:
      subscription?(record) and record["provider"] == "codex" and record["status"] == "active" and
        record["disabled"] == false

  defp subscription?(record), do: record["credential_kind"] == "subscription_oauth"

  defp runtime_prepare(tenant, record, credentials, rejected_revision) do
    expires_soon =
      case DateTime.from_iso8601(credentials["expired"] || "") do
        {:ok, expires, _} -> DateTime.diff(expires, DateTime.utc_now()) < 300
        _ -> true
      end

    rejected =
      is_binary(rejected_revision) and
        rejected_revision == (record["credential_revision"] || record["version"])

    if expires_soon or rejected,
      do: refresh(tenant, record, true),
      else: {:ok, record, credentials}
  end

  def list(tenant, after_id \\ "") do
    with :ok <- connection(tenant), do: Store.list(tenant, after_id)
  end

  def create(tenant, %{"credential_kind" => "subscription_oauth"} = attrs) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("subscription_account_create", [], fn ->
        with true <- attrs["provider"] in ["codex", "claude"],
             {:ok, data} <- adapter(tenant, "/normalize", attrs),
             {:ok, record} <-
               Store.connect(tenant, attrs["provider"], data["email"], data["credentials"]) do
          # The imported credentials are already normalized. A failed details
          # read must not turn a saved account into a failed import.
          result =
            Log.span("subscription_account_quota", [account_id: record["id"]], fn ->
              fetch_quota(tenant, record, data["credentials"], timeout: 8_000)
            end)

          case result do
            {:ok, account} -> {:ok, account}
            _ -> {:ok, Store.public(record)}
          end
        else
          false -> {:error, :invalid_input}
          other -> other
        end
      end)
    end)
  end

  def create(tenant, %{"credential_kind" => "provider_api_key"} = attrs) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("provider_account_create", [], fn ->
        with :ok <- connection(tenant),
             {:ok, value} <- provider_value(Map.delete(attrs, "credential_kind")),
             id = Store.id(),
             {:ok, ciphertext} <- Store.seal(tenant, id, value.credentials),
             {:ok, record} <-
               Store.create(
                 tenant,
                 value.public
                 |> Map.merge(%{
                   "id" => id,
                   "credential_kind" => "provider_api_key",
                   "provider" => "custom",
                   "credentials" => ciphertext,
                   "disabled" => false
                 })
               ) do
          {:ok, Store.public(record)}
        end
      end)
    end)
  end

  def create(_, _), do: {:error, :invalid_input}

  def update(tenant, id, attrs) do
    Log.context([tenant_id: tenant, account_id: id], fn ->
      Log.span("account_update", [], fn ->
        with {:ok, record} <- Store.get(tenant, id),
             {:ok, updated} <- update_record(tenant, record, attrs) do
          {:ok, Store.public(updated)}
        end
      end)
    end)
  end

  defp update_record(tenant, %{"credential_kind" => "subscription_oauth"} = record, attrs) do
    with true <- record["version"] == attrs["version"],
         {:ok, record} <- replacement(tenant, record, attrs["credentials"]),
         {:ok, updated} <-
           Store.update(
             tenant,
             Map.merge(record, Map.take(attrs, ["disabled"])),
             attrs["version"]
           ) do
      {:ok, updated}
    else
      false -> {:error, :conflict}
      other -> other
    end
  end

  defp update_record(tenant, %{"credential_kind" => "provider_api_key"} = record, attrs) do
    expected = attrs["version"]

    cond do
      Map.keys(attrs) |> Enum.sort() == ["name", "version"] ->
        with {:ok, name} <- provider_name(attrs["name"]) do
          Store.update_locked(tenant, record["id"], expected, fn current ->
            Store.update(tenant, Map.put(current, "name", name), expected)
          end)
        end

      Map.keys(attrs) |> Enum.sort() == ["disabled", "version"] and is_boolean(attrs["disabled"]) ->
        Store.update_locked(tenant, record["id"], expected, fn current ->
          Store.update(tenant, Map.put(current, "disabled", attrs["disabled"]), expected)
        end)

      Map.keys(attrs) |> Enum.sort() == ["connection", "credentials", "version"] ->
        with {:ok, value} <-
               provider_value(%{
                 "name" => record["name"],
                 "connection" => attrs["connection"],
                 "credentials" => attrs["credentials"]
               }) do
          Store.update_locked(
            tenant,
            record["id"],
            expected,
            fn current ->
              with {:ok, ciphertext} <- Store.seal(tenant, record["id"], value.credentials) do
                Store.update(
                  tenant,
                  current
                  |> Map.put("connection", value.public["connection"])
                  |> Map.put("credentials", ciphertext),
                  expected
                )
              end
            end,
            true
          )
        end

      true ->
        {:error, :invalid_input}
    end
  end

  defp update_record(_, _, _), do: {:error, :invalid_input}

  defp replacement(_tenant, record, nil), do: {:ok, record}

  defp replacement(tenant, record, credentials) do
    with {:ok, data} <-
           adapter(tenant, "/normalize", %{
             "provider" => record["provider"],
             "credentials" => credentials
           }),
         {:ok, ciphertext} <- Store.seal(tenant, record["id"], data["credentials"]) do
      {:ok,
       record
       |> Map.merge(%{
         "credentials" => ciphertext,
         "credential_revision" => Store.id(),
         "email" => data["email"],
         "status" => "active",
         "prepared" => false
       })
       |> Map.drop(["quota", "reset_attempt"])}
    end
  end

  def delete(tenant, id, version) do
    Log.context([tenant_id: tenant, account_id: id], fn ->
      Log.span("account_delete", [], fn ->
        with {:ok, record} <- Store.get(tenant, id) do
          if record["credential_kind"] == "provider_api_key",
            do: Store.delete_locked(tenant, id, version),
            else: Store.delete(tenant, id, version)
        else
          {:error, :not_found} -> {:error, :conflict}
          other -> other
        end
      end)
    end)
  end

  def list_bindings(tenant, account_id, after_id \\ 0) do
    with :ok <- connection(tenant),
         {:ok, _} <- Store.get(tenant, account_id),
         do: Store.list_bindings(tenant, account_id, after_id)
  end

  defp provider_value(attrs) when is_map(attrs) and map_size(attrs) == 3 do
    with {:ok, name} <- provider_name(attrs["name"]),
         {:ok, connection} <- provider_connection(attrs["connection"]),
         {:ok, api_key} <- provider_key(attrs["credentials"]) do
      {:ok,
       %{
         public: %{"name" => name, "connection" => connection},
         credentials: %{"api_key" => api_key}
       }}
    end
  end

  defp provider_value(_), do: {:error, :invalid_input}

  defp provider_name(name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and String.length(name) <= 80 and byte_size(name) <= 320 and not control?(name),
      do: {:ok, name},
      else: {:error, :invalid_input}
  end

  defp provider_name(_), do: {:error, :invalid_input}

  defp provider_connection(connection) when is_map(connection) and map_size(connection) == 3 do
    endpoint = connection["endpoint"]
    protocol = connection["protocol"]
    auth_scheme = connection["auth_scheme"]
    uri = if is_binary(endpoint), do: URI.parse(endpoint), else: %URI{}

    valid_pair =
      {protocol, auth_scheme} in [
        {"anthropic_messages", "bearer"},
        {"anthropic_messages", "api_key"},
        {"openai_completions", "bearer"},
        {"openai_responses", "bearer"}
      ]

    if is_binary(endpoint) and byte_size(endpoint) <= 2048 and not control?(endpoint) and
         uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and valid_pair do
      {:ok, Map.take(connection, ~w(endpoint protocol auth_scheme))}
    else
      {:error, :invalid_input}
    end
  end

  defp provider_connection(_), do: {:error, :invalid_input}

  defp provider_key(%{"api_key" => api_key})
       when is_binary(api_key) and byte_size(api_key) > 0 and byte_size(api_key) <= 16_384 do
    if control?(api_key), do: {:error, :invalid_input}, else: {:ok, api_key}
  end

  defp provider_key(_), do: {:error, :invalid_input}

  defp control?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/u)

  # Claim before external refresh. If the process dies or the response is lost,
  # the account remains unavailable until reauthorization replaces its material.
  # A late result cannot overwrite a replacement or resurrect a deleted record.
  defp prepare(tenant, record) do
    if subscription?(record) and record["prepared"] == true and
         not expiring?(record["expires_at"]) do
      with {:ok, credentials} <- Store.open(tenant, record["id"], record["credentials"]),
           do: {:ok, record, credentials}
    else
      if subscription?(record), do: refresh(tenant, record), else: {:error, :invalid_input}
    end
  end

  defp expiring?(nil), do: false

  defp expiring?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.diff(time, DateTime.utc_now()) < 30
      _ -> false
    end
  end

  defp refresh(tenant, record, force \\ false) do
    Log.context([tenant_id: tenant, account_id: record["id"], provider: record["provider"]], fn ->
      Log.span("subscription_account_refresh", [], fn ->
        with true <- record["status"] == "active",
             true <- subscription?(record),
             {:ok, claimed} <-
               Store.update(
                 tenant,
                 Map.merge(record, %{
                   "status" => "reauthorization_required",
                   "refresh_deadline" =>
                     System.system_time(:second) +
                       if(force, do: 10, else: div(SalixAgent.LLM.request_timeout_ms(), 1000) + 5)
                 }),
                 record["version"]
               ),
             {:ok, credentials} <- Store.open(tenant, record["id"], record["credentials"]),
             {:ok, data} <-
               prepare_admitted(tenant, record, claimed, credentials, force),
             {:ok, ciphertext} <- Store.seal(tenant, record["id"], data["credentials"]),
             {:ok, saved} <-
               Store.update(
                 tenant,
                 Map.merge(claimed, %{
                   "status" => "active",
                   "refresh_deadline" => nil,
                   "credentials" => ciphertext,
                   "credential_revision" => Store.id(),
                   "email" => data["email"],
                   "prepared" => true,
                   "expires_at" => data["credentials"]["expired"]
                 }),
                 claimed["version"]
               ) do
          {:ok, saved, data["credentials"]}
        else
          false -> {:error, :authorization_unavailable}
          other -> other
        end
      end)
    end)
  end

  defp prepare_admitted(tenant, record, claimed, credentials, force) do
    case adapter(tenant, "/prepare", %{
           "provider" => record["provider"],
           "force_refresh" => force,
           "credentials" => credentials
         }) do
      {:error, {:worker_rejected, _, _}} = error ->
        # No executor ran, so the original credential remains usable for a later refresh.
        # The claim version prevents restoration over a concurrent edit or deletion.
        with {:ok, _} <- Store.update(tenant, record, claimed["version"]), do: error

      result ->
        result
    end
  end

  def quota(tenant, id) do
    Log.context([tenant_id: tenant, account_id: id], fn ->
      Log.span("subscription_account_quota", [], fn ->
        with {:ok, record} <- Store.get(tenant, id),
             true <- subscription?(record),
             {:ok, record, credentials} <- prepare(tenant, record) do
          fetch_quota(tenant, record, credentials)
        else
          false -> {:error, :invalid_input}
          other -> other
        end
      end)
    end)
  end

  defp fetch_quota(tenant, record, credentials, opts \\ []) do
    with {:ok, snapshot} <-
           adapter(
             tenant,
             "/quota",
             %{
               "provider" => record["provider"],
               "credentials" => credentials
             },
             opts
           ),
         {:ok, saved} <-
           Store.update(tenant, Map.put(record, "quota", snapshot), record["version"]) do
      {:ok, Store.public(saved)}
    end
  end

  # Persist the logical attempt before the external side effect. An uncertain
  # response leaves its key available for retry, including after a UI reconnect.
  def reset_quota(tenant, id, %{"version" => version, "request_id" => key})
      when is_binary(version) and is_binary(key) do
    Log.context([tenant_id: tenant, account_id: id], fn ->
      Log.span("subscription_account_reset", [], fn ->
        with :ok <- connection(tenant),
             true <- Regex.match?(~r/^[A-Za-z0-9_-]{16,128}$/, key),
             {:ok, record} <- Store.get(tenant, id),
             true <- record["provider"] == "codex",
             true <- record["status"] == "active",
             :ok <- reset_admission(record, version, key),
             {:ok, record, credentials} <- prepare(tenant, record),
             {:ok, claimed} <- claim_reset(tenant, record, key),
             {:ok, result} <- execute_reset(tenant, claimed, credentials),
             {:ok, saved} <- settle_reset(tenant, claimed, result) do
          # Do not turn a completed reset into a failed mutation if this read fails.
          case quota(tenant, id) do
            {:ok, account} ->
              {:ok,
               %{"outcome" => result["code"], "account" => account, "quota_refreshed" => true}}

            _ ->
              {:ok,
               %{
                 "outcome" => result["code"],
                 "account" => Store.public(saved),
                 "quota_refreshed" => false
               }}
          end
        else
          false -> {:error, :invalid_input}
          error -> error
        end
      end)
    end)
  end

  def reset_quota(_, _, _), do: {:error, :invalid_input}

  defp reset_admission(record, version, key) do
    case record["reset_attempt"] do
      %{"request_id" => ^key} -> :ok
      %{"outcome" => "pending"} -> {:error, :reset_in_progress}
      _ -> if record["version"] == version, do: :ok, else: {:error, :conflict}
    end
  end

  defp claim_reset(tenant, record, key) do
    case record["reset_attempt"] do
      %{"request_id" => ^key} ->
        {:ok, record}

      _ ->
        Store.update(
          tenant,
          Map.put(record, "reset_attempt", %{"request_id" => key, "outcome" => "pending"}),
          record["version"]
        )
    end
  end

  defp execute_reset(tenant, record, credentials) do
    attempt = record["reset_attempt"]

    if attempt["outcome"] == "pending" do
      case adapter(tenant, "/quota/reset", %{
             "provider" => "codex",
             "credentials" => credentials,
             "redeem_request_id" => attempt["request_id"]
           }) do
        {:ok, %{"code" => code} = result}
        when code in ~w(reset already_redeemed nothing_to_reset no_credit) ->
          {:ok, result}

        _ ->
          {:error, :reset_pending}
      end
    else
      {:ok, %{"code" => attempt["outcome"]}}
    end
  end

  defp settle_reset(tenant, record, result) do
    if record["reset_attempt"]["outcome"] == result["code"] do
      {:ok, record}
    else
      value = put_in(record, ["reset_attempt", "outcome"], result["code"])
      # Keep observed quota until the follow-up read succeeds. Never invent 100%.
      case Store.update(tenant, value, record["version"]) do
        {:ok, saved} -> {:ok, saved}
        _ -> {:error, :reset_pending}
      end
    end
  end

  def models(tenant, provider) when provider in ["codex", "claude"] do
    with :ok <- connection(tenant),
         {:ok, record} <- Store.discovery_account(tenant, provider),
         {:ok, _record, credentials} <- prepare(tenant, record) do
      adapter(tenant, "/models", %{"provider" => provider, "credentials" => credentials})
    end
  end

  def begin_oauth(tenant, attrs) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("subscription_oauth_begin", [], fn ->
        with :ok <- oauth_target(tenant, attrs),
             {:ok, attempt} <-
               start_authorization(tenant, attrs, %{
                 "provider" => attrs["provider"],
                 "state" => Store.id()
               }) do
          id = Store.id()
          expires = DateTime.add(DateTime.utc_now(), 900)

          with {:ok, ciphertext} <-
                 Store.seal(
                   tenant,
                   id,
                   attempt
                   |> Map.merge(Map.take(attrs, ["account_id", "version"]))
                   |> Map.put(
                     "next_poll_at",
                     System.system_time(:second) + (attempt["interval"] || 5)
                   )
                 ),
               {:ok, _} <-
                 Store.query(
                   "INSERT INTO subscription_oauth_attempts (tenant_id,id,ciphertext,expires_at) VALUES ($1,$2,$3,$4)",
                   [tenant, id, ciphertext, expires]
                 ) do
            {:ok,
             Map.merge(Map.take(attempt, ~w(mode user_code interval)), %{
               "id" => id,
               "url" => attempt["url"],
               "expires_at" => DateTime.to_iso8601(expires)
             })}
          end
        end
      end)
    end)
  end

  defp start_authorization(tenant, %{"provider" => "codex", "mode" => "device"}, _body),
    do: adapter(tenant, "/oauth/device/begin", %{})

  defp start_authorization(_tenant, %{"mode" => mode}, _body) when mode not in ["callback", nil],
    do: {:error, :invalid_input}

  defp start_authorization(tenant, _attrs, body), do: adapter(tenant, "/oauth/begin", body)

  defp oauth_target(tenant, %{"account_id" => id} = attrs) do
    with {:ok, a} <- Store.get(tenant, id),
         true <-
           subscription?(a) and a["version"] == attrs["version"] and
             a["provider"] == attrs["provider"] do
      :ok
    else
      false -> {:error, :conflict}
      other -> other
    end
  end

  defp oauth_target(_, _), do: :ok

  # One indexed attempt per poll, at most once per provider interval for 15 minutes.
  # Claim the attempt before external I/O. Concurrent requests cannot exchange it twice.
  def complete_oauth(tenant, id, %{"code" => ""}) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("subscription_oauth_complete", [], fn -> poll_device_authorization(tenant, id) end)
    end)
  end

  def complete_oauth(tenant, id, %{"code" => input}) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("subscription_oauth_complete", [], fn ->
        with {:ok, %{rows: [[ciphertext, expires]]}} <-
               Store.query(
                 "SELECT ciphertext,expires_at FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2",
                 [tenant, id]
               ),
             true <- DateTime.compare(as_datetime(expires), DateTime.utc_now()) == :gt,
             {:ok, attempt} <- Store.open(tenant, id, ciphertext),
             true <- attempt["mode"] != "device",
             {:ok, code} <- authorization_code(input, attempt["state"]),
             {:ok, %{num_rows: 1}} <-
               Store.query(
                 "DELETE FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2",
                 [
                   tenant,
                   id
                 ]
               ),
             {:ok, data} <-
               adapter(tenant, "/oauth/exchange", %{"attempt" => attempt, "code" => code}) do
          save_authorization(tenant, attempt, data)
        else
          false -> {:error, :authorization_expired}
          {:ok, _} -> {:error, :authorization_unavailable}
          other -> other
        end
      end)
    end)
  end

  defp poll_device_authorization(tenant, id) do
    with :ok <- connection(tenant),
         {:ok, %{rows: [[ciphertext, expires]]}} <-
           Store.query(
             "SELECT ciphertext,expires_at FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2",
             [tenant, id]
           ),
         true <- DateTime.compare(as_datetime(expires), DateTime.utc_now()) == :gt,
         {:ok, %{"mode" => "device"} = attempt} <- Store.open(tenant, id, ciphertext),
         {:ok, %{num_rows: 1}} <-
           Store.query(
             "DELETE FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2 AND ciphertext=$3",
             [tenant, id, ciphertext]
           ) do
      result =
        if System.system_time(:second) < attempt["next_poll_at"],
          do: {:ok, %{"status" => "pending"}},
          else:
            adapter(tenant, "/oauth/device/poll", Map.take(attempt, ~w(device_auth_id user_code)))

      case result do
        {:ok, %{"status" => "pending"}} ->
          interval = attempt["interval"]

          attempt =
            Map.put(
              attempt,
              "next_poll_at",
              if(System.system_time(:second) < attempt["next_poll_at"],
                do: attempt["next_poll_at"],
                else: System.system_time(:second) + interval
              )
            )

          with {:ok, sealed} <- Store.seal(tenant, id, attempt),
               {:ok, _} <-
                 Store.query(
                   "INSERT INTO subscription_oauth_attempts (tenant_id,id,ciphertext,expires_at) VALUES ($1,$2,$3,$4)",
                   [tenant, id, sealed, expires]
                 ) do
            {:ok, %{"status" => "pending", "interval" => interval}}
          end

        {:ok, data} ->
          save_authorization(tenant, attempt, data)

        other ->
          other
      end
    else
      false -> {:error, :authorization_expired}
      {:ok, _} -> {:error, :authorization_unavailable}
      other -> other
    end
  end

  defp save_authorization(tenant, attempt, data) do
    if attempt["account_id"] do
      update(tenant, attempt["account_id"], %{
        "version" => attempt["version"],
        "credentials" => data["credentials"]
      })
    else
      create(tenant, %{
        "credential_kind" => "subscription_oauth",
        "provider" => attempt["provider"],
        "credentials" => data["credentials"]
      })
    end
  end

  defp as_datetime(%DateTime{} = time), do: time
  defp as_datetime(time), do: DateTime.from_naive!(time, "Etc/UTC")

  defp authorization_code(input, state) when is_binary(input) do
    input = String.trim(input)

    cond do
      input == "" ->
        {:error, :invalid_input}

      String.contains?(input, "://") ->
        query = URI.parse(input).query || ""
        params = URI.decode_query(query)

        if params["state"] == state and is_binary(params["code"]) and params["code"] != "" and
             !params["error"], do: {:ok, params["code"]}, else: {:error, :invalid_input}

      String.contains?(input, "#") ->
        case String.split(input, "#", parts: 2) do
          [code, ^state] when code != "" -> {:ok, code}
          _ -> {:error, :invalid_input}
        end

      true ->
        {:ok, input}
    end
  end

  defp authorization_code(_, _), do: {:error, :invalid_input}

  def dispatch(opts, call, started? \\ fn -> false end, identity \\ []) do
    if owns_route?(opts) do
      config = Map.new(opts, fn {k, v} -> {to_string(k), v} end)
      tenant = config["account_pool_tenant"]
      provider = if config["protocol"] == "responses", do: "codex", else: "claude"

      Log.context([tenant_id: tenant, provider: provider] ++ Log.sanitize(identity), fn ->
        Log.span("subscription_dispatch", [], fn ->
          case with(
                 :ok <- connection(tenant),
                 do: Store.candidates(tenant, provider, config["model"])
               ) do
            {:ok, candidates} ->
              {ready, cooling} = Enum.split_with(candidates, &(cooldown_ms(&1) == 0))

              Log.emit("subscription_account_selection",
                candidate_count: length(candidates),
                ready_count: length(ready),
                cooling_count: length(cooling)
              )

              {:error, unavailable} =
                SalixAgent.LLM.Error.http(provider, 503, "subscription accounts unavailable")

              unavailable =
                case cooling do
                  [] ->
                    unavailable

                  _ ->
                    Map.put(
                      unavailable,
                      "retry_after_ms",
                      Enum.min(Enum.map(cooling, &cooldown_ms/1))
                    )
                end

              execute_candidates(
                tenant,
                provider,
                config,
                ready,
                call,
                started?,
                {:error, unavailable}
              )

            {:error, :not_configured} ->
              SalixAgent.LLM.Error.http(provider, 400, error_message(:not_configured))

            _ ->
              SalixAgent.LLM.Error.http(provider, 503, "subscription storage unavailable")
          end
        end)
      end)
    else
      call.(opts)
    end
  end

  defp cooldown_ms(%{"cooldown_until" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, until, _} ->
        until
        |> DateTime.diff(DateTime.utc_now(), :microsecond)
        |> Kernel.+(999)
        |> div(1_000)
        |> max(0)
        |> min(30_000)

      _ ->
        0
    end
  end

  defp cooldown_ms(_), do: 0

  defp execute_candidates(_, _, _, [], _, _, last), do: last

  defp execute_candidates(tenant, provider, config, [candidate | rest], call, started?, last) do
    Log.context([account_id: candidate["id"]], fn ->
      Log.emit("subscription_account_selected", candidate_count: length(rest) + 1)

      case prepare(tenant, candidate) do
        {:ok, record, credentials} ->
          credentials = Map.drop(credentials, ["refresh_token", "id_token"])

          credential = %{"provider" => provider, "credentials" => credentials}

          received = :atomics.new(2, [])

          transport = fn url, opts ->
            path = URI.parse(url).path

            SalixAgent.SubscriptionWorker.post(
              path,
              opts,
              credential,
              fn -> :atomics.put(received, 1, 1) end,
              fn -> :atomics.put(received, 2, 1) end
            )
          end

          resolved = Map.put(config, "transport", transport)
          result = Log.span("subscription_account_attempt", [], fn -> call.(resolved) end)

          case result do
            {:error, _} ->
              if :atomics.get(received, 2) == 1 do
                result
              else
                cool_down(tenant, record)

                if :atomics.get(received, 1) == 1 or started?.() do
                  Log.emit("subscription_retry_stopped", candidate_count: length(rest))
                  result
                else
                  Log.emit("subscription_retry_next", candidate_count: length(rest))
                  execute_candidates(tenant, provider, config, rest, call, started?, result)
                end
              end

            _ ->
              result
          end

        {:error, {:worker_rejected, status, code}} ->
          SalixAgent.LLM.Error.http(provider, status, code)

        _ ->
          execute_candidates(tenant, provider, config, rest, call, started?, last)
      end
    end)
  end

  defp cool_down(tenant, record) do
    Log.context(
      [
        tenant_id: tenant,
        account_id: record["id"],
        provider: record["provider"],
        retry_after_ms: 30_000
      ],
      fn ->
        Log.span("subscription_account_cooldown", [], fn ->
          Store.update(
            tenant,
            Map.put(
              record,
              "cooldown_until",
              DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 30))
            ),
            record["version"]
          )
        end)
      end
    )
  end

  def validate_config(config, tenant) do
    case config do
      %{"account_pool" => provider} when provider in ["codex", "claude"] and is_binary(tenant) ->
        :ok

      %{"account_pool" => _} ->
        {:error, {:bad_request, "account pools require a private template and Codex or Claude"}}

      _ ->
        :ok
    end
  end

  def resolve_config(config, tenant) do
    with :ok <- validate_config(config, tenant) do
      case config["account_pool"] do
        provider when provider in ["codex", "claude"] ->
          with :ok <- connection(tenant) do
            # The owning template supplies the tenant. Drop user endpoints and
            # headers: this route must only execute tenant-owned credentials.
            resolved =
              Map.take(
                config,
                ~w(model max_tokens context_tokens reasoning reasoning_effort thinking prompt_caching supports_images)
              )

            {:ok,
             Map.merge(resolved, %{
               "provider" => if(provider == "codex", do: "openai", else: "anthropic"),
               "protocol" => if(provider == "codex", do: "responses", else: "anthropic"),
               "base_url" =>
                 if(provider == "codex",
                   do: "subscription://worker/v1",
                   else: "subscription://worker"
                 ),
               "account_pool_tenant" => tenant
             })}
          end

        _ ->
          {:ok, Map.delete(config, "account_pool_tenant")}
      end
    end
  end

  # Billing trusts only the resolved route bound to the local worker, not
  # a user-supplied billing flag. A mismatched route receives no credit exemption.
  def owns_route?(opts) when is_map(opts) or is_list(opts) do
    opts = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

    SalixStore.Ids.valid_tenant_id?(opts["account_pool_tenant"]) and
      {opts["protocol"], opts["base_url"]} in [
        {"responses", "subscription://worker/v1"},
        {"anthropic", "subscription://worker"}
      ]
  end

  def owns_route?(_), do: false

  def agent_uses_pool?(agent_id, tenant) when is_binary(agent_id) and is_binary(tenant) do
    with {:ok, agent} <- SalixAgent.Control.get(agent_id, tenant),
         {:ok, config} <- SalixAgent.Templates.resolve_llm_for_record(agent) do
      owns_route?(config)
    else
      _ -> false
    end
  end

  def agent_uses_pool?(_, _), do: false

  def error_message(:authorization_expired),
    do:
      "Authorization expired after 15 minutes. Select Continue and use the new link and callback URL."

  def error_message(:authorization_unavailable),
    do:
      "This authorization attempt expired, was already used, or ended when the service restarted. Select Continue and use the new link."

  def error_message(:not_configured),
    do:
      "Subscription Proxy requires a 32-byte storage key. Configure subscription_proxy.storage_key or SALIX_SUBSCRIPTION_STORAGE_KEY."

  def error_message(:reset_in_progress),
    do:
      "Another reset is pending. Close this dialog and refresh subscriptions to resume that request."

  def error_message(:reset_pending),
    do:
      "The reset result is not confirmed. Retry the same reset to check its result without using another reset credit."

  def error_message(:conflict), do: "This account changed. Refresh the list and try again."

  def error_message(:account_in_use),
    do: "A workload still uses this account. Open account usage and unbind every workload first."

  def error_message(:not_found),
    do: "The account or authorization attempt is no longer available."

  def error_message(:invalid_input),
    do:
      "Invalid credentials or authorization code. Check the input and start authorization again if needed."

  def error_message(:unauthorized),
    do: "The subscription operation was not authorized."

  def error_message(_),
    do:
      "The subscription adapter could not complete the operation. Refresh before retrying a change."
end
