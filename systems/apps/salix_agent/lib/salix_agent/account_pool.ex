defmodule SalixAgent.AccountPool do
  @moduledoc "Salix-owned subscription accounts and SDK dispatch."
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixAgent.SubscriptionLog, as: Log

  # One entry per subscription product. `flows` lists sign-in modes, default
  # first. The route names the client wire protocol and a reserved
  # `subscription://` base URL whose host identifies the provider; the worker
  # receives only the path, and the selected credential chooses its executor.
  @providers %{
    "codex" => %{
      flows: ["callback", "device"],
      llm_provider: "openai",
      protocol: "responses",
      base_url: "subscription://worker/v1"
    },
    "claude" => %{
      flows: ["callback"],
      llm_provider: "anthropic",
      protocol: "anthropic",
      base_url: "subscription://worker"
    },
    "gemini" => %{
      flows: ["callback"],
      llm_provider: "openai",
      protocol: "chat_completions",
      base_url: "subscription://gemini/v1"
    },
    "grok" => %{
      flows: ["device"],
      llm_provider: "openai",
      protocol: "responses",
      base_url: "subscription://grok/v1",
      # The worker has no Grok compaction (see account-proxy/providers.go).
      native_compaction: false
    },
    "kimi-code" => %{
      flows: ["device"],
      llm_provider: "anthropic",
      protocol: "anthropic",
      base_url: "subscription://kimi-code"
    },
    "github-copilot" => %{
      flows: ["device"],
      llm_provider: "openai",
      protocol: "chat_completions",
      base_url: "subscription://github-copilot/v1"
    }
  }

  @doc "Subscription provider IDs that support sign-in and pooled inference."
  def providers, do: Map.keys(@providers)

  def provider?(provider), do: is_map_key(@providers, provider)

  @doc """
  The per-provider dispatch seam: provider ID to `{protocol, base_url}` route.
  `resolve_config/2` merges this route with the model request ID, and
  `dispatch/4` maps the route back to the provider whose accounts it selects.
  """
  def route(provider) do
    case @providers[provider] do
      %{protocol: protocol, base_url: base_url, llm_provider: llm_provider} ->
        {:ok, %{"provider" => llm_provider, "protocol" => protocol, "base_url" => base_url}}

      nil ->
        {:error, :invalid_input}
    end
  end

  defp route_provider(config) do
    Enum.find_value(@providers, fn {provider, route} ->
      if {config["protocol"], config["base_url"]} == {route.protocol, route.base_url},
        do: provider
    end)
  end

  # Antigravity refreshes on its own within five minutes of expiry, but
  # inference credentials carry no refresh token. Prepare earlier for Gemini.
  defp refresh_lead("gemini"), do: 360
  defp refresh_lead(_), do: 30

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

  def list(tenant, after_id \\ "", view \\ :all) do
    with :ok <- connection(tenant), do: Store.list(tenant, after_id, view)
  end

  def create(tenant, %{"credential_kind" => "subscription_oauth"} = attrs) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("subscription_account_create", [], fn ->
        with true <- provider?(attrs["provider"]),
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

  # A Profile: an API key for a catalog source. The source decides the endpoint,
  # protocols and auth scheme; a user endpoint is accepted where the source has
  # none (Azure, Cloudflare, Custom).
  def create(tenant, %{"credential_kind" => "provider_api_key", "source" => _} = attrs) do
    Log.context([tenant_id: tenant], fn ->
      Log.span("provider_account_create", [], fn ->
        with :ok <- connection(tenant),
             {:ok, value, credentials} <- source_value(attrs),
             id = Store.id(),
             {:ok, ciphertext} <- Store.seal(tenant, id, credentials),
             {:ok, record} <-
               Store.create(
                 tenant,
                 Map.merge(value, %{
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

  defp update_record(
         tenant,
         %{"credential_kind" => "subscription_oauth"} = record,
         %{
           "name" => _,
           "version" => expected
         } = attrs
       )
       when map_size(attrs) == 2 do
    with {:ok, name} <- provider_name(attrs["name"]) do
      Store.update_locked(tenant, record["id"], expected, fn current ->
        Store.update(tenant, Map.put(current, "name", name), expected)
      end)
    end
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

      Map.keys(attrs) |> Enum.sort() == ["api_key", "version"] and is_binary(record["source"]) ->
        with {:ok, key} <- source_key(record["source"], attrs["api_key"]) do
          Store.update_locked(
            tenant,
            record["id"],
            expected,
            fn current ->
              with {:ok, ciphertext} <- Store.seal(tenant, record["id"], key_credentials(key)) do
                Store.update(
                  tenant,
                  current
                  |> Map.put("credentials", ciphertext)
                  |> put_key_hint(key),
                  expected
                )
              end
            end,
            true
          )
        end

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

  @source_fields ~w(credential_kind source name api_key base_url protocol models)
  @wire %{
    "anthropic" => "anthropic_messages",
    "chat_completions" => "openai_completions",
    "responses" => "openai_responses"
  }

  defp source_value(attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in @source_fields)),
         {:ok, %{"kind" => "api_key"} = source} <- SalixAgent.Models.source(attrs["source"]),
         {:ok, key} <- source_key(attrs["source"], attrs["api_key"]),
         {:ok, name} <- provider_name(attrs["name"] || source["name"] <> " API Key"),
         {:ok, endpoints} <- source_endpoints(source, attrs) do
      protocol = Enum.find(source["protocols"], &Map.has_key?(endpoints, &1))
      # Anthropic and an Anthropic-native Custom endpoint take `x-api-key`.
      auth = if attrs["source"] in ["anthropic", "custom"], do: "api_key", else: "bearer"

      with {:ok, connection} <-
             provider_connection(%{
               "endpoint" => endpoints[protocol],
               "protocol" => @wire[protocol],
               "auth_scheme" => if(protocol == "anthropic", do: auth, else: "bearer")
             }) do
        {:ok,
         %{
           "source" => attrs["source"],
           "name" => name,
           "endpoints" => endpoints,
           "connection" => connection
         }
         |> put_key_hint(key)
         |> Map.merge(custom_models(attrs)), key_credentials(key)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  # The source's own endpoints, or the user's one where the source has none.
  # A user endpoint serves one protocol: the source's only one, or the chosen one.
  defp source_endpoints(source, attrs) do
    case {source["endpoint_required"] == true, attrs["base_url"], attrs["protocol"]} do
      {false, nil, nil} ->
        {:ok, source["endpoints"]}

      {true, url, protocol} when is_binary(url) ->
        protocol = protocol || if(length(source["protocols"]) == 1, do: hd(source["protocols"]))

        if protocol in source["protocols"] and SalixAgent.ModelDiscovery.endpoint?(url),
          do: {:ok, %{protocol => SalixAgent.ModelDiscovery.normalize_url(url, protocol)}},
          else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  # A Custom endpoint lists the model ids it serves (from model discovery).
  # One bad id drops only that id, not the endpoint's other models.
  defp custom_models(%{"source" => "custom", "models" => models})
       when is_list(models) and length(models) <= 500 do
    %{
      "models" =>
        models
        |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 200))
        |> Enum.uniq()
    }
  end

  defp custom_models(_), do: %{}

  # A Custom endpoint (Ollama, a self-hosted gateway) may need no key: then it
  # has no key at all, and dispatch sends no auth header. Every catalog source
  # needs one.
  defp source_key("custom", key) when key in [nil, ""], do: {:ok, nil}
  defp source_key(_source, key), do: provider_key(%{"api_key" => key})

  defp key_credentials(nil), do: %{}
  defp key_credentials(key), do: %{"api_key" => key}

  # A keyless Profile has no hint; the public `key_hint` is then null.
  defp put_key_hint(record, nil), do: Map.delete(record, "key_hint")
  defp put_key_hint(record, key), do: Map.put(record, "key_hint", key_hint(key))

  # Enough to tell keys apart in a list; never enough to use one. Only a long
  # key shows its last four characters; a shorter key shows none, so four
  # characters are never a large part of it.
  defp key_hint(key) do
    key = String.trim(key)
    if String.length(key) >= 20, do: "…" <> String.slice(key, -4, 4), else: "…"
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
         not expiring?(record["expires_at"], refresh_lead(record["provider"])) do
      with {:ok, credentials} <- Store.open(tenant, record["id"], record["credentials"]),
           do: {:ok, record, credentials}
    else
      if subscription?(record), do: refresh(tenant, record), else: {:error, :invalid_input}
    end
  end

  defp expiring?(nil, _lead), do: false

  defp expiring?(value, lead) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.diff(time, DateTime.utc_now()) < lead
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

  defp start_authorization(tenant, %{"provider" => provider} = attrs, body) do
    flows = @providers[provider][:flows] || []

    mode = attrs["mode"] || List.first(flows)

    cond do
      mode not in flows -> {:error, :invalid_input}
      mode == "device" -> adapter(tenant, "/oauth/device/begin", %{"provider" => provider})
      true -> adapter(tenant, "/oauth/begin", body)
    end
  end

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
            adapter(
              tenant,
              "/oauth/device/poll",
              Map.take(attempt, ~w(provider device_auth_id user_code context))
            )

      case result do
        {:ok, %{"status" => "pending"} = pending} ->
          # RFC 8628 slow_down: add five seconds to every later poll.
          interval =
            if pending["slow_down"] == true,
              do: min(attempt["interval"] + 5, 900),
              else: attempt["interval"]

          attempt = Map.put(attempt, "interval", interval)

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
    if catalog_route?(opts),
      do: dispatch_catalog(opts, call, started?, identity),
      else: dispatch_pool(opts, call, started?, identity)
  end

  # Subscription plans whose accounts the worker executes, by catalog source.
  # Every provider is one: its pool route fixes the wire protocol, and the
  # catalog supplies only the request id (`route["model"]`).
  # Codex and Claude first, as before the other plans existed.
  @pool_sources ["codex", "claude", "gemini", "grok", "kimi-code", "github-copilot"]
  if Enum.sort(@pool_sources) != Enum.sort(Map.keys(@providers)),
    do: raise("@pool_sources must list every subscription provider")

  # A catalog route names a model, not a credential. Each Profile that serves
  # the model is a candidate: subscriptions first, then, when the Agent allows
  # pay-per-use, API keys. A candidate that fails before any output reaches
  # the caller hands the request to the next one, whatever its provider.
  defp dispatch_catalog(opts, call, started?, identity) do
    config = Map.new(opts, fn {k, v} -> {to_string(k), v} end)
    tenant = config["catalog_tenant"]
    model = config["catalog_model"]

    base =
      Map.drop(config, ~w(catalog_tenant catalog_model allow_paid profile_id protocol base_url))

    Log.context([tenant_id: tenant] ++ Log.sanitize(identity), fn ->
      Log.span("catalog_dispatch", [], fn ->
        with :ok <- connection(tenant),
             {:ok, attempts} <- catalog_attempts(tenant, base, model, config) do
          Log.emit("catalog_candidates", candidate_count: length(attempts))
          # Output started, or a pool worker already received response bytes:
          # either way no other Profile may take the request over.
          received = :atomics.new(1, [])
          on_received = fn -> :atomics.put(received, 1, 1) end
          started? = fn -> started?.() or :atomics.get(received, 1) == 1 end
          run_attempts(attempts, {call, on_received}, started?, identity, unavailable(model))
        else
          {:error, :not_configured} ->
            SalixAgent.LLM.Error.http("catalog", 400, error_message(:not_configured))

          _ ->
            SalixAgent.LLM.Error.http("catalog", 503, "profile storage unavailable")
        end
      end)
    end)
  end

  # The Agent kept to one Profile: only it serves, a key included (choosing a
  # key is choosing to pay for it). Otherwise every Profile that serves the
  # model, subscriptions first, keys when pay-per-use is allowed.
  defp catalog_attempts(tenant, base, model, %{"profile_id" => id}) when is_binary(id) do
    case Store.get(tenant, id) do
      {:ok, %{"credential_kind" => "subscription_oauth", "provider" => provider}}
      when provider in @pool_sources ->
        {:ok,
         for {:ok, route} <- [plan_route(model, provider)] do
           {:subscription,
            fn ->
              base |> pool_opts(tenant, provider, route["model"]) |> Map.put("account_pin", id)
            end}
         end}

      {:ok, %{"credential_kind" => "provider_api_key", "disabled" => false} = record} ->
        {:ok, key_attempts(tenant, base, model, [record])}

      {:ok, _} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      other ->
        other
    end
  end

  defp catalog_attempts(tenant, base, model, config) do
    with {:ok, keys} <-
           if(config["allow_paid"] == true, do: Store.usable_api_keys(tenant), else: {:ok, []}) do
      {:ok, subscription_attempts(tenant, base, model) ++ key_attempts(tenant, base, model, keys)}
    end
  end

  @doc "Whether a tenant's Profile can serve a catalog model at all."
  def profile_serves?(tenant, id, model) when is_binary(id) do
    case Store.get(tenant, id) do
      {:ok, %{"credential_kind" => "subscription_oauth", "provider" => provider}}
      when provider in @pool_sources ->
        match?({:ok, _}, plan_route(model, provider))

      {:ok, %{"credential_kind" => "provider_api_key"} = record} ->
        match?({:ok, _, _}, key_route(record, model))

      _ ->
        false
    end
  end

  def profile_serves?(_, _, _), do: false

  @doc "Whether a tenant's Profile is an API key (pay-per-use)."
  def key_profile?(tenant, id) when is_binary(id),
    do: match?({:ok, %{"credential_kind" => "provider_api_key"}}, Store.get(tenant, id))

  def key_profile?(_, _), do: false

  # A plan serves a catalog route unless the route needs the Responses API
  # and the plan's pool does not send it upstream: Copilot sends Chat
  # Completions for every model, which also carries its Claude models.
  defp plan_route(model, provider) do
    with {:ok, route} <- SalixAgent.Models.route(model, provider),
         true <- route["protocol"] != "responses" or @providers[provider].protocol == "responses" do
      {:ok, route}
    else
      _ -> :error
    end
  end

  defp unavailable(model),
    do: SalixAgent.LLM.Error.http("catalog", 503, "no enabled profile serves #{model}")

  # Only plans with a usable account: an empty pool is not an attempt, so its
  # "unavailable" never hides the answer of a Profile that could have served.
  defp subscription_attempts(tenant, base, model) do
    for source <- @pool_sources,
        {:ok, route} <- [plan_route(model, source)],
        {:ok, [_ | _]} <- [Store.candidates(tenant, source, route["model"])] do
      {:subscription, fn -> pool_opts(base, tenant, source, route["model"]) end}
    end
  end

  # Endpoint, credential and header fields a Profile's route replaces. The
  # rest of `base` is per-request runtime settings (streaming callbacks,
  # prompt_cache_key, transport_retry, response_format) and passes through.
  @route_fields ~w(api_key api_key_env auth_token auth_token_env default_headers
    provider protocol base_url transport account_pool account_pool_tenant account_pin)

  # A plan's pool route on top of the request's own settings.
  defp pool_opts(base, tenant, provider, model) do
    {:ok, route} = resolve_config(%{"account_pool" => provider, "model" => model}, tenant)
    base |> Map.drop(@route_fields) |> Map.merge(route)
  end

  defp key_attempts(tenant, base, model, keys) do
    for record <- keys, {:ok, request, protocol} <- [key_route(record, model)] do
      {:api_key,
       fn ->
         case Store.open(tenant, record["id"], record["credentials"]) do
           {:ok, credentials} when is_map(credentials) ->
             key_opts(base, record, request, protocol, credentials["api_key"])

           _ ->
             nil
         end
       end}
    end
  end

  # The Profile's own credential only: the template's key never reaches a
  # Profile's endpoint. Only a Custom endpoint may have none.
  defp key_opts(base, record, request, protocol, key) do
    base = Map.drop(base, @route_fields)

    auth =
      cond do
        is_binary(key) and key != "" and protocol == "anthropic" and
            record["connection"]["auth_scheme"] == "bearer" ->
          %{"auth_token" => key}

        is_binary(key) and key != "" ->
          %{"api_key" => key}

        record["source"] == "custom" ->
          %{}

        true ->
          nil
      end

    if auth do
      base
      |> Map.merge(auth)
      |> Map.merge(%{
        "provider" => record["source"],
        "protocol" => protocol,
        "base_url" => record["endpoints"][protocol],
        "model" => request,
        "credential_scope" => "tenant"
      })
    end
  end

  # The catalog names the request id a source uses. A Custom endpoint is not in
  # the catalog: it serves the model ids it listed when it was connected.
  defp key_route(%{"source" => "custom", "endpoints" => endpoints} = record, model)
       when map_size(endpoints) == 1 do
    if model in List.wrap(record["models"]),
      do: {:ok, model, hd(Map.keys(endpoints))},
      else: :error
  end

  defp key_route(%{"source" => source, "endpoints" => endpoints}, model)
       when is_binary(source) and is_map(endpoints) do
    case SalixAgent.Models.route(model, source) do
      {:ok, %{"model" => request, "protocol" => protocol}} when is_map_key(endpoints, protocol) ->
        {:ok, request, protocol}

      _ ->
        :error
    end
  end

  defp key_route(_, _), do: :error

  defp run_attempts([], _call, _started?, _identity, last), do: last

  defp run_attempts(
         [{kind, prepare} | rest],
         {call, on_received} = calls,
         started?,
         identity,
         last
       ) do
    case prepare.() do
      nil ->
        run_attempts(rest, calls, started?, identity, last)

      opts ->
        result =
          case kind do
            :subscription -> dispatch_pool(opts, call, started?, identity, on_received)
            :api_key -> call.(opts)
          end

        case result do
          {:error, meta} = error ->
            # Keep the first answer that another Profile could not change.
            if not started?.() and fail_over?(meta),
              do: run_attempts(rest, calls, started?, identity, first_error(last, error)),
              else: error

          ok ->
            ok
        end
    end
  end

  # Another Profile helps only when this one could not take the request: its
  # credential, quota or route was refused, or the provider was down. A timeout
  # may have done the work already, and a request error would recur anywhere.
  defp fail_over?(%{} = meta) do
    status = meta["status"] || meta[:status]
    status in [401, 402, 403, 404, 429] or status in [500, 502, 503, 529]
  end

  defp fail_over?(_), do: false

  defp first_error({:error, %{"body" => "no enabled profile serves " <> _}}, error), do: error
  defp first_error(last, _error), do: last

  def catalog_route?(opts) when is_map(opts) or is_list(opts) do
    opts = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

    SalixStore.Ids.valid_tenant_id?(opts["catalog_tenant"]) and is_binary(opts["catalog_model"]) and
      opts["base_url"] == "catalog://"
  end

  def catalog_route?(_), do: false

  # A pinned account is the only candidate, whatever its rank in the pool. It
  # still passes the pool's filter: its plan, enabled and active, and quota
  # left for this model. Otherwise the request is cleanly unavailable.
  defp pool_candidates(tenant, provider, %{"account_pin" => id} = config) when is_binary(id),
    do: Store.candidates(tenant, provider, config["model"], id)

  defp pool_candidates(tenant, provider, config),
    do: Store.candidates(tenant, provider, config["model"])

  # `on_received` runs when a worker passes on the first response bytes.
  # At most this many accounts serve one request, refills included.
  @account_attempts 10

  defp dispatch_pool(opts, call, started?, identity, on_received \\ fn -> :ok end) do
    if owns_route?(opts) do
      config = Map.new(opts, fn {k, v} -> {to_string(k), v} end)
      tenant = config["account_pool_tenant"]
      provider = route_provider(config)

      Log.context([tenant_id: tenant, provider: provider] ++ Log.sanitize(identity), fn ->
        Log.span("subscription_dispatch", [], fn ->
          case with(
                 :ok <- connection(tenant),
                 do: pool_candidates(tenant, provider, config)
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

              # An account that rejects a model keeps its rank, so a request
              # that ran out of fetched candidates asks for the next ones.
              refill = fn tried ->
                if is_binary(config["account_pin"]) do
                  []
                else
                  case Store.candidates(tenant, provider, config["model"], nil, tried) do
                    {:ok, more} -> Enum.filter(more, &(cooldown_ms(&1) == 0))
                    _ -> []
                  end
                end
              end

              execute_candidates(
                tenant,
                provider,
                config,
                ready,
                {call, on_received},
                started?,
                {:error, unavailable},
                %{tried: [], refill: refill, budget: @account_attempts}
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

  # Out of fetched candidates after a model-level rejection (403, 404): fetch
  # the next accounts this request has not tried, since such an account keeps
  # its rank. Account-level failures keep the bound of one fetch.
  defp execute_candidates(tenant, provider, config, [], calls, started?, last, attempts) do
    model_rejected =
      match?({:error, meta} when is_map(meta), last) and error_status(elem(last, 1)) in [403, 404]

    case model_rejected and attempts.budget > 0 and attempts.refill.(attempts.tried) do
      [_ | _] = more ->
        execute_candidates(tenant, provider, config, more, calls, started?, last, attempts)

      _ ->
        last
    end
  end

  defp execute_candidates(_, _, _, _, _, _, last, %{budget: 0}), do: last

  defp execute_candidates(
         tenant,
         provider,
         config,
         [candidate | rest],
         {call, on_received} = calls,
         started?,
         last,
         attempts
       ) do
    attempts = %{
      attempts
      | tried: [candidate["id"] | attempts.tried],
        budget: attempts.budget - 1
    }

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
              fn ->
                :atomics.put(received, 1, 1)
                on_received.()
              end,
              fn -> :atomics.put(received, 2, 1) end
            )
          end

          resolved = Map.put(config, "transport", transport)
          result = Log.span("subscription_account_attempt", [], fn -> call.(resolved) end)

          case result do
            {:error, meta} ->
              status = error_status(meta)

              # Owner decision: a 400, 403 or 404 rejects this model or
              # request, not the account, so other requests keep it. 401,
              # 402, 429, 5xx and transport failures still cool it down.
              # A worker that refused before running says nothing of the account.
              rejected = :atomics.get(received, 2) == 1

              unless rejected or status in [400, 403, 404], do: cool_down(tenant, record)

              # A 403 for every model means the account itself is refused;
              # each one is logged against the account so that shows.
              if status == 403, do: Log.emit("subscription_account_forbidden", http_status: 403)

              cond do
                rejected ->
                  result

                # A request-level 400 fails the same way on every account.
                status == 400 ->
                  result

                :atomics.get(received, 1) == 1 or started?.() ->
                  Log.emit("subscription_retry_stopped", candidate_count: length(rest))
                  result

                true ->
                  Log.emit("subscription_retry_next", candidate_count: length(rest))

                  execute_candidates(
                    tenant,
                    provider,
                    config,
                    rest,
                    calls,
                    started?,
                    result,
                    attempts
                  )
              end

            _ ->
              result
          end

        {:error, {:worker_rejected, status, code}} ->
          SalixAgent.LLM.Error.http(provider, status, code)

        _ ->
          execute_candidates(tenant, provider, config, rest, calls, started?, last, attempts)
      end
    end)
  end

  defp error_status(%{} = meta), do: meta["status"] || meta[:status]
  defp error_status(_), do: nil

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
      %{"catalog_model" => model} when is_binary(tenant) ->
        if is_boolean(config["allow_paid"]) and
             (is_nil(config["profile_id"]) or is_binary(config["profile_id"])) and
             known_model?(tenant, model),
           do: :ok,
           else: {:error, {:bad_request, "catalog models require a known model and allow_paid"}}

      %{"catalog_model" => _} ->
        {:error, {:bad_request, "catalog models require a private template"}}

      %{"account_pool" => provider} when is_binary(tenant) and is_map_key(@providers, provider) ->
        :ok

      %{"account_pool" => _} ->
        {:error,
         {:bad_request, "account pools require a private template and a subscription provider"}}

      _ ->
        :ok
    end
  end

  # A catalog model, or a model id that one of the tenant's Custom endpoints
  # listed (an Ollama `llama3.2:3b` is in no catalog).
  defp known_model?(tenant, model) do
    match?({:ok, _}, SalixAgent.Models.get(model)) or Store.custom_model?(tenant, model)
  end

  @doc "A model a Custom endpoint serves, shaped like a catalog entry."
  def custom_model(tenant, model) do
    if Store.custom_model?(tenant, model),
      do:
        {:ok,
         %{
           "id" => model,
           "name" => model,
           "vendor" => nil,
           "efforts" => [],
           "max_tokens" => 32_000,
           "context_tokens" => 0,
           "images" => false
         }},
      else: {:error, :invalid_model_configuration}
  end

  def resolve_config(%{"catalog_model" => model} = config, tenant) do
    with :ok <- validate_config(config, tenant) do
      # The Profile is chosen per request in dispatch; until then the route only
      # names the model and who may pay for it.
      {:ok,
       config
       |> Map.take(
         ~w(max_tokens context_tokens reasoning reasoning_effort thinking prompt_caching supports_images credential_scope)
       )
       |> Map.merge(%{
         "model" => model,
         "catalog_model" => model,
         "allow_paid" => config["allow_paid"],
         "profile_id" => config["profile_id"],
         "catalog_tenant" => tenant,
         "base_url" => "catalog://"
       })}
    end
  end

  def resolve_config(config, tenant) do
    with :ok <- validate_config(config, tenant) do
      case config["account_pool"] do
        provider when is_map_key(@providers, provider) ->
          with :ok <- connection(tenant),
               {:ok, route} <- route(provider) do
            # The owning template supplies the tenant. Drop user endpoints and
            # headers: this route must only execute tenant-owned credentials.
            resolved =
              Map.take(
                config,
                ~w(model max_tokens context_tokens reasoning reasoning_effort thinking prompt_caching supports_images)
              )

            resolved =
              if @providers[provider][:native_compaction] == false,
                do: Map.put(resolved, "native_compaction", false),
                else: resolved

            {:ok, resolved |> Map.merge(route) |> Map.put("account_pool_tenant", tenant)}
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
      route_provider(opts) != nil
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
