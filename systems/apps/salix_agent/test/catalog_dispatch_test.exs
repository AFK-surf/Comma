defmodule SalixAgent.CatalogDispatchTest do
  use ExUnit.Case, async: false

  alias SalixAgent.AccountPool
  alias SalixAgent.SubscriptionStore, as: Store

  # The quota poller claims every due account in this database; keep it from
  # rewriting the versions of accounts these tests own.
  setup_all do
    poller = Process.whereis(SalixAgent.SubscriptionQuotaWorker)
    if poller, do: :sys.suspend(poller)
    on_exit(fn -> if poller && Process.alive?(poller), do: :sys.resume(poller) end)
    :ok
  end

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
               "base_url" => "https://team.openai.azure.com/openai/v1"
             })

    assert {:error, :invalid_input} = key(tenant, "codex", "sk-valid-key-0000")
    assert {:error, :invalid_input} = key(tenant, "no-such-source", "sk-valid-key-0000")
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

  test "without pay-per-use an API key never serves the request", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

    assert {:error, error} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", false), fn _ ->
               flunk("a pay-per-use key must not be called")
             end)

    assert error["body"] =~ "no enabled profile serves gpt-5.5"
  end

  test "a disabled Profile is skipped", %{tenant: tenant} do
    {:ok, profile} = key(tenant, "openai", "sk-proj-0123456789abcdef")

    {:ok, _} =
      AccountPool.update(tenant, profile["id"], %{
        "disabled" => true,
        "version" => profile["version"]
      })

    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", true), fn _ ->
               flunk("a disabled profile must not be called")
             end)
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

  test "an error another Profile cannot fix is returned, not retried", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")
    calls = :counters.new(1, [])

    for error <- [
          %{"status" => 400, "body" => "context too long"},
          %{"category" => "transport_error"}
        ] do
      :counters.put(calls, 1, 0)

      assert {:error, ^error} =
               AccountPool.dispatch(route(tenant, "gpt-5.5", true), fn _ ->
                 :counters.add(calls, 1, 1)
                 {:error, error}
               end)

      assert :counters.get(calls, 1) == 1
    end
  end

  test "a Custom endpoint serves only the models it listed", %{tenant: tenant} do
    {:ok, profile} =
      key(tenant, "custom", "sk-custom-0123456789", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["team-model"]
      })

    assert profile["models"] == ["team-model"]

    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", true), fn _ ->
               flunk("Custom must not serve an unlisted model")
             end)

    {:ok, custom} =
      AccountPool.resolve_config(%{"catalog_model" => "gpt-5.5", "allow_paid" => true}, tenant)

    assert {:ok, opts} =
             AccountPool.dispatch(%{custom | "catalog_model" => "team-model"}, &{:ok, &1})

    assert opts["base_url"] == "https://llm.example.test/v1"
    assert opts["model"] == "team-model"
  end

  test "one bad model id drops only that id from a Custom endpoint", %{tenant: tenant} do
    {:ok, profile} =
      key(tenant, "custom", "sk-custom-0123456789", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["team-model", "", 7, String.duplicate("m", 201), "team-model", "other"]
      })

    assert profile["models"] == ["team-model", "other"]

    # The cap stays: a list over 500 ids is not kept.
    {:ok, too_many} =
      key(tenant, "custom", "sk-custom-0123456789", %{
        "base_url" => "https://llm.example.test/v1",
        "protocol" => "chat_completions",
        "models" => Enum.map(1..501, &"m#{&1}")
      })

    assert too_many["models"] == nil
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

    assert {:error, _} =
             SalixAgent.Templates.resolve_private_catalog("llama3.2:3b", nil, true, tenant)

    {:ok, custom} =
      key(tenant, "custom", "", %{
        "base_url" => "https://ollama.example.test/v1",
        "protocol" => "chat_completions",
        "models" => ["llama3.2:3b"]
      })

    # Automatic, with pay-per-use allowed.
    {:ok, choice} = SalixAgent.Templates.resolve_private_catalog("llama3.2:3b", nil, true, tenant)
    assert choice["model_display_name"] == "llama3.2:3b"
    assert choice["model_vendor"] == nil
    assert choice["max_tokens"] == 32_000
    assert choice["context_tokens"] == 0
    assert choice["supports_images"] == false

    {:ok, llm} = SalixAgent.Templates.resolve_llm_for_template(choice["template_id"], tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["base_url"] == "https://ollama.example.test/v1"
    assert opts["model"] == "llama3.2:3b"

    # Without pay-per-use the Custom key does not serve, as for any key.
    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "llama3.2:3b", false), fn _ ->
               flunk("a pay-per-use key must not be called")
             end)

    # Pinned to the Custom Profile.
    {:ok, pinned} =
      SalixAgent.Templates.resolve_private_catalog(
        "llama3.2:3b",
        nil,
        false,
        tenant,
        custom["id"]
      )

    {:ok, llm} = SalixAgent.Templates.resolve_llm_for_template(pinned["template_id"], tenant)
    assert {:ok, opts} = AccountPool.dispatch(llm, &{:ok, &1})
    assert opts["model"] == "llama3.2:3b"

    # Such a model has no reasoning efforts.
    assert {:error, :invalid_model_configuration} =
             SalixAgent.Templates.resolve_private_catalog("llama3.2:3b", "high", true, tenant)

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
             SalixAgent.Templates.resolve_private_catalog(
               "claude-opus-5",
               nil,
               false,
               tenant,
               openai["id"]
             )
  end

  # A provider for `SalixAgent.LLM.complete_stream/5`: it streams one delta of
  # the given kind, then fails with an overloaded 529, and counts its calls.
  defmodule StreamThenOverloaded do
    def complete_stream(_messages, _tools, on_delta, opts) do
      {counter, kind} = :persistent_term.get({__MODULE__, :test})
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

  test "output of any kind, then an error, does not move to another Profile", %{tenant: tenant} do
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    {:ok, _} = key(tenant, "openrouter", "sk-or-v1-0123456789abcdef")
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, StreamThenOverloaded)

    on_exit(fn ->
      :persistent_term.erase({StreamThenOverloaded, :test})

      if previous,
        do: Application.put_env(:salix_agent, :llm, previous),
        else: Application.delete_env(:salix_agent, :llm)
    end)

    for kind <- [:text, :tool, :reasoning] do
      calls = :counters.new(1, [])
      :persistent_term.put({StreamThenOverloaded, :test}, {calls, kind})

      opts =
        route(tenant, "gpt-5.5", true)
        |> Map.merge(%{
          "metering_disabled" => true,
          "on_tool_delta" => fn _ -> :ok end,
          "on_reasoning_delta" => fn _ -> :ok end
        })

      assert {:error, %{"status" => 529}} =
               SalixAgent.LLM.complete_stream([], [], fn _ -> :ok end, opts)

      assert {kind, :counters.get(calls, 1)} == {kind, 1}
    end
  end

  # A worker that passes on response bytes, then fails.
  defmodule BytesThenOverloadedWorker do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:start, id, _payload, reply_to}, _from, state) do
      send(reply_to, {:subscription, id, %{"type" => "data", "data" => Base.encode64("part")}})
      send(reply_to, {:subscription, id, %{"type" => "error", "status" => 529, "code" => "busy"}})
      {:reply, :ok, state}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  test "a subscription worker that received bytes ends the dispatch", %{tenant: tenant} do
    subscription(tenant, "codex")
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    previous = Application.get_env(:salix_agent, :subscription_worker)

    Application.put_env(
      :salix_agent,
      :subscription_worker,
      start_supervised!(BytesThenOverloadedWorker)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :subscription_worker, previous),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

    calls = :counters.new(1, [])

    # A blocking call (compaction, titles) sets no delta; the pool's bytes count.
    call = fn opts ->
      :counters.add(calls, 1, 1)

      case opts["transport"] do
        transport when is_function(transport, 2) ->
          transport.("subscription://worker/v1/responses", json: %{"model" => "gpt-5.5"})
          {:error, %{"status" => 529}}

        _ ->
          flunk("a key must not take over after the worker received bytes")
      end
    end

    assert {:error, %{"status" => 529}} =
             AccountPool.dispatch(route(tenant, "gpt-5.5", true), call)

    assert :counters.get(calls, 1) == 1
  end

  test "a pinned subscription with no quota left is unavailable, not called", %{tenant: tenant} do
    account = subscription(tenant, "codex")
    {:ok, current} = Store.get(tenant, account["id"])

    reset = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))

    {:ok, _} =
      Store.update(
        tenant,
        Map.put(current, "quota", %{
          "windows" => [%{"period" => "week", "remaining_percent" => 0, "reset_at" => reset}]
        }),
        current["version"]
      )

    assert {:error, %{"status" => 503}} =
             route(tenant, "gpt-5.5", false)
             |> Map.put("profile_id", account["id"])
             |> AccountPool.dispatch(fn _ -> flunk("an exhausted pin must not be called") end)
  end

  test "a release waits while a selection holds the catalog lock", %{tenant: tenant} do
    {:ok, choice} = SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "high", false, tenant)
    parent = self()

    holder =
      Task.async(fn ->
        SalixAgent.Templates.with_catalog_lock(tenant, fn ->
          send(parent, :locked)
          Process.sleep(300)
          {:ok, System.monotonic_time(:millisecond)}
        end)
      end)

    assert_receive :locked

    release =
      Task.async(fn ->
        :ok = SalixAgent.Templates.release_private_catalog(choice["template_id"], tenant)
        System.monotonic_time(:millisecond)
      end)

    {:ok, held_until} = Task.await(holder)
    assert Task.await(release) >= held_until
  end

  test "a subscription keeps the request's own settings, automatic and pinned", %{
    tenant: tenant
  } do
    account = subscription(tenant, "codex")
    on_tool = fn _ -> :tool end
    on_reasoning = fn _ -> :reasoning end

    request =
      route(tenant, "gpt-5.5", false)
      |> Map.merge(%{
        "on_tool_delta" => on_tool,
        "on_reasoning_delta" => on_reasoning,
        "prompt_cache_key" => "cache-key",
        "transport_retry" => false,
        "response_format" => %{"type" => "json_object"},
        # A template's endpoint and credential never reach a Profile.
        "api_key" => "template-key",
        "default_headers" => %{"x-leak" => "1"}
      })

    for opts <- [request, Map.put(request, "profile_id", account["id"])] do
      assert {:ok, sent} = AccountPool.dispatch(opts, &{:ok, &1})
      assert sent["base_url"] == "subscription://worker/v1"
      assert sent["on_tool_delta"] == on_tool
      assert sent["on_reasoning_delta"] == on_reasoning
      assert sent["prompt_cache_key"] == "cache-key"
      assert sent["transport_retry"] == false
      assert sent["response_format"] == %{"type" => "json_object"}
      refute sent["api_key"]
      refute sent["default_headers"]
    end
  end

  test "an Anthropic-native Custom endpoint sends its key as x-api-key", %{tenant: tenant} do
    {:ok, profile} =
      key(tenant, "custom", "sk-ant-local-0123456789", %{
        "base_url" => "https://claude.example.test",
        "protocol" => "anthropic",
        "models" => ["team-claude"]
      })

    assert profile["connection"]["auth_scheme"] == "api_key"

    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "team-claude", true), &{:ok, &1})
    assert opts["protocol"] == "anthropic"
    assert opts["api_key"] == "sk-ant-local-0123456789"
    refute opts["auth_token"]
  end

  # Each plan's pool route sets the wire protocol; the catalog gives only the
  # request id (Kimi Code serves `kimi-k3` as `k3`).
  @plans [
    {"gemini", "gemini-3.1-pro-low", "gemini-3.1-pro-low", "chat_completions",
     "subscription://gemini/v1"},
    {"grok", "grok-4.3", "grok-4.3", "responses", "subscription://grok/v1"},
    {"kimi-code", "kimi-k3", "k3", "anthropic", "subscription://kimi-code"},
    {"github-copilot", "gemini-3.5-flash", "gemini-3.5-flash", "chat_completions",
     "subscription://github-copilot/v1"}
  ]

  test "every subscription plan serves its catalog models, automatically and pinned" do
    for {plan, model, request, protocol, base_url} <- @plans do
      tenant = SalixStore.Ids.new_tenant_id()
      account = subscription(tenant, plan)

      assert {:ok, opts} = AccountPool.dispatch(route(tenant, model, false), &{:ok, &1})
      assert {opts["protocol"], opts["base_url"], opts["model"]} == {protocol, base_url, request}
      assert is_function(opts["transport"], 2)

      # Pinned: only this account serves, even when another plan could.
      other = subscription(tenant, "codex")
      assert AccountPool.profile_serves?(tenant, account["id"], model)

      pinned = route(tenant, model, false) |> Map.put("profile_id", account["id"])
      assert {:ok, opts} = AccountPool.dispatch(pinned, &{:ok, &1})
      assert {opts["base_url"], opts["model"]} == {base_url, request}

      {:ok, _} =
        AccountPool.update(tenant, account["id"], %{
          "disabled" => true,
          "version" => account["version"]
        })

      assert {:error, _} =
               AccountPool.dispatch(pinned, fn _ -> flunk("a disabled pin must not dispatch") end)

      # Another plan's account pinned for this model is not a candidate.
      refute AccountPool.profile_serves?(tenant, other["id"], model)
    end
  end

  # Copilot sends Chat Completions upstream for every model, Claude ones too.
  # A catalog route that needs the Responses API cannot run on it.
  test "a plan without a Responses pool does not serve a Responses-only route", %{
    tenant: tenant
  } do
    copilot = subscription(tenant, "github-copilot")
    {:ok, %{"protocol" => "responses"}} = SalixAgent.Models.route("gpt-5-mini", "github-copilot")

    refute AccountPool.profile_serves?(tenant, copilot["id"], "gpt-5-mini")

    assert {:error, _} =
             AccountPool.dispatch(route(tenant, "gpt-5-mini", false), fn _ ->
               flunk("a Responses-only route must not run on Copilot")
             end)

    assert {:error, _} =
             route(tenant, "gpt-5-mini", false)
             |> Map.put("profile_id", copilot["id"])
             |> AccountPool.dispatch(fn _ -> flunk("must not dispatch") end)

    for {model, request} <- [
          {"gemini-3.5-flash", "gemini-3.5-flash"},
          {"claude-haiku-4-5", "claude-haiku-4.5"}
        ] do
      assert AccountPool.profile_serves?(tenant, copilot["id"], model)
      assert {:ok, opts} = AccountPool.dispatch(route(tenant, model, false), &{:ok, &1})

      assert {opts["protocol"], opts["base_url"], opts["model"]} ==
               {"chat_completions", "subscription://github-copilot/v1", request}
    end
  end

  # Owner decision: 400, 403 and 404 reject a model or a request, not the
  # account. Only account-level failures cool the account down.
  test "a model-level rejection leaves the account ready; a 429 cools it", %{tenant: tenant} do
    account = subscription(tenant, "codex")
    request = route(tenant, "gpt-5.5", false)

    for status <- [400, 403, 404] do
      assert {:error, %{"status" => ^status}} =
               AccountPool.dispatch(request, fn _ -> {:error, %{"status" => status}} end)

      assert {:ok, saved} = Store.get(tenant, account["id"])
      refute saved["cooldown_until"]
    end

    assert {:ok, %{"base_url" => "subscription://worker/v1"}} =
             AccountPool.dispatch(request, &{:ok, &1})

    assert {:error, _} = AccountPool.dispatch(request, fn _ -> {:error, %{"status" => 429}} end)
    assert {:ok, saved} = Store.get(tenant, account["id"])
    assert saved["cooldown_until"]
  end

  describe "accounts that reject a model" do
    setup %{tenant: tenant} do
      {:ok, pool} =
        AccountPool.resolve_config(%{"account_pool" => "codex", "model" => "gpt-5.5"}, tenant)

      {:ok, pool: pool}
    end

    test "a request reaches accounts past the first fetched ones", %{tenant: tenant, pool: pool} do
      for _ <- 1..4, do: subscription(tenant, "codex")
      calls = :counters.new(1, [])

      # Every account tried is a new one; the fourth serves the model.
      call = fn _ ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) < 4, do: {:error, %{"status" => 404}}, else: {:ok, :served}
      end

      assert {:ok, :served} = AccountPool.dispatch(pool, call)
      assert :counters.get(calls, 1) == 4
    end

    test "a request-level 400 is not retried on another account", %{tenant: tenant, pool: pool} do
      for _ <- 1..2, do: subscription(tenant, "codex")
      calls = :counters.new(1, [])

      assert {:error, %{"status" => 400}} =
               AccountPool.dispatch(pool, fn _ ->
                 :counters.add(calls, 1, 1)
                 {:error, %{"status" => 400}}
               end)

      assert :counters.get(calls, 1) == 1
    end

    test "each 403 is logged against its account", %{tenant: tenant, pool: pool} do
      account = subscription(tenant, "codex")

      log =
        ExUnit.CaptureLog.capture_log([metadata: [:account_id]], fn ->
          assert {:error, _} =
                   AccountPool.dispatch(pool, fn _ -> {:error, %{"status" => 403}} end)
        end)

      assert log =~ "subscription_account_forbidden"
      assert log =~ account["id"]
      refute log =~ "subscription-token"
    end
  end

  test "a subscription serves before any pay-per-use key", %{tenant: tenant} do
    subscription(tenant, "codex")
    {:ok, _} = key(tenant, "openai", "sk-proj-0123456789abcdef")

    assert {:ok, opts} = AccountPool.dispatch(route(tenant, "gpt-5.5", true), &{:ok, &1})
    assert opts["base_url"] == "subscription://worker/v1"
    assert opts["model"] == "gpt-5.5"
    assert is_function(opts["transport"], 2)
  end

  test "an unknown catalog model cannot be configured", %{tenant: tenant} do
    assert {:error, {:bad_request, _}} =
             AccountPool.resolve_config(
               %{"catalog_model" => "no-such-model", "allow_paid" => true},
               tenant
             )

    assert {:error, {:bad_request, _}} =
             AccountPool.resolve_config(
               %{"catalog_model" => "gpt-5.5", "allow_paid" => true},
               nil
             )
  end

  test "pinning an API key is choosing to pay for it", %{tenant: tenant} do
    {:ok, openai} = key(tenant, "openai", "sk-proj-0123456789abcdef")
    subscription = subscription(tenant, "codex")

    {:ok, pinned} =
      SalixAgent.Templates.resolve_private_catalog("gpt-5.5", nil, false, tenant, openai["id"])

    assert pinned["provider_config"]["allow_paid"] == true

    # Asking again with false finds the same choice.
    assert {:ok, %{"template_id" => same}} =
             SalixAgent.Templates.resolve_private_catalog(
               "gpt-5.5",
               nil,
               false,
               tenant,
               openai["id"]
             )

    assert same == pinned["template_id"]

    {:ok, plan} =
      SalixAgent.Templates.resolve_private_catalog(
        "gpt-5.5",
        nil,
        false,
        tenant,
        subscription["id"]
      )

    assert plan["provider_config"]["allow_paid"] == false
  end

  test "a catalog choice reuses its private template", %{tenant: tenant} do
    {:ok, first} = SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "high", false, tenant)
    {:ok, again} = SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "high", false, tenant)
    {:ok, paid} = SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "high", true, tenant)

    assert first["template_id"] == again["template_id"]
    refute paid["template_id"] == first["template_id"]
    assert first["model_display_name"] == "GPT-5.5"

    assert {:error, :invalid_model_configuration} =
             SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "ultra", false, tenant)

    assert {:ok, llm} =
             SalixAgent.Templates.resolve_llm_for_template(first["template_id"], tenant)

    assert AccountPool.catalog_route?(llm)
    assert llm["credential_scope"] == "tenant"
  end

  test "releasing a catalog choice deletes it only when no Agent uses it", %{tenant: tenant} do
    {:ok, choice} = SalixAgent.Templates.resolve_private_catalog("gpt-5.5", "high", false, tenant)

    assert :ok = SalixAgent.Templates.release_private_catalog(choice["template_id"], tenant)
    assert {:error, :not_found} = SalixAgent.Templates.get(choice["template_id"], tenant)
    assert :ok = SalixAgent.Templates.release_private_catalog(nil, tenant)
  end

  test "a runtime choice is a hidden template its runtime can run, reused and released", %{
    tenant: tenant
  } do
    alias SalixAgent.Templates

    {:ok, codex} = Templates.resolve_private_runtime("codex", "gpt-5.5", "high", tenant)
    {:ok, again} = Templates.resolve_private_runtime("codex", "gpt-5.5", "high", tenant)
    {:ok, default} = Templates.resolve_private_runtime("codex", "gpt-5.5", nil, tenant)

    assert again["template_id"] == codex["template_id"]
    refute default["template_id"] == codex["template_id"]
    assert codex["hidden"] == true

    # Compute dispatch reads exactly these fields when the binding has no model.
    assert {:ok, llm} = Templates.resolve_llm_for_template(codex["template_id"], tenant)

    assert {llm["model"], llm["provider"], llm["reasoning_effort"]} ==
             {"gpt-5.5", "openai", "high"}

    # Codex and Claude Code run only what their own subscription serves. Pi
    # needs a Pi provider id that the catalog does not name.
    for {runtime, model, effort} <- [
          {"codex", "claude-opus-5", nil},
          {"claude", "gpt-5.5", nil},
          {"codex", "gpt-5.5", "ultra"},
          {"pi", "claude-opus-5", nil},
          {"kimi", "gpt-5.5", nil}
        ] do
      assert {:error, :invalid_model_configuration} =
               Templates.resolve_private_runtime(runtime, model, effort, tenant)
    end

    assert {:ok, _} = Templates.resolve_private_runtime("claude", "claude-opus-5", "max", tenant)

    assert :ok = Templates.release_private_catalog(codex["template_id"], tenant)
    assert {:error, :not_found} = Templates.get(codex["template_id"], tenant)
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
        "credential_kind" => "subscription_oauth",
        "provider" => provider,
        "email" => "member@example.com",
        "disabled" => false,
        "status" => "active",
        "credentials" => cipher,
        "prepared" => true,
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
      })

    record
  end
end
