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

  # OpenCode Go signs in with an OpenCode Console account (`SalixAgent.OpenCodeConsole`);
  # the Profile it makes is an `opencode-go` key the Console renews.
  @console_source "opencode-go"

  @doc "Whether `provider` signs in (`begin_oauth/2`): a subscription, or OpenCode Go's Console account."
  def sign_in?(provider), do: provider?(provider) or provider == @console_source

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
    key = SystemsRuntime.get_env(:salix_agent, :subscription_storage_key)

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
         true <- DateTime.diff(expires, SystemsClock.utc_now()) > 30 do
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
      if record["credential"] == "subscription" do
        claude_oauth_access(tenant, record, rejected_revision)
      else
        provider_key_access(tenant, id, "claude")
      end
    end
  end

  def runtime_access(_, _, _, _), do: {:error, :subscription_access_unavailable}

  defp provider_key_access(tenant, id, provider) do
    with :ok <- connection(tenant),
         {:ok, record} <- Store.get(tenant, id),
         true <- record["credential"] == "api_key",
         true <- record["disabled"] == false,
         true <- provider in compatible_runtimes(Store.connection(record)["protocol"]),
         {:ok, %{"api_key" => api_key}} <- Store.open(tenant, id, record["credentials"]),
         true <- is_binary(api_key) and byte_size(api_key) > 0 do
      {:ok,
       %{
         "credential_kind" => "provider_api_key",
         "subscription_account_id" => id,
         "connection" => Store.connection(record),
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
           record["source"] == "claude" and record["status"] == "ok" and
             record["disabled"] == false,
         {:ok, credentials} <- Store.open(tenant, id, record["credentials"]),
         {:ok, record, credentials} <- runtime_prepare(tenant, record, credentials, rejected),
         {:ok, current} <- Store.get(tenant, id),
         true <-
           current["disabled"] == false and current["status"] == "ok" and
             current["credentials"] == record["credentials"],
         token when is_binary(token) and byte_size(token) > 0 <- credentials["access_token"],
         {:ok, expires, _} <- DateTime.from_iso8601(credentials["expired"] || ""),
         true <- DateTime.diff(expires, SystemsClock.utc_now()) > 30 do
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

  def compatible_runtimes("anthropic_messages"), do: ["claude"]
  def compatible_runtimes(_), do: []

  defp usable_codex?(record),
    do:
      subscription?(record) and record["source"] == "codex" and record["status"] == "ok" and
        record["disabled"] == false

  defp subscription?(record), do: record["credential"] == "subscription"

  defp runtime_prepare(tenant, record, credentials, rejected_revision) do
    expires_soon =
      case DateTime.from_iso8601(credentials["expired"] || "") do
        {:ok, expires, _} -> DateTime.diff(expires, SystemsClock.utc_now()) < 300
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
             {:ok, value, credentials} <- source_value(tenant, attrs),
             id = Store.id(),
             {:ok, ciphertext} <- Store.seal(tenant, id, credentials),
             {:ok, record} <-
               Store.create(
                 tenant,
                 Map.merge(value, %{
                   "id" => id,
                   "credential" => "api_key",
                   "status" => "ok",
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
                   "credential" => "api_key",
                   "source" => "custom",
                   "status" => "ok",
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

  # The models a Profile does not offer, by model id. Stored as exclusions,
  # so a model the catalog adds later starts offered.
  defp update_record(
         tenant,
         %{"credential" => kind} = record,
         %{"disabled_models" => models, "version" => expected} = attrs
       )
       when kind in ["subscription", "api_key"] and map_size(attrs) == 2 do
    with {:ok, models} <- disabled_models(models) do
      Store.update_edition(tenant, record["id"], expected, fn current ->
        Store.update(tenant, Map.put(current, "disabled_models", models), current["version"])
      end)
    end
  end

  defp update_record(
         tenant,
         %{"credential" => "subscription"} = record,
         %{
           "name" => _,
           "version" => expected
         } = attrs
       )
       when map_size(attrs) == 2 do
    with {:ok, name} <- provider_name(attrs["name"]) do
      Store.update_edition(tenant, record["id"], expected, fn current ->
        Store.update(tenant, Map.put(current, "name", name), current["version"])
      end)
    end
  end

  defp update_record(tenant, %{"credential" => "subscription"} = record, attrs) do
    expected = attrs["version"]

    # A stale edition fails before the credential normalization call.
    with true <-
           is_binary(expected) and Store.edition(record["version"]) == Store.edition(expected),
         {:ok, replace} <- replacement(tenant, record, attrs["credentials"]) do
      Store.update_edition(tenant, record["id"], expected, fn current ->
        Store.update(
          tenant,
          current |> replace.() |> Map.merge(Map.take(attrs, ["disabled"])),
          current["version"]
        )
      end)
    else
      false -> {:error, :conflict}
      other -> other
    end
  end

  defp update_record(tenant, %{"credential" => "api_key"} = record, attrs) do
    expected = attrs["version"]

    cond do
      Map.keys(attrs) |> Enum.sort() == ["name", "version"] ->
        with {:ok, name} <- provider_name(attrs["name"]) do
          Store.update_edition(tenant, record["id"], expected, fn current ->
            Store.update(tenant, Map.put(current, "name", name), current["version"])
          end)
        end

      Map.keys(attrs) |> Enum.sort() == ["disabled", "version"] and is_boolean(attrs["disabled"]) ->
        Store.update_edition(tenant, record["id"], expected, fn current ->
          Store.update(
            tenant,
            Map.put(current, "disabled", attrs["disabled"]),
            current["version"]
          )
        end)

      Map.keys(attrs) |> Enum.sort() == ["api_key", "version"] and is_binary(record["source"]) ->
        with {:ok, key} <- source_key(record["source"], attrs["api_key"]) do
          Store.update_edition(
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
                  current["version"]
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
          Store.update_edition(
            tenant,
            record["id"],
            expected,
            fn current ->
              with {:ok, ciphertext} <- Store.seal(tenant, record["id"], value.credentials) do
                Store.update(
                  tenant,
                  current
                  |> Map.merge(Map.take(value.public, ~w(endpoint protocol auth)))
                  |> Map.put("credentials", ciphertext),
                  current["version"]
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

  # The change replacing credentials makes to an account, applied to the
  # account as it is when the write takes its lock.
  defp replacement(_tenant, _record, nil), do: {:ok, & &1}

  defp replacement(tenant, record, credentials) do
    with {:ok, data} <-
           adapter(tenant, "/normalize", %{
             "provider" => record["source"],
             "credentials" => credentials
           }),
         {:ok, ciphertext} <- Store.seal(tenant, record["id"], data["credentials"]) do
      {:ok,
       fn current ->
         current
         |> Map.merge(%{
           "credentials" => ciphertext,
           "credential_revision" => Store.id(),
           "email" => data["email"],
           "status" => "ok",
           "prepared" => false
         })
         |> Map.drop(["quota", "reset_attempt"])
       end}
    end
  end

  def delete(tenant, id, version) do
    Log.context([tenant_id: tenant, account_id: id], fn ->
      Log.span("account_delete", [], fn ->
        with {:ok, record} <- Store.get(tenant, id) do
          Store.delete_edition(tenant, id, version, record["credential"] == "api_key")
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

  @source_fields ~w(credential_kind source name api_key base_url protocol models model_info)
  @wire %{
    "anthropic" => "anthropic_messages",
    "chat_completions" => "openai_completions",
    "responses" => "openai_responses"
  }

  defp source_value(tenant, attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in @source_fields)),
         {:ok, %{"kind" => "api_key"} = source} <- SalixAgent.Models.source(attrs["source"]),
         # A platform-only source (an internal gateway) is the platform's alone.
         true <- source["platform_only"] != true or tenant == platform_tenant(),
         {:ok, key} <- source_key(attrs["source"], attrs["api_key"]),
         {:ok, name} <- provider_name(attrs["name"] || source["name"] <> " API Key"),
         {:ok, endpoints} <- source_endpoints(source, attrs) do
      protocol = Enum.find(source["protocols"], &Map.has_key?(endpoints, &1))
      # Anthropic and an Anthropic-native Custom endpoint take `x-api-key`.
      auth = if attrs["source"] in ["anthropic", "custom"], do: "api_key", else: "bearer"

      # An internal gateway (a platform-only source) may sit on the cluster's
      # own network, without TLS; so may any platform Profile, which only the
      # platform's operators and deployment configuration create (a local or
      # self-hosted installation's one model).
      schemes =
        if source["platform_only"] == true or tenant == platform_tenant(),
          do: ["https", "http"],
          else: ["https"]

      with {:ok, connection} <-
             provider_connection(
               %{
                 "endpoint" => endpoints[protocol],
                 "protocol" => @wire[protocol],
                 "auth_scheme" => if(protocol == "anthropic", do: auth, else: "bearer")
               },
               schemes
             ) do
        {:ok,
         %{
           "source" => attrs["source"],
           "name" => name,
           "endpoints" => endpoints
         }
         |> Map.merge(stored_connection(connection))
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
  defp custom_models(%{"source" => "custom", "models" => models} = attrs)
       when is_list(models) and length(models) <= 500 do
    models =
      models
      |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 200))
      |> Enum.uniq()

    info = model_info(attrs["model_info"], models)
    if info == %{}, do: %{"models" => models}, else: %{"models" => models, "model_info" => info}
  end

  defp custom_models(_), do: %{}

  # What a Custom endpoint says of its listed models: context and output
  # limits, image input and reasoning efforts. A field of the wrong kind, or a
  # model it does not list, is dropped, not the endpoint.
  defp model_info(info, models) when is_map(info) do
    for {model, fields} <- info, model in models, is_map(fields), into: %{} do
      {model,
       %{
         "context_tokens" => positive(fields["context_tokens"]),
         "max_tokens" => positive(fields["max_tokens"]),
         "images" => if(is_boolean(fields["images"]), do: fields["images"]),
         "efforts" => efforts(fields["efforts"])
       }
       |> Map.reject(fn {_key, value} -> value in [nil, []] end)}
    end
    |> Map.reject(fn {_model, fields} -> fields == %{} end)
  end

  defp model_info(_info, _models), do: %{}

  defp positive(value) when is_integer(value) and value > 0 and value <= 10_000_000, do: value
  defp positive(_), do: nil

  defp efforts(values) when is_list(values) and length(values) <= 10,
    do: Enum.filter(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 32))

  defp efforts(_), do: []

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
         public: Map.merge(%{"name" => name}, stored_connection(connection)),
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

  @disabled_models_limit 500

  defp disabled_models(models)
       when is_list(models) and length(models) <= @disabled_models_limit do
    if Enum.all?(
         models,
         &(is_binary(&1) and &1 != "" and byte_size(&1) <= 200 and not control?(&1))
       ),
       do: {:ok, Enum.uniq(models)},
       else: {:error, :invalid_input}
  end

  defp disabled_models(_), do: {:error, :invalid_input}

  # Whether a Profile's owner turned this model off for it.
  defp excluded?(record, model), do: model in List.wrap(record["disabled_models"])

  defp provider_connection(connection, schemes \\ ["https"])

  defp provider_connection(connection, schemes)
       when is_map(connection) and map_size(connection) == 3 do
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
         uri.scheme in schemes and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and valid_pair do
      {:ok, Map.take(connection, ~w(endpoint protocol auth_scheme))}
    else
      {:error, :invalid_input}
    end
  end

  defp provider_connection(_, _), do: {:error, :invalid_input}

  # A key's address as the Profile stores it (Store.connection gives it back).
  defp stored_connection(connection) do
    %{
      "endpoint" => connection["endpoint"],
      "protocol" => Store.stored_protocol(connection["protocol"]),
      "auth" => connection["auth_scheme"]
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

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
         not expiring?(record["expires_at"], refresh_lead(record["source"])) do
      with {:ok, credentials} <- Store.open(tenant, record["id"], record["credentials"]),
           do: {:ok, record, credentials}
    else
      if subscription?(record), do: refresh(tenant, record), else: {:error, :invalid_input}
    end
  end

  defp expiring?(nil, _lead), do: false

  defp expiring?(value, lead) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.diff(time, SystemsClock.utc_now()) < lead
      _ -> false
    end
  end

  defp refresh(tenant, record, force \\ false) do
    Log.context([tenant_id: tenant, account_id: record["id"], provider: record["source"]], fn ->
      Log.span("subscription_account_refresh", [], fn ->
        with true <- record["status"] == "ok",
             true <- subscription?(record),
             {:ok, claimed} <-
               Store.update_background(
                 tenant,
                 Map.merge(record, %{
                   "status" => "login",
                   "refresh_deadline" =>
                     SystemsClock.system_time(:second) +
                       if(force, do: 10, else: div(SalixAgent.LLM.request_timeout_ms(), 1000) + 5)
                 }),
                 record["version"]
               ),
             {:ok, credentials} <- Store.open(tenant, record["id"], record["credentials"]),
             {:ok, data} <-
               prepare_admitted(tenant, record, claimed, credentials, force),
             {:ok, ciphertext} <- Store.seal(tenant, record["id"], data["credentials"]),
             {:ok, saved} <-
               Store.apply_background(
                 tenant,
                 record["id"],
                 &still_claimed?(&1, claimed),
                 &Map.merge(&1, %{
                   "status" => "ok",
                   "refresh_deadline" => nil,
                   "credentials" => ciphertext,
                   "credential_revision" => Store.id(),
                   "email" => data["email"],
                   "prepared" => true,
                   "expires_at" => data["credentials"]["expired"]
                 })
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
           "provider" => record["source"],
           "force_refresh" => force,
           "credentials" => credentials
         }) do
      {:error, {:worker_rejected, _, _}} = error ->
        # No executor ran, so the original credential remains usable for a later refresh.
        # The claim is lifted only while it is still this refresh's: a replacement
        # or deletion meanwhile is kept, a user's other change is kept too.
        with {:ok, _} <-
               Store.apply_background(
                 tenant,
                 record["id"],
                 &still_claimed?(&1, claimed),
                 &Map.merge(&1, %{
                   "status" => record["status"],
                   "refresh_deadline" => record["refresh_deadline"]
                 })
               ),
             do: error

      result ->
        result
    end
  end

  # The account still holds this refresh's claim on the same credentials: no
  # replacement, deletion or other refresh came in between.
  defp still_claimed?(current, claimed) do
    current["status"] == "login" and
      current["refresh_deadline"] == claimed["refresh_deadline"] and
      current["credential_revision"] == claimed["credential_revision"]
  end

  # The account still has the credentials a background answer was about.
  defp same_credentials?(current, record),
    do: current["credential_revision"] == record["credential_revision"]

  # A quota answer read for `record` is still the newest: no other quota write
  # and no reset since. A slow poll's answer from before a reset must not
  # replace the quota the reset's own read wrote.
  defp quota_still_current?(current, record) do
    same_credentials?(current, record) and current["quota"] == record["quota"] and
      current["reset_attempt"] == record["reset_attempt"]
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
    with {:ok, %{"body" => answer}} <-
           adapter(
             tenant,
             "/quota",
             %{
               "provider" => record["source"],
               "credentials" => credentials
             },
             opts
           ),
         {:ok, saved} <-
           Store.apply_background(
             tenant,
             record["id"],
             &quota_still_current?(&1, record),
             &Map.put(&1, "quota", SalixAgent.Profiles.quota(record["source"], answer))
           ) do
      {:ok, Store.public(saved)}
    else
      {:ok, _not_an_answer} -> {:error, :quota_unavailable}
      other -> other
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
             true <- record["source"] == "codex",
             true <- record["status"] == "ok",
             :ok <- reset_admission(record, version, key),
             {:ok, record, credentials} <- prepare(tenant, record),
             {:ok, claimed} <- claim_reset(tenant, record, key),
             {:ok, result} <- execute_reset(tenant, claimed, credentials),
             {:ok, saved, outcome} <- settle_reset(tenant, claimed, result) do
          # Do not turn a completed reset into a failed mutation if this read fails.
          case quota(tenant, id) do
            {:ok, account} ->
              {:ok, %{"outcome" => outcome, "account" => account, "quota_refreshed" => true}}

            _ ->
              {:ok,
               %{
                 "outcome" => outcome,
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
        Store.update_background(
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

  # Records the reset's outcome once. A request with the same key that settles
  # second (the page retries a pending key) reads the recorded outcome
  # instead of replacing it.
  defp settle_reset(tenant, record, result) do
    if record["reset_attempt"]["outcome"] == result["code"] do
      {:ok, record, result["code"]}
    else
      key = record["reset_attempt"]["request_id"]
      # Keep observed quota until the follow-up read succeeds. Never invent 100%.
      case Store.apply_background(
             tenant,
             record["id"],
             &(same_credentials?(&1, record) and
                 match?(%{"reset_attempt" => %{"request_id" => ^key, "outcome" => "pending"}}, &1)),
             &put_in(&1, ["reset_attempt", "outcome"], result["code"])
           ) do
        {:ok, saved} ->
          {:ok, saved, result["code"]}

        _ ->
          case Store.get(tenant, record["id"]) do
            {:ok, %{"reset_attempt" => %{"request_id" => ^key, "outcome" => outcome}} = current}
            when outcome != "pending" ->
              {:ok, current, outcome}

            _ ->
              {:error, :reset_pending}
          end
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
          expires = DateTime.add(SystemsClock.utc_now(), 900)

          with {:ok, ciphertext} <-
                 Store.seal(
                   tenant,
                   id,
                   attempt
                   |> Map.merge(Map.take(attrs, ["account_id", "version"]))
                   |> Map.put(
                     "next_poll_at",
                     SystemsClock.system_time(:second) + (attempt["interval"] || 5)
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

  defp start_authorization(_tenant, %{"provider" => @console_source} = attrs, _body) do
    with false <- Map.has_key?(attrs, "account_id"),
         {:ok, device} <- SalixAgent.OpenCodeConsole.start() do
      {:ok,
       %{
         "provider" => @console_source,
         "mode" => "device",
         "device_code" => device.device_code,
         "user_code" => device.user_code,
         "url" => device.url,
         "interval" => device.interval
       }}
    else
      true -> {:error, :invalid_input}
      other -> other
    end
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
           subscription?(a) and is_binary(attrs["version"]) and
             Store.edition(a["version"]) == Store.edition(attrs["version"]) and
             a["source"] == attrs["provider"] do
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
             true <- DateTime.compare(as_datetime(expires), SystemsClock.utc_now()) == :gt,
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
         true <- DateTime.compare(as_datetime(expires), SystemsClock.utc_now()) == :gt,
         {:ok, %{"mode" => "device"} = attempt} <- Store.open(tenant, id, ciphertext),
         {:ok, %{num_rows: 1}} <-
           Store.query(
             "DELETE FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2 AND ciphertext=$3",
             [tenant, id, ciphertext]
           ) do
      result =
        if SystemsClock.system_time(:second) < attempt["next_poll_at"],
          do: {:ok, %{"status" => "pending"}},
          else: poll_device(tenant, attempt)

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
              if(SystemsClock.system_time(:second) < attempt["next_poll_at"],
                do: attempt["next_poll_at"],
                else: SystemsClock.system_time(:second) + interval
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

  defp poll_device(_tenant, %{"provider" => @console_source} = attempt) do
    case SalixAgent.OpenCodeConsole.poll(attempt["device_code"]) do
      {:pending, slow_down} -> {:ok, %{"status" => "pending", "slow_down" => slow_down}}
      {:ok, token} -> {:ok, %{"console" => token}}
      error -> error
    end
  end

  defp poll_device(tenant, attempt),
    do:
      adapter(
        tenant,
        "/oauth/device/poll",
        Map.take(attempt, ~w(provider device_auth_id user_code context))
      )

  defp save_authorization(tenant, _attempt, %{"console" => token}),
    do: save_console(tenant, token)

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
      config
      |> Map.drop(~w(catalog_tenant catalog_model allow_paid profile_id protocol base_url))
      |> put_route_session(identity)

    Log.context([tenant_id: tenant] ++ Log.sanitize(identity), fn ->
      Log.span("catalog_dispatch", [], fn ->
        with :ok <- connection(tenant),
             {:ok, attempts} <- catalog_attempts(tenant, base, model, config) do
          Log.emit("catalog_candidates", candidate_count: length(attempts))

          if attempts == [] do
            not_served(tenant, model, config["profile_id"])
          else
            # Output started, or a pool worker already received response bytes:
            # either way no other Profile may take the request over.
            received = SystemsRuntime.Atomics.new(1, [])
            on_received = fn -> SystemsRuntime.Atomics.put(received, 1, 1) end
            started? = fn -> started?.() or SystemsRuntime.Atomics.get(received, 1) == 1 end
            run_attempts(attempts, {call, on_received}, started?, identity, unavailable(model))
          end
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
      {:ok, %{"credential" => "subscription", "source" => provider} = record}
      when provider in @pool_sources ->
        {:ok,
         for {:ok, route} <- [plan_route(model, provider)],
             not excluded?(record, model),
             {:ok, [_ | _]} <- [Store.candidates(tenant, provider, route["model"], id, [], model)] do
           {{:subscription, model}, funding(provider, nil),
            fn ->
              base |> pool_opts(tenant, provider, route["model"]) |> Map.put("account_pin", id)
            end}
         end}

      {:ok, %{"credential" => "api_key", "disabled" => false} = record} ->
        {:ok, key_attempts(tenant, base, model, [record])}

      {:ok, _} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      other ->
        other
    end
  end

  # Only the Tenant's own Profiles serve a catalog model; the platform pays
  # only for the Comma model, never for a model the member chose.
  defp catalog_attempts(tenant, base, model, config) do
    with {:ok, keys} <-
           if(config["allow_paid"] == true, do: Store.usable_api_keys(tenant), else: {:ok, []}) do
      {:ok, subscription_attempts(tenant, base, model) ++ key_attempts(tenant, base, model, keys)}
    end
  end

  @platform SalixStore.Ids.platform_tenant_id()

  @doc "The reserved tenant that owns platform-funded Profiles."
  def platform_tenant, do: @platform

  @doc "Whether a tenant's Profile can serve a catalog model at all."
  def profile_serves?(tenant, id, model) when is_binary(id) do
    case Store.get(tenant, id) do
      {:ok, %{"credential" => "subscription", "source" => provider} = record}
      when provider in @pool_sources ->
        match?({:ok, _}, plan_route(model, provider)) and not excluded?(record, model)

      {:ok, %{"credential" => "api_key"} = record} ->
        match?({:ok, _, _}, key_route(record, model))

      _ ->
        false
    end
  end

  def profile_serves?(_, _, _), do: false

  @doc """
  Whether the Tenant's own Codex subscription serves a catalog choice: its
  pinned Profile is one, or, unpinned, an enabled, signed-in Codex
  subscription of the Tenant serves the model. Reads at most the bounded
  serving Profile page.
  """
  def codex_serves?(tenant, %{"kind" => "catalog", "model" => model} = choice)
      when is_binary(tenant) do
    case choice["profile_id"] do
      id when is_binary(id) ->
        match?(
          {:ok, %{"credential" => "subscription", "source" => "codex"}},
          Store.get(tenant, id)
        ) and profile_serves?(tenant, id, model)

      _unpinned ->
        with :ok <- connection(tenant),
             {:ok, %{profiles: profiles}} <- Store.serving_profiles(tenant),
             {:ok, _route} <- plan_route(model, "codex") do
          Enum.any?(profiles, fn profile ->
            profile["credential"] == "subscription" and profile["source"] == "codex" and
              not excluded?(profile, model)
          end)
        else
          _ -> false
        end
    end
  end

  def codex_serves?(_tenant, _choice), do: false

  @doc "Whether a tenant's Profile is an API key (pay-per-use)."
  def key_profile?(tenant, id) when is_binary(id),
    do: match?({:ok, %{"credential" => "api_key"}}, Store.get(tenant, id))

  def key_profile?(_, _), do: false

  @doc """
  Models that at least one Profile able to serve Agents now can serve: an
  enabled API key, or an enabled, signed-in subscription. The server form of
  the client's `servingProfiles`/`canServeAgents`. It reads at most 100
  Profiles and returns at most `limit` models, those a subscription serves
  first. Custom endpoints add the model ids they listed. `filter` (a function
  of the model list) narrows the models before `limit` applies.
  """
  def servable_models(tenant, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    filter = Keyword.get(opts, :filter, &Function.identity/1)
    query = opts |> Keyword.get(:query) |> to_string() |> String.trim() |> String.downcase()

    with :ok <- connection(tenant),
         {:ok, %{profiles: profiles, truncated: profiles_truncated}} <-
           Store.serving_profiles(tenant) do
      {plans, keys} =
        Enum.split_with(profiles, &(&1["credential"] == "subscription"))

      plans = Enum.filter(plans, &(&1["source"] in @pool_sources))

      catalog =
        for model <- SalixAgent.Models.list(),
            {_, _, _} = served <- [served_by(model["id"], plans, keys)],
            do: servable_entry(model, served)

      catalog_ids = MapSet.new(catalog, & &1["id"])

      custom =
        for %{"source" => "custom"} = key <- keys,
            id <- List.wrap(key["models"]),
            is_binary(id),
            not MapSet.member?(catalog_ids, id),
            not excluded?(key, id),
            do: custom_entry(id, get_in(key, ["model_info", id]) || %{})

      matching =
        (catalog ++ Enum.uniq_by(custom, & &1["id"]))
        |> Enum.filter(&servable_match?(&1, query))
        |> filter.()
        |> Enum.sort_by(&if(&1["served_by"] == "subscription", do: 0, else: 1))

      {:ok,
       %{
         "models" => Enum.take(matching, limit),
         "truncated" => profiles_truncated or length(matching) > limit
       }}
    else
      # Without Profile storage no Profile exists.
      {:error, :not_configured} -> {:ok, %{"models" => [], "truncated" => false}}
      error -> error
    end
  end

  @doc """
  The models one Profile serves: the catalog models its plan or key serves,
  less those it disabled, and a Custom endpoint's own models. What a station
  that borrows it may run.
  """
  @spec profile_models(map()) :: [String.t()]
  def profile_models(record) when is_map(record) do
    # A key stored before endpoints by protocol names its one endpoint.
    record =
      case record do
        %{"endpoints" => %{}} ->
          record

        %{"protocol" => p, "endpoint" => e} when is_binary(p) ->
          Map.put(record, "endpoints", %{p => e})

        _ ->
          record
      end

    {plans, keys} =
      if record["credential"] == "subscription",
        do: {Enum.filter([record], &(&1["source"] in @pool_sources)), []},
        else: {[], [record]}

    catalog =
      for model <- SalixAgent.Models.list(),
          served_by(model["id"], plans, keys) != nil,
          do: model["id"]

    custom =
      for id <- List.wrap(record["models"]), is_binary(id), not excluded?(record, id), do: id

    Enum.uniq(catalog ++ custom)
  end

  # A plan serves the model when one of its signed-in accounts still offers it.
  # The key sources that route it are reported as well, so a model a plan
  # serves can also say that pay-per-use keys serve it.
  defp served_by(model, plans, keys) do
    subscriptions =
      plans
      |> Enum.reject(&excluded?(&1, model))
      |> Enum.map(& &1["source"])
      |> Enum.uniq()
      |> Enum.filter(&match?({:ok, _}, plan_route(model, &1)))

    key_sources =
      keys
      |> Enum.filter(&match?({:ok, _, _}, key_route(&1, model)))
      |> Enum.map(& &1["source"])
      |> Enum.uniq()

    cond do
      subscriptions != [] -> {"subscription", subscriptions, key_sources}
      key_sources != [] -> {"api_key", [], key_sources}
      true -> nil
    end
  end

  defp servable_entry(model, {served_by, plans, key_sources}) do
    model
    |> Map.take(~w(id name family vendor efforts))
    |> Map.merge(%{
      "served_by" => served_by,
      "subscription_plans" => plans,
      "api_key_sources" => Enum.map(key_sources, &key_source/1),
      "requires_allow_paid" => served_by != "subscription"
    })
  end

  defp custom_entry(id, info) do
    %{
      "id" => id,
      "name" => id,
      "family" => nil,
      "vendor" => nil,
      "efforts" => info["efforts"] || [],
      "served_by" => "api_key",
      "subscription_plans" => [],
      "api_key_sources" => [key_source("custom")],
      "requires_allow_paid" => true
    }
  end

  # A key source with its display name (`SalixAgent.Models.sources/0`).
  defp key_source(id) do
    name =
      case SalixAgent.Models.source(id) do
        {:ok, %{"name" => name}} when is_binary(name) -> name
        _ -> id
      end

    %{"id" => id, "name" => name}
  end

  defp servable_match?(_model, ""), do: true

  defp servable_match?(model, query) do
    Enum.any?(
      ~w(id name family vendor),
      &String.contains?(String.downcase(to_string(model[&1])), query)
    )
  end

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

  # No Profile of the Tenant may serve the model at all: the choice needs a
  # Profile, pay-per-use or another model, and a retry fails the same way. It
  # stops the input as `model_unavailable`, which tells the member to change
  # the model choice.
  defp not_served(model) do
    case unavailable(model) do
      {:error, %{} = meta} ->
        {:error,
         Map.merge(meta, %{
           "error_class" => "billing_unavailable",
           "reason" => "model_unavailable",
           "retryable" => false
         })}

      other ->
        other
    end
  end

  # Nothing may take the request. When the member's own subscriptions serve
  # the model but their used-up windows hold them back, the input stops as
  # `quota_exhausted`, naming the one that refills first and when, so the
  # member waits for it or chooses another model. Otherwise no Profile serves
  # the model at all. `pin`: the Profile the Agent kept to, if any.
  defp not_served(tenant, model, pin) do
    held =
      for source <- @pool_sources,
          {:ok, route} <- [plan_route(model, source)],
          {:ok, records} <- [Store.held_back(tenant, source, route["model"], pin, model)],
          record <- records,
          do: {source, record, SalixAgent.Profiles.refills_at(record, route["model"])}

    case held do
      [] -> not_served(model)
      held -> held |> Enum.min_by(fn {_, _, at} -> at || :never end) |> usage_limit(model)
    end
  end

  defp usage_limit({source, record, refills_at}, model) do
    {:error, meta} =
      SalixAgent.LLM.Error.http(
        "catalog",
        503,
        "subscriptions serving #{model} reached their usage limit"
      )

    funding =
      source
      |> funding(record)
      |> Map.put("reset_at", if(is_integer(refills_at), do: div(refills_at, 1000)))
      |> compact_funding()

    {:error,
     Map.merge(meta, %{
       "error_class" => "billing_unavailable",
       "reason" => "quota_exhausted",
       "retryable" => false,
       "funding" => funding
     })}
  end

  # Only plans with a usable account: an empty pool is not an attempt, so its
  # "unavailable" never hides the answer of a Profile that could have served.
  # An account that turned the model off is not in its plan's pool for it.
  defp subscription_attempts(tenant, base, model) do
    for source <- @pool_sources,
        {:ok, route} <- [plan_route(model, source)],
        {:ok, [_ | _]} <- [Store.candidates(tenant, source, route["model"], nil, [], model)] do
      {{:subscription, model}, funding(source, nil),
       fn -> pool_opts(base, tenant, source, route["model"]) end}
    end
  end

  # The Profile a failed attempt would have spent, for the member's own fix:
  # its catalog source and, for a key, the Profile they named. Never a credential.
  defp funding(source, nil), do: %{"source" => source}

  defp funding(source, record),
    do: %{"source" => source, "profile_id" => record["id"], "profile_name" => record["name"]}

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
      {:api_key, funding(record["source"] || "custom", record),
       fn -> open_key(tenant, base, record, request, protocol, "tenant") end}
    end
  end

  defp open_key(tenant, base, record, request, protocol, scope) do
    case Store.open(tenant, record["id"], record["credentials"]) do
      {:ok, credentials} when is_map(credentials) ->
        credentials = renew_console(tenant, record, credentials)
        key_opts(base, record, request, protocol, credentials["api_key"], scope)

      _ ->
        nil
    end
  end

  # ── OpenCode Go signed in with an OpenCode Console account ──────────────

  # The Console's access token lasts 30 days; it is renewed this long before.
  @console_renew_lead 3 * 24 * 3600

  # A signed-in account is its key: one Profile per Console account, which a
  # later sign-in to the same account renews rather than duplicates.
  defp save_console(tenant, token) do
    email = SalixAgent.OpenCodeConsole.email(token.access)
    console = console_credentials(token, email)

    with :ok <- connection(tenant),
         {:ok, existing} <- console_profile(tenant, email) do
      case existing do
        nil ->
          with {:ok, value, credentials} <-
                 source_value(tenant, %{
                   "source" => @console_source,
                   "api_key" => token.access,
                   "name" => console_name(email)
                 }),
               id = Store.id(),
               {:ok, ciphertext} <- Store.seal(tenant, id, Map.merge(credentials, console)),
               {:ok, record} <-
                 Store.create(
                   tenant,
                   value
                   |> Map.merge(%{
                     "id" => id,
                     "credential" => "api_key",
                     "status" => "ok",
                     "credentials" => ciphertext,
                     "disabled" => false
                   })
                   |> put_console_email(email)
                 ) do
            {:ok, Store.public(record)}
          end

        record ->
          with {:ok, ciphertext} <-
                 Store.seal(
                   tenant,
                   record["id"],
                   Map.merge(key_credentials(token.access), console)
                 ),
               {:ok, saved} <-
                 Store.update_edition(tenant, record["id"], record["version"], fn current ->
                   Store.update(
                     tenant,
                     current
                     |> Map.put("credentials", ciphertext)
                     |> Map.delete("refresh_deadline")
                     |> put_key_hint(token.access),
                     current["version"]
                   )
                 end) do
            {:ok, Store.public(saved)}
          end
      end
    end
  end

  defp console_credentials(token, email) do
    %{
      "console" =>
        %{"refresh" => token.refresh, "expires_at" => token.expires_at}
        |> then(&if(email, do: Map.put(&1, "email", email), else: &1))
    }
  end

  defp console_name(nil), do: "OpenCode Go"
  defp console_name(email), do: "OpenCode Go · " <> email

  defp put_console_email(record, nil), do: Map.put(record, "console_email", "")
  defp put_console_email(record, email), do: Map.put(record, "console_email", email)

  # The Profile an earlier sign-in to this Console account made, if any.
  defp console_profile(_tenant, nil), do: {:ok, nil}

  defp console_profile(tenant, email) do
    with {:ok, %{rows: rows}} <-
           Store.query(
             """
             SELECT value,version FROM subscription_accounts
             WHERE tenant_id=$1 AND value->>'source'=$2 AND value->>'console_email'=$3
             ORDER BY id LIMIT 1
             """,
             [tenant, @console_source, email]
           ) do
      case rows do
        [[value, version]] -> {:ok, Map.put(value, "version", version)}
        [] -> {:ok, nil}
      end
    end
  end

  # A signed-in key close to running out is renewed first. The renewal is
  # claimed on the Profile (`refresh_deadline`), so one request renews while
  # the others keep the current key, which still works for days; a refresh
  # token is spent when used. A refused renewal leaves the key as it is: it
  # works until it runs out, and a new sign-in replaces it.
  defp renew_console(
         tenant,
         record,
         %{"console" => %{"refresh" => refresh} = console} = credentials
       )
       when is_binary(refresh) do
    now = SystemsClock.system_time(:second)

    if console["expires_at"] - now > @console_renew_lead or
         (is_integer(record["refresh_deadline"]) and record["refresh_deadline"] > now) do
      credentials
    else
      claim = Map.put(record, "refresh_deadline", now + 30)

      with {:ok, claimed} <- Store.update_background(tenant, claim, record["version"]),
           {:ok, token} <- SalixAgent.OpenCodeConsole.renew(refresh),
           renewed =
             credentials
             |> Map.put("api_key", token.access)
             |> Map.merge(console_credentials(token, console["email"])),
           {:ok, ciphertext} <- Store.seal(tenant, record["id"], renewed),
           {:ok, _saved} <-
             Store.apply_background(
               tenant,
               record["id"],
               &(&1["refresh_deadline"] == claimed["refresh_deadline"]),
               &(&1
                 |> Map.put("credentials", ciphertext)
                 |> Map.delete("refresh_deadline")
                 |> put_key_hint(token.access))
             ) do
        renewed
      else
        {:error, :refused} ->
          # Signed out at the Console, or the token was spent elsewhere: not
          # asked again before the key runs out, nor more than hourly after.
          Log.emit("console_renew_refused")

          Store.apply_background(
            tenant,
            record["id"],
            &(&1["refresh_deadline"] == now + 30),
            &Map.put(&1, "refresh_deadline", max(console["expires_at"], now + 3600))
          )

          credentials

        {:error, reason} ->
          Log.emit("console_renew_failed", reason: inspect(reason))
          credentials
      end
    end
  end

  defp renew_console(_tenant, _record, credentials), do: credentials

  # The Profile's own credential only: the template's key never reaches a
  # Profile's endpoint. Only a Custom endpoint may have none.
  defp key_opts(base, record, request, protocol, key, scope) do
    {session, base} = Map.pop(Map.drop(base, @route_fields), "route_session")

    auth =
      cond do
        is_binary(key) and key != "" and protocol == "anthropic" and
            record["auth"] == "bearer" ->
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
        "credential_scope" => scope
      })
      |> put_source_headers(record, session)
    end
  end

  # OpenCode Go refuses a request without an `x-opencode-session` id (HTTP 400
  # `MissingSessionID`): one per Session keeps its requests on one routing and
  # prompt-cache lane. Without a Session, the Profile's own id.
  defp put_source_headers(opts, %{"source" => "opencode-go"} = record, session),
    do: Map.put(opts, "default_headers", %{"x-opencode-session" => session || record["id"]})

  defp put_source_headers(opts, _record, _session), do: opts

  # The Session a catalog request belongs to, for a source that keys its
  # routing by it (`put_source_headers/3`).
  defp put_route_session(base, identity) do
    case identity[:session_id] || base["session_id"] do
      session when is_binary(session) and session != "" ->
        Map.put(base, "route_session", SalixAgent.LLM.prompt_cache_key(session))

      _ ->
        base
    end
  end

  # A key serves nothing its owner turned off for it.
  defp key_route(record, model) do
    if excluded?(record, model), do: :error, else: source_route(record, model)
  end

  # The catalog names the request id a source uses. A Custom endpoint is not in
  # the catalog: it serves the model ids it listed when it was connected.
  defp source_route(%{"source" => "custom", "endpoints" => endpoints} = record, model)
       when map_size(endpoints) == 1 do
    if model in List.wrap(record["models"]),
      do: {:ok, model, hd(Map.keys(endpoints))},
      else: :error
  end

  defp source_route(%{"source" => source, "endpoints" => endpoints}, model)
       when is_binary(source) and is_map(endpoints) do
    case SalixAgent.Models.route(model, source) do
      {:ok, %{"model" => request, "protocol" => protocol}} when is_map_key(endpoints, protocol) ->
        {:ok, request, protocol}

      _ ->
        :error
    end
  end

  defp source_route(_, _), do: :error

  defp run_attempts([], _call, _started?, _identity, last), do: last

  defp run_attempts(
         [{kind, funding, prepare} | rest],
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
            {:subscription, model} ->
              dispatch_pool(opts, call, started?, identity, on_received, model)

            :api_key ->
              call.(opts)
          end

        case tag_funding(result, funding) do
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

  defp tag_funding({:error, %{} = meta}, funding),
    do: {:error, Map.put_new(meta, "funding", compact_funding(funding))}

  defp tag_funding(result, _funding), do: result

  defp compact_funding(funding),
    do: funding |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> Map.new()

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
  # `catalog_model`: the catalog id this request serves, so an account that
  # turned it off is no candidate. Nil on a template's own pool route.
  defp pool_candidates(tenant, provider, %{"account_pin" => id} = config, catalog_model)
       when is_binary(id),
       do: Store.candidates(tenant, provider, config["model"], id, [], catalog_model)

  defp pool_candidates(tenant, provider, config, catalog_model),
    do: Store.candidates(tenant, provider, config["model"], nil, [], catalog_model)

  # `on_received` runs when a worker passes on the first response bytes.
  # At most this many accounts serve one request, refills included.
  @account_attempts 10

  defp dispatch_pool(
         opts,
         call,
         started?,
         identity,
         on_received \\ fn -> :ok end,
         catalog_model \\ nil
       ) do
    if owns_route?(opts) do
      config = Map.new(opts, fn {k, v} -> {to_string(k), v} end)
      tenant = config["account_pool_tenant"]
      provider = route_provider(config)

      Log.context([tenant_id: tenant, provider: provider] ++ Log.sanitize(identity), fn ->
        Log.span("subscription_dispatch", [], fn ->
          case with(
                 :ok <- connection(tenant),
                 do: pool_candidates(tenant, provider, config, catalog_model)
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
                  case Store.candidates(
                         tenant,
                         provider,
                         config["model"],
                         nil,
                         tried,
                         catalog_model
                       ) do
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

  defp cooldown_ms(%{"cooldown_until" => until}) when is_integer(until),
    do: (until - SystemsClock.system_time(:millisecond)) |> max(0) |> min(30_000)

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

          received = SystemsRuntime.Atomics.new(2, [])

          transport = fn url, opts ->
            path = URI.parse(url).path

            SalixAgent.SubscriptionWorker.post(
              path,
              opts,
              credential,
              fn ->
                SystemsRuntime.Atomics.put(received, 1, 1)
                on_received.()
              end,
              fn -> SystemsRuntime.Atomics.put(received, 2, 1) end
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
              rejected = SystemsRuntime.Atomics.get(received, 2) == 1

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

                SystemsRuntime.Atomics.get(received, 1) == 1 or started?.() ->
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
        provider: record["source"],
        retry_after_ms: 30_000
      ],
      fn ->
        Log.span("subscription_account_cooldown", [], fn ->
          Store.apply_background(
            tenant,
            record["id"],
            &same_credentials?(&1, record),
            &Map.put(&1, "cooldown_until", SystemsClock.system_time(:millisecond) + 30_000)
          )
        end)
      end
    )
  end

  def validate_config(config, tenant) do
    case config do
      # The model is checked when it is chosen (`SalixAgent.ModelChoice.choose/2`).
      # A stored choice whose Custom endpoint was removed later still resolves:
      # no Profile serves it at dispatch, and the input stops as
      # `model_unavailable`.
      %{"catalog_model" => model} when is_binary(tenant) ->
        if is_boolean(config["allow_paid"]) and
             (is_nil(config["profile_id"]) or is_binary(config["profile_id"])) and
             is_binary(model) and model != "",
           do: :ok,
           else: {:error, {:bad_request, "catalog models require a model and allow_paid"}}

      %{"catalog_model" => _} ->
        {:error, {:bad_request, "catalog models require a tenant"}}

      %{"account_pool" => provider} when is_binary(tenant) and is_map_key(@providers, provider) ->
        :ok

      %{"account_pool" => _} ->
        {:error, {:bad_request, "account pools require a tenant and a subscription provider"}}

      _ ->
        :ok
    end
  end

  @doc "A model a Custom endpoint serves, shaped like a catalog entry."
  # A model the catalog does not know takes what its Custom Profile says of it
  # (`model_info`), else the defaults.
  def custom_model(tenant, model) do
    case Store.custom_model_info(tenant, model) do
      :error ->
        {:error, :invalid_model_configuration}

      {:ok, info} ->
        {:ok,
         %{
           "id" => model,
           "name" => model,
           "vendor" => nil,
           "efforts" => info["efforts"] || [],
           "max_tokens" => info["max_tokens"] || 32_000,
           "context_tokens" => info["context_tokens"] || 0,
           "images" => info["images"] == true
         }}
    end
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
         {:ok, config} <- SalixAgent.AgentModel.resolve_llm(agent) do
      # Only the Tenant's own Profiles serve a catalog choice; it never falls
      # back to platform credentials.
      owns_route?(config) or
        (is_map(config) and is_binary(config["catalog_model"]) and
           config["catalog_tenant"] == tenant)
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
