defmodule SalixAgent.CatalogDispatchTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, ModelChoice}
  alias SalixAgent.SubscriptionStore, as: Store

  setup do
    {:ok, tenant: SalixStore.Ids.new_tenant_id()}
  end

  test "an API-key Profile for a catalog source seals its key and shows only a hint", %{
    tenant: tenant
  } do
    assert {:ok, profile} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")

    assert profile["source"] == "openrouter"
    assert profile["name"] == "OpenRouter API Key"
    assert profile["key_hint"] == "…cdef"
    refute inspect(profile) =~ "0123456789"

    assert {:ok, renamed} =
             AccountPool.update(tenant, profile["id"], %{
               "name" => "Team",
               "version" => profile["version"]
             })

    assert {:ok, replaced} =
             AccountPool.update(tenant, profile["id"], %{
               "api_key" => "sk-or-v1-replacement-9999",
               "version" => renamed["version"]
             })

    assert replaced["name"] == "Team"
    assert replaced["key_hint"] == "…9999"

    # A key shorter than 20 characters shows none of them.
    assert {:ok, %{"key_hint" => "…"}} = key(tenant, "openai", "sk-0123456789abcd")

    # A user endpoint only where the source has none, and only https.
    assert {:error, :invalid_input} =
             key(tenant, "openrouter", "sk-valid-key-0000", %{"base_url" => "https://x.test/v1"})

    assert {:error, :invalid_input} = key(tenant, "azure-openai", "sk-valid-key-0000")

    assert {:ok, %{"source" => "azure-openai"}} =
             key(tenant, "azure-openai", "sk-valid-key-0000", %{
               "base_url" => "https://team.openai.azure.com/openai/v1",
               "protocol" => "responses"
             })

    assert {:error, :invalid_input} = key(tenant, "codex", "sk-valid-key-0000")
    assert {:error, :invalid_input} = key(tenant, "no-such-source", "sk-valid-key-0000")
  end

  test "a platform Profile never serves a model the member chose", %{tenant: tenant} do
    platform = AccountPool.platform_tenant()

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])
    end)

    {:ok, _} = key(platform, "openrouter", "sk-or-v1-platform-0000")

    {:ok, _} =
      key(platform, "custom", "sk-custom-platform-0123", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["platform-model"]
      })

    for allow_paid <- [false, true] do
      assert {:error, _} =
               AccountPool.dispatch(route(tenant, "gpt-5.5", allow_paid), fn _ ->
                 flunk("the platform must not pay for a member's model")
               end)
    end

    assert {:error, :invalid_model_configuration} =
             AccountPool.custom_model(tenant, "platform-model")
  end

  test "a catalog route reaches the model through another provider's key", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")
    route = route(tenant, "gpt-5.5", true)

    assert AccountPool.catalog_route?(route)

    assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
    assert opts["base_url"] == "https://openrouter.ai/api/v1"
    assert opts["protocol"] == "chat_completions"
    assert opts["model"] == "openai/gpt-5.5"
    assert opts["api_key"] == "sk-or-v1-0123456789abcdef"
    assert opts["credential_scope"] == "tenant"
    assert opts["reasoning_effort"] == "high"
  end

  test "an OpenCode Go key is asked with the Session's x-opencode-session, which it requires", %{
    tenant: tenant
  } do
    {:ok, profile} = key(tenant, "opencode-go", "oc-go-0123456789abcdef")
    route = route(tenant, "deepseek-v4.1-flash", true)

    assert {:ok, opts} =
             AccountPool.dispatch(route, &{:ok, &1}, fn -> false end, session_id: "s1")

    assert opts["base_url"] =~ "opencode.ai"
    session = opts["default_headers"]["x-opencode-session"]
    assert session == SalixAgent.LLM.prompt_cache_key("s1")

    # The same Session keeps its id; another has its own; none falls back to the Profile.
    assert {:ok, %{"default_headers" => %{"x-opencode-session" => ^session}}} =
             AccountPool.dispatch(route, &{:ok, &1}, fn -> false end, session_id: "s1")

    assert {:ok, %{"default_headers" => %{"x-opencode-session" => other}}} =
             AccountPool.dispatch(route, &{:ok, &1}, fn -> false end, session_id: "s2")

    refute other == session

    assert {:ok, %{"default_headers" => %{"x-opencode-session" => fallback}}} =
             AccountPool.dispatch(route, &{:ok, &1})

    assert fallback == profile["id"]

    # Another source's key carries no such header.
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")

    assert {:ok, opts} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", true), &{:ok, &1}, fn -> false end,
               session_id: "s1"
             )

    refute Map.has_key?(opts, "default_headers")
  end

  test "without pay-per-use an API key never serves the request", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

    assert {:error, error} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", false), fn _ ->
               flunk("a pay-per-use key must not be called")
             end)

    assert error["body"] =~ "no enabled profile serves gpt-5.5"
  end

  test "a failure before output moves to the next Profile; a started stream does not", %{
    tenant: tenant
  } do
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")
    route = route(tenant, "gpt-5.5", true)
    calls = :counters.new(1, [])

    fail_first = fn opts ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: {:error, %{"status" => 429}},
        else: {:ok, opts["base_url"]}
    end

    assert {:ok, _} = AccountPool.dispatch(route, fail_first)
    assert :counters.get(calls, 1) == 2

    started = :counters.new(1, [])

    assert {:error, %{"status" => 500}} =
             AccountPool.dispatch(
               route,
               fn _ ->
                 :counters.add(started, 1, 1)
                 {:error, %{"status" => 500}}
               end,
               fn -> true end
             )

    assert :counters.get(started, 1) == 1
  end

  test "a failed attempt names the Profile it would have spent, never its credential", %{
    tenant: tenant
  } do
    {:ok, profile} =
      key(tenant, "openai", "sk-proj-0123456789abcdef", %{"name" => "Team OpenAI key"})

    assert {:error, meta} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", true), fn _ ->
               {:error, %{"status" => 402, "body" => "insufficient_quota"}}
             end)

    assert meta["funding"] == %{
             "source" => "openai",
             "profile_id" => profile["id"],
             "profile_name" => "Team OpenAI key"
           }

    refute inspect(meta) =~ "sk-proj-0123456789abcdef"
  end

  test "a Custom endpoint may have no key, and then gets no credential", %{tenant: tenant} do
    endpoint = %{
      "base_url" => "https://ollama.example.test",
      "protocol" => "chat_completions",
      "models" => ["llama3.2:3b"]
    }

    assert {:ok, keyless} =
             AccountPool.create(
               tenant,
               Map.merge(endpoint, %{
                 "credential_kind" => "provider_api_key",
                 "source" => "custom"
               })
             )

    assert {:ok, empty} = key(tenant, "custom", "", endpoint)

    for profile <- [keyless, empty] do
      assert profile["key_hint"] == nil
      assert profile["connection"]["auth_scheme"] == "bearer"
      assert profile["models"] == ["llama3.2:3b"]
    end

    # Dispatch passes no key: the template's own key does not leak to the endpoint.
    route =
      route(tenant, "llama3.2:3b", false)
      |> Map.merge(%{"profile_id" => keyless["id"], "api_key" => "template-key"})

    assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
    assert opts["base_url"] == "https://ollama.example.test/v1"
    assert opts["model"] == "llama3.2:3b"
    for field <- ~w(api_key api_key_env auth_token auth_token_env), do: refute(opts[field])

    # A key can be added later and removed again.
    {:ok, keyed} =
      AccountPool.update(tenant, keyless["id"], %{
        "api_key" => "sk-local-0123456789",
        "version" => keyless["version"]
      })

    assert keyed["key_hint"] == "…"
    assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
    assert opts["api_key"] == "sk-local-0123456789"

    {:ok, cleared} =
      AccountPool.update(tenant, keyless["id"], %{"api_key" => "", "version" => keyed["version"]})

    assert cleared["key_hint"] == nil
    assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
    refute opts["api_key"]

    # Every catalog source still needs a key, on create and on replace.
    assert {:error, :invalid_input} = key(tenant, "openrouter", "")

    assert {:error, :invalid_input} =
             AccountPool.create(tenant, %{
               "credential_kind" => "provider_api_key",
               "source" => "openrouter"
             })

    {:ok, router} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")

    assert {:error, :invalid_input} =
             AccountPool.update(tenant, router["id"], %{
               "api_key" => "",
               "version" => router["version"]
             })
  end

  test "a model only a Custom endpoint lists can be chosen and served", %{tenant: tenant} do
    # Not in the catalog, and no Custom endpoint lists it yet.
    assert {:error, {:bad_request, _}} =
             AccountPool.resolve_config(
               %{"catalog_model" => "llama3.2:3b", "allow_paid" => true},
               tenant
             )

    assert {:error, _} = choose(tenant, "llama3.2:3b", nil, true)

    {:ok, custom} =
      key(tenant, "custom", "", %{
        "base_url" => "https://ollama.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["llama3.2:3b"]
      })

    # Automatic, with pay-per-use allowed.
    {:ok, choice} = choose(tenant, "llama3.2:3b", nil, true)
    {:ok, template} = ModelChoice.record(choice, tenant)
    assert template["model_display_name"] == "llama3.2:3b"
    assert template["model_vendor"] == nil
    assert template["max_tokens"] == 32_000
    assert template["context_tokens"] == 0
    assert template["supports_images"] == false

    {:ok, llm} = ModelChoice.resolve_llm(choice, tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["base_url"] == "https://ollama.example.test/v1"
    assert opts["model"] == "llama3.2:3b"

    # Without pay-per-use the Custom key does not serve, as for any key.
    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "llama3.2:3b", false), fn _ ->
               flunk("a pay-per-use key must not be called")
             end)

    # Pinned to the Custom Profile.
    {:ok, pinned} = choose(tenant, "llama3.2:3b", nil, false, custom["id"])
    {:ok, llm} = ModelChoice.resolve_llm(pinned, tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["model"] == "llama3.2:3b"

    # Such a model has no reasoning efforts.
    assert {:error, :invalid_model_configuration} = choose(tenant, "llama3.2:3b", "high", true)

    # Another tenant's Custom endpoint does not make the model known here.
    assert {:error, {:bad_request, _}} =
             AccountPool.resolve_config(
               %{"catalog_model" => "llama3.2:3b", "allow_paid" => true},
               SalixStore.Ids.new_tenant_id()
             )
  end

  test "an Agent kept to one Profile uses only that Profile", %{tenant: tenant} do
    {:ok, openai} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    {:ok, _router} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")

    # Keeping to a key is choosing to pay for it, whatever allow_paid says.
    pinned = route(tenant, "gpt-5.5", false) |> Map.put("profile_id", openai["id"])
    assert {:ok, opts} = AccountPool.dispatch(pinned, &{:ok, &1})
    assert opts["base_url"] == "https://api.openai.com/v1"

    calls = :counters.new(1, [])

    assert {:error, _} =
             AccountPool.dispatch(pinned, fn _ ->
               :counters.add(calls, 1, 1)
               {:error, %{"status" => 429}}
             end)

    assert :counters.get(calls, 1) == 1

    subscription = subscription(tenant, "codex")
    kept = route(tenant, "gpt-5.5", true) |> Map.put("profile_id", subscription["id"])
    assert {:ok, opts} = AccountPool.dispatch(kept, &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"

    # A plan pinned for a model it does not serve fails without a call or a crash.
    gemini = subscription(tenant, "gemini")
    refute AccountPool.profile_serves?(tenant, gemini["id"], "gpt-5.5")

    assert {:error, _} =
             route(tenant, "gpt-5.5", false)
             |> Map.put("profile_id", gemini["id"])
             |> AccountPool.dispatch(fn _ -> flunk("must not dispatch") end)

    assert AccountPool.profile_serves?(tenant, openai["id"], "gpt-5.5")
    refute AccountPool.profile_serves?(tenant, openai["id"], "claude-opus-5")
    refute AccountPool.profile_serves?(tenant, "missing", "gpt-5.5")

    assert {:error, :invalid_model_configuration} =
             choose(tenant, "claude-opus-5", nil, false, openai["id"])
  end

  # A provider for `SalixAgent.LLM.complete_stream/5`: it streams one delta of
  # the given kind, then fails with an overloaded 529, and counts its calls.
  defmodule StreamThenOverloaded do
    def complete_stream(_messages, _tools, on_delta, opts) do
      {counter, kind} = SystemsRuntime.PersistentTerm.get({__MODULE__, :test})
      :counters.add(counter, 1, 1)
      fetch = &(Map.get(opts, &1) || Map.get(opts, to_string(&1)))

      case kind do
        :text ->
          on_delta.("Hel")

        :tool ->
          fetch.(:on_tool_delta).(%{index: 0, id: "t", name: "reply", fragment: "{"})

        :reasoning ->
          fetch.(:on_reasoning_delta).(SalixAgent.LLM.ReasoningDelta.private_reasoning("x"))
      end

      {:error, %{"status" => 529, "body" => "overloaded_error"}}
    end
  end

  # A worker that passes on response bytes, then fails.
  defmodule BytesThenOverloadedWorker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:start, id, _payload, reply_to}, _from, state) do
      SystemsRuntime.Proc.send(
        reply_to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64("part")}}
      )

      SystemsRuntime.Proc.send(
        reply_to,
        {:subscription, id, %{"type" => "error", "status" => 529, "code" => "busy"}}
      )

      {:reply, :ok, state}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  describe "accounts that reject a model" do
    setup %{tenant: tenant} do
      {:ok, pool} =
        AccountPool.resolve_config(%{"account_pool" => "codex", "model" => "gpt-5.5"}, tenant)

      {:ok, pool: pool}
    end
  end

  test "a model turned off on a Profile is not served by it; another Profile serves it", %{
    tenant: tenant
  } do
    plan = subscription(tenant, "codex")
    {:ok, router} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")
    assert AccountPool.profile_serves?(tenant, plan["id"], "gpt-5.5")

    assert {:ok, off} =
             AccountPool.update(tenant, plan["id"], %{
               "disabled_models" => ["gpt-5.5", "gpt-5.5"],
               "version" => plan["version"]
             })

    assert off["disabled_models"] == ["gpt-5.5"]
    assert {:ok, %{"disabled_models" => ["gpt-5.5"]}} = Store.get(tenant, plan["id"])
    refute AccountPool.profile_serves?(tenant, plan["id"], "gpt-5.5")
    assert AccountPool.profile_serves?(tenant, plan["id"], "gpt-6-luna")
    assert AccountPool.profile_serves?(tenant, router["id"], "gpt-5.5")

    # The plan's pool has no account for the model, so the key serves it.
    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", true), &{:ok, &1})
    assert opts["base_url"] == "https://openrouter.ai/api/v1"

    assert {:error, error} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", false), fn _ ->
               flunk("an account that turned the model off must not serve it")
             end)

    assert error["body"] =~ "no enabled profile serves gpt-5.5"

    assert {:error, _} =
             route(tenant, "gpt-5.5", false)
             |> Map.put("profile_id", plan["id"])
             |> AccountPool.dispatch(fn _ ->
               flunk("a pin must not serve a model it turned off")
             end)

    # Another account of the same plan still offers it.
    other = subscription(tenant, "codex")

    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", false), &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"

    assert {:ok, [only]} =
             Store.candidates(tenant, "codex", "gpt-5.5", nil, [], "gpt-5.5")

    assert only["id"] == other["id"]

    # An API key's exclusion holds on the automatic and the pinned path.
    {:ok, _} =
      AccountPool.update(tenant, router["id"], %{
        "disabled_models" => ["claude-opus-5"],
        "version" => router["version"]
      })

    refute AccountPool.profile_serves?(tenant, router["id"], "claude-opus-5")

    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "claude-opus-5", true), fn _ ->
               flunk("a key must not serve a model it turned off")
             end)

    assert {:error, _} =
             route(tenant, "claude-opus-5", true)
             |> Map.put("profile_id", router["id"])
             |> AccountPool.dispatch(fn _ -> flunk("must not dispatch") end)

    # Turning it back on serves it again.
    {:ok, on} =
      AccountPool.update(tenant, plan["id"], %{
        "disabled_models" => [],
        "version" => off["version"]
      })

    assert on["disabled_models"] == []
    assert AccountPool.profile_serves?(tenant, plan["id"], "gpt-5.5")
  end

  test "a subscription serves before any pay-per-use key", %{tenant: tenant} do
    subscription(tenant, "codex")
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", true), &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"
    assert opts["model"] == "gpt-5.5"
    assert is_function(opts["transport"], 2)
  end

  test "pinning an API key is choosing to pay for it", %{tenant: tenant} do
    {:ok, openai} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    subscription = subscription(tenant, "codex")

    {:ok, pinned} = choose(tenant, "gpt-5.5", nil, false, openai["id"])
    assert pinned["allow_paid"] == true

    {:ok, plan} = choose(tenant, "gpt-5.5", nil, false, subscription["id"])
    assert plan["allow_paid"] == false
  end

  defp key(tenant, source, api_key, extra \\ %{}) do
    AccountPool.create(
      tenant,
      Map.merge(
        %{"credential_kind" => "provider_api_key", "source" => source, "api_key" => api_key},
        extra
      )
    )
  end

  defp route(tenant, model, allow_paid) do
    {:ok, route} =
      AccountPool.resolve_config(
        %{
          "catalog_model" => model,
          "allow_paid" => allow_paid,
          "reasoning_effort" => "high",
          "credential_scope" => "tenant"
        },
        tenant
      )

    route
  end

  # A ready subscription account: prepared credentials that do not expire soon,
  # so dispatch opens them without asking the worker to refresh.
  defp subscription(tenant, provider) do
    id = Store.id()
    {:ok, cipher} = Store.seal(tenant, id, %{"access_token" => "subscription-token"})

    {:ok, record} =
      Store.create(tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => provider,
        "email" => "member@example.com",
        "disabled" => false,
        "status" => "ok",
        "credentials" => cipher,
        "prepared" => true,
        "expires_at" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
      })

    record
  end

  defp choose(tenant, model, effort, allow_paid, profile_id \\ nil) do
    %{
      "kind" => "catalog",
      "model" => model,
      "reasoning_effort" => effort,
      "allow_paid" => allow_paid,
      "profile_id" => profile_id
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> ModelChoice.choose(tenant)
  end
end
