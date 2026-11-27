defmodule SalixAgent.CatalogDispatchTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, ModelChoice, PlatformRouter}
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

    # A retry finds no Profile either: the input stops and names the model.
    assert error["retryable"] == false
    assert error["error_class"] == "billing_unavailable"
    assert error["reason"] == "model_unavailable"
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

    # Only that key serves the model, so choosing it is choosing to pay for it,
    # and a stored choice that says otherwise reads the same.
    assert {:ok, %{"allow_paid" => true}} = choose(tenant, "llama3.2:3b", nil, false)

    stored = %{"kind" => "catalog", "model" => "llama3.2:3b", "allow_paid" => false}
    assert {:ok, %{"allow_paid" => true}} = ModelChoice.public(stored, tenant)
    {:ok, llm} = ModelChoice.resolve_llm(stored, tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["base_url"] == "https://ollama.example.test/v1"

    # Pinned to the Custom Profile.
    {:ok, pinned} = choose(tenant, "llama3.2:3b", nil, false, custom["id"])
    {:ok, llm} = ModelChoice.resolve_llm(pinned, tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["model"] == "llama3.2:3b"

    # Such a model has no reasoning efforts.
    assert {:error, :invalid_model_configuration} = choose(tenant, "llama3.2:3b", "high", true)

    # Another tenant's Custom endpoint does not make the model known here.
    assert {:error, _} = choose(SalixStore.Ids.new_tenant_id(), "llama3.2:3b", nil, true)

    # Once the endpoint's Profile is removed, a stored choice still reads as
    # that model, and dispatch stops the input as `model_unavailable`.
    AccountPool.delete(tenant, custom["id"], custom["version"])
    assert {:error, :not_found} = Store.get(tenant, custom["id"])
    {:ok, template} = ModelChoice.record(choice, tenant)
    assert template["model_display_name"] == "llama3.2:3b"
    assert {:ok, %{"catalog_model" => "llama3.2:3b"}} = ModelChoice.public(choice, tenant)
    {:ok, llm} = ModelChoice.resolve_llm(choice, tenant)

    assert {:error, %{"reason" => "model_unavailable", "retryable" => false}} =
             AccountPool.dispatch(llm, fn _ -> flunk("no Profile serves the model") end)
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

  test "own subscriptions at their usage limit stop the input as quota_exhausted, naming the one that refills first",
       %{tenant: tenant} do
    now = SystemsClock.system_time(:millisecond)

    used_up = fn hours ->
      %{
        "quota" => %{
          "observed_at" => now,
          "windows" => [
            %{"used_percent" => 100, "resets_at" => now + hours * 3_600_000, "minutes" => 10_080}
          ]
        }
      }
    end

    later = subscription(tenant, "codex", Map.put(used_up.(30), "name", "Later"))
    sooner = subscription(tenant, "codex", Map.put(used_up.(3), "name", "ChatGPT Plus"))

    for route <- [
          route(tenant, "gpt-5.5", false),
          Map.put(route(tenant, "gpt-5.5", false), "profile_id", sooner["id"])
        ] do
      assert {:error, error} =
               AccountPool.dispatch(route, fn _ -> flunk("a used-up plan must not be called") end)

      assert error["error_class"] == "billing_unavailable"
      assert error["reason"] == "quota_exhausted"
      assert error["retryable"] == false

      assert error["funding"] == %{
               "source" => "codex",
               "profile_id" => sooner["id"],
               "profile_name" => "ChatGPT Plus",
               "reset_at" => div(now + 3 * 3_600_000, 1000)
             }
    end

    # Kept to the other plan, the stop names that one.
    assert {:error, %{"reason" => "quota_exhausted", "funding" => %{"profile_id" => id}}} =
             route(tenant, "gpt-5.5", false)
             |> Map.put("profile_id", later["id"])
             |> AccountPool.dispatch(fn _ -> flunk("a used-up plan must not be called") end)

    assert id == later["id"]

    # A plan with allowance left serves; pay-per-use serves past used-up plans.
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", true), &{:ok, &1})
    assert opts["base_url"] == "https://api.openai.com/v1"

    subscription(tenant, "codex")
    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", false), &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"
  end

  test "a used-up ChatGPT plan goes on with its credits only once its owner lets it",
       %{tenant: tenant} do
    now = SystemsClock.system_time(:millisecond)

    plan =
      subscription(tenant, "codex", %{
        "name" => "ChatGPT Pro",
        "quota" => %{
          "observed_at" => now,
          "windows" => [
            %{"used_percent" => 100, "resets_at" => now + 3_600_000, "minutes" => 10_080}
          ],
          "credits" => %{"has_credits" => true, "unlimited" => false, "balance" => "60470"}
        }
      })

    # Credits alone are not spent: the stop says the plan has some.
    assert {:error, %{"reason" => "quota_exhausted", "funding" => funding}} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", false), fn _ ->
               flunk("credits must not be spent unasked")
             end)

    assert funding["profile_id"] == plan["id"]
    assert funding["credits"] == true

    {:ok, on} =
      AccountPool.update(tenant, plan["id"], %{
        "use_credits" => true,
        "version" => plan["version"]
      })

    assert on["use_credits"] == true

    # Plans a provider asked to wait do not keep it from serving now.
    for _ <- 1..3, do: subscription(tenant, "codex", %{"cooldown_until" => now + 60_000})
    assert {:ok, [first | _]} = Store.candidates(tenant, "codex", "gpt-5.5")
    assert first["id"] == plan["id"]
    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", false), &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"

    # A plan with allowance left still serves first.
    fresh = subscription(tenant, "codex")
    assert {:ok, [first, second | _]} = Store.candidates(tenant, "codex", "gpt-5.5")
    assert {first["id"], second["id"]} == {fresh["id"], plan["id"]}
  end

  describe "a platform Router" do
    setup %{tenant: tenant} do
      platform = AccountPool.platform_tenant()

      on_exit(fn ->
        Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])
        PlatformRouter.delete(tenant)
      end)

      {:ok, platform_key} = key(platform, "openrouter", "sk-or-v1-platform-router-0000")
      {:ok, platform_key: platform_key}
    end

    test "serves on platform keys first, then the tenant's subscriptions; its keys only when the record allows pay-per-use",
         %{tenant: tenant, platform_key: platform_key} do
      subscription(tenant, "codex")
      {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

      assert {:ok, %{"allow_paid" => false}} =
               PlatformRouter.put(tenant, %{"model" => "gpt-5.5", "billing" => "record"})

      route = marked_route(tenant, "gpt-5.5")
      assert route["platform"] == true
      refute route["allow_paid"]

      # The platform key serves, and the meta names what served it.
      assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
      assert opts["api_key"] == "sk-or-v1-platform-router-0000"
      assert opts["credential_scope"] == "platform"
      assert opts["funding"] == %{"scope" => "platform", "billing" => "record"}

      attempts = fn -> Enum.reverse(Process.get(:attempts, [])) end

      record_attempt = fn opts ->
        Process.put(:attempts, [opts["base_url"] | Process.get(:attempts, [])])
      end

      # A platform key refused before output: the tenant's subscription serves.
      platform_fails = fn opts ->
        record_attempt.(opts)

        if opts["api_key"] == "sk-or-v1-platform-router-0000",
          do: {:error, %{"status" => 429}},
          else: {:ok, opts}
      end

      assert {:ok, opts} = AccountPool.dispatch(route, platform_fails)
      assert opts["base_url"] == "subscription://worker/v1"
      assert opts["funding"] == %{"scope" => "tenant", "billing" => "record"}
      assert attempts.() == ["https://openrouter.ai/api/v1", "subscription://worker/v1"]

      # No subscription serves either: the tenant's API key is not tried, and
      # the stop is the platform attempt's.
      only_tenant_key = fn opts ->
        record_attempt.(opts)

        if opts["api_key"] == "sk-proj-0123456789abcdef",
          do: {:ok, opts},
          else: {:error, %{"status" => 429}}
      end

      Process.delete(:attempts)
      assert {:error, meta} = AccountPool.dispatch(route, only_tenant_key)
      assert meta["funding"] == %{"source" => "platform"}
      assert attempts.() == ["https://openrouter.ai/api/v1", "subscription://worker/v1"]

      # When nothing serves, the stop is the platform's and names no platform Profile.
      assert {:error, meta} =
               AccountPool.dispatch(route, fn _ ->
                 {:error, %{"status" => 402, "body" => "insufficient_quota"}}
               end)

      assert meta["funding"] == %{"source" => "platform"}
      refute inspect(meta) =~ platform_key["id"]
      refute inspect(meta) =~ "sk-or-v1-platform-router-0000"

      # The record allows pay-per-use: the tenant's key serves past the
      # subscriptions, funded by the tenant. The record decides, so the stored
      # choice without `allow_paid` does not keep the key out.
      assert {:ok, %{"allow_paid" => true}} =
               PlatformRouter.put(tenant, %{
                 "model" => "gpt-5.5",
                 "billing" => "record",
                 "allow_paid" => "true"
               })

      subscription(tenant, "codex")
      Process.delete(:attempts)
      assert {:ok, opts} = AccountPool.dispatch(route, only_tenant_key)
      assert opts["api_key"] == "sk-proj-0123456789abcdef"
      assert opts["funding"] == %{"scope" => "tenant", "billing" => "record"}
      assert hd(attempts.()) == "https://openrouter.ai/api/v1"
      assert List.last(attempts.()) == "https://api.openai.com/v1"

      # Turned off again without re-applying: a stored choice that still
      # allows pay-per-use does not keep the key path.
      assert {:ok, %{"allow_paid" => false}} =
               PlatformRouter.put(tenant, %{"model" => "gpt-5.5", "billing" => "record"})

      paid = marked_route(tenant, "gpt-5.5", true)
      assert paid["platform"] == true
      assert paid["allow_paid"] == true
      assert paid["base_url"] == "catalog://"

      subscription(tenant, "codex")
      Process.delete(:attempts)
      assert {:error, _meta} = AccountPool.dispatch(paid, only_tenant_key)
      refute "https://api.openai.com/v1" in attempts.()

      # Cleared, no platform key serves and the choice's own `allow_paid`
      # applies; nothing is platform-funded.
      :ok = PlatformRouter.delete(tenant)
      subscription(tenant, "codex")
      assert {:ok, opts} = AccountPool.dispatch(route, &{:ok, &1})
      assert opts["base_url"] == "subscription://worker/v1"
      refute Map.has_key?(opts, "funding")

      Process.delete(:attempts)
      assert {:error, _meta} = AccountPool.dispatch(route, only_tenant_key)
      refute "https://api.openai.com/v1" in attempts.()
      refute "https://openrouter.ai/api/v1" in attempts.()

      Process.delete(:attempts)
      assert {:ok, opts} = AccountPool.dispatch(paid, only_tenant_key)
      assert opts["api_key"] == "sk-proj-0123456789abcdef"
      assert opts["credential_scope"] == "tenant"
      refute Map.has_key?(opts, "funding")
      refute "https://openrouter.ai/api/v1" in attempts.()

      # A tenant with no Profile of its own gets the usual stop.
      bare = SalixStore.Ids.new_tenant_id()

      assert {:error, error} =
               AccountPool.dispatch(marked_route(bare, "gpt-5.5"), fn _ ->
                 flunk("no platform key without the record")
               end)

      assert error["reason"] == "model_unavailable"
    end

    test "in deduct billing a fee refusal skips the platform keys", %{tenant: tenant} do
      assert {:ok, _} =
               PlatformRouter.put(tenant, %{"model" => "gpt-5.5", "billing" => "deduct"})

      refuse = fn -> {:error, %{reason: "insufficient_credits"}} end
      refused = Map.put(marked_route(tenant, "gpt-5.5"), "platform_admit", refuse)

      # No subscription of the tenant serves, and its API key is not tried
      # without pay-per-use: the stop is the refusal.
      {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

      assert {:error, error} =
               AccountPool.dispatch(refused, fn _ ->
                 flunk("a refused platform key must not serve")
               end)

      assert error["error_class"] == "billing_unavailable"
      assert error["reason"] == "insufficient_credits"
      assert error["retryable"] == false

      # The tenant's subscription serves past the refusal.
      subscription(tenant, "codex")
      assert {:ok, opts} = AccountPool.dispatch(refused, &{:ok, &1})
      assert opts["funding"] == %{"scope" => "tenant", "billing" => "deduct"}

      # Admitted, the platform key serves.
      admitted = Map.put(refused, "platform_admit", fn -> :ok end)
      assert {:ok, opts} = AccountPool.dispatch(admitted, &{:ok, &1})
      assert opts["funding"] == %{"scope" => "platform", "billing" => "deduct"}
    end
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

  # The route of a Router holding the platform Router's marked choice.
  defp marked_route(tenant, model, allow_paid \\ false) do
    choice = %{"kind" => "catalog", "model" => model, "platform" => true}
    choice = if allow_paid, do: Map.put(choice, "allow_paid", true), else: choice
    {:ok, record} = ModelChoice.record(choice, tenant)
    assert record["provider_config"]["platform"] == true
    assert {:ok, %{} = route} = ModelChoice.llm_config(record)
    assert route["catalog_model"] == model
    route
  end

  # A ready subscription account: prepared credentials that do not expire soon,
  # so dispatch opens them without asking the worker to refresh.
  defp subscription(tenant, provider, extra \\ %{}) do
    id = Store.id()
    {:ok, cipher} = Store.seal(tenant, id, %{"access_token" => "subscription-token"})

    {:ok, record} =
      Store.create(
        tenant,
        Map.merge(
          %{
            "id" => id,
            "credential" => "subscription",
            "source" => provider,
            "email" => "member@example.com",
            "disabled" => false,
            "status" => "ok",
            "credentials" => cipher,
            "prepared" => true,
            "expires_at" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
          },
          extra
        )
      )

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
