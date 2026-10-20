defmodule SalixAgent.SubscriptionOwnerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.AccountPool
  alias SalixAgent.SubscriptionStore, as: Store

  defmodule Worker do
    use GenServer
    def start_link(fun), do: GenServer.start_link(__MODULE__, fun)
    def init(fun), do: {:ok, fun}

    def handle_call({:start, id, data, reply_to}, _from, fun) do
      SystemsRuntime.Task.start(fn ->
        cmd = Jason.decode!(data)
        result = fun.(cmd)

        case result do
          {:error, status, code} ->
            SystemsRuntime.Proc.send(
              reply_to,
              {:subscription, id, %{"type" => "error", "status" => status, "code" => code}}
            )

          _ ->
            SystemsRuntime.Proc.send(
              reply_to,
              {:subscription, id,
               %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
            )

            SystemsRuntime.Proc.send(reply_to, {:subscription, id, %{"type" => "done"}})
        end
      end)

      {:reply, :ok, fun}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  defmodule ImageResolver do
    def resolve(_agent_id) do
      {choice, tenant} = SystemsRuntime.fetch_env!(:salix_agent, :subscription_image_test_choice)
      SalixAgent.ModelChoice.media(choice, tenant)
    end
  end

  defmodule ImageArchive do
    def record(fact) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:image_archive, fact})
      :ok
    end
  end

  test "a model its own Codex subscription serves generates images through that pool", %{
    tenant: tenant
  } do
    image_storage()
    old_archive = SystemsRuntime.get_env(:salix_agent, :event_archive_mod)
    SystemsRuntime.put_env(:salix_agent, :event_archive_mod, ImageArchive)

    on_exit(fn ->
      if old_archive,
        do: SystemsRuntime.put_env(:salix_agent, :event_archive_mod, old_archive),
        else: SystemsRuntime.delete_env(:salix_agent, :event_archive_mod)
    end)

    account(tenant)
    parent = SystemsRuntime.Proc.self()

    server(fn cmd ->
      case cmd["op"] do
        "/prepare" ->
          reply(cmd)

        "/v1/images/generations" ->
          SystemsRuntime.Proc.send(parent, {:image_request, cmd})

          %{
            "data" => [%{"b64_json" => Base.encode64("generated image bytes")}],
            "output_format" => "png",
            "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
          }
      end
    end)

    choice = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
    {:ok, media} = SalixAgent.ModelChoice.media(choice, tenant)
    assert media["image_config"]["model"] == "gpt-image-2"
    assert media["image_config"]["provider_config"] == %{"account_pool" => "codex"}
    assert media["image_config"]["account_pool_tenant"] == tenant

    SystemsRuntime.put_env(:salix_agent, :subscription_image_test_choice, {choice, tenant})
    agent = SalixAgent.TestSupport.new_agent_id()

    assert {text, [%{"type" => "vfs_write", "path" => "/artifacts/pool.png"} = event]} =
             SalixAgent.Tools.Media.generate_image(
               %{"prompt" => "a blue leaf", "path" => "/artifacts/pool.png", "quality" => "low"},
               %{agent_id: agent, tenant_id: tenant}
             )

    assert text =~ "Generated image"

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(agent, "image-pool-test", %{}, [event])

    assert {:ok, "generated image bytes"} =
             SalixAgent.AgentWorkspace.read(agent, "/artifacts/pool.png")

    settle_receive({:image_request, cmd})
    assert cmd["body"]["model"] == "gpt-image-2"
    assert cmd["body"]["prompt"] == "a blue leaf"
    assert cmd["body"]["quality"] == "low"
    assert cmd["credential"]["credentials"] == %{"access_token" => "rotated"}

    settle_receive(
      {:image_archive, %{boundary: :llm_request, agent_id: ^agent, tenant_id: ^tenant}}
    )

    settle_receive(
      {:image_archive,
       %{
         boundary: :llm_response,
         agent_id: ^agent,
         payload: %{"kind" => "image", "image" => %{"usage" => %{"output_tokens" => 5}}}
       }}
    )
  end

  test "without its own Codex subscription a model keeps the platform image settings", %{
    tenant: tenant
  } do
    image_storage()
    # Another Tenant's subscription neither serves this Tenant nor its images.
    account(SalixStore.Ids.new_tenant_id())
    server(fn _ -> flunk("must not use another tenant's credentials") end)

    choice = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
    {:ok, media} = SalixAgent.ModelChoice.media(choice, tenant)
    refute Map.has_key?(media["image_config"], "account_pool_tenant")

    # A pool route for a Tenant without an owned account fails closed.
    cfg = Map.put(image_config(), "account_pool_tenant", tenant)

    assert {:error, error} =
             SalixAgent.LLM.generate_image("a leaf", [config: cfg], %{tenant_id: tenant})

    assert error["body"] =~ "subscription accounts unavailable"
  end

  defp image_config do
    %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"account_pool" => "codex"}
    }
  end

  defp image_storage do
    saved =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :media_resolver},
            {:salix_agent, :subscription_image_test_choice}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, ImageResolver)

    on_exit(fn ->
      for {app, key, value} <- saved do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)
  end

  setup do
    old = SystemsRuntime.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, old),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
    end)

    {:ok, tenant: SalixStore.Ids.new_tenant_id()}
  end

  test "new subscription accounts return and persist one initial quota read", %{tenant: tenant} do
    parent = SystemsRuntime.Proc.self()

    reset = 1_798_761_600

    # The provider's answer as account-proxy reads it, for each plan.
    answers = %{
      "codex" => %{
        "plan_type" => "pro",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 25,
            "reset_at" => reset,
            "limit_window_seconds" => 604_800
          }
        }
      },
      "claude" => %{
        "seven_day" => %{"utilization" => 25, "resets_at" => "2026-12-31T00:00:00Z"}
      }
    }

    server(fn cmd ->
      case cmd["op"] do
        "/normalize" ->
          %{"email" => "new@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          SystemsRuntime.Proc.send(
            parent,
            {:initial_quota, cmd["body"]["provider"], cmd["body"]["credentials"]}
          )

          %{"body" => answers[cmd["body"]["provider"]]}
      end
    end)

    for provider <- ["codex", "claude"] do
      credentials = %{"access_token" => "new-token"}

      assert {:ok, account} =
               AccountPool.create(tenant, %{
                 "credential_kind" => "subscription_oauth",
                 "provider" => provider,
                 "credentials" => credentials
               })

      settle_receive({:initial_quota, ^provider, ^credentials})
      settle_refute_receive({:initial_quota, ^provider, _})
      # Stored as the Profile's quota; the API says it as before.
      assert [%{"period" => "week", "remaining_percent" => 75.0}] = account["quota"]["windows"]
      refute Map.has_key?(account, "credentials")
      assert {:ok, saved} = Store.get(tenant, account["id"])

      assert [%{"label" => "每周", "minutes" => 10_080, "used_percent" => 25.0}] =
               saved["quota"]["windows"]

      if provider == "codex", do: assert(saved["quota"]["plan_type"] == "pro")
      assert saved["version"] == account["version"]
    end
  end

  test "missing storage key fails subscription requests without calling the provider", %{
    tenant: tenant
  } do
    key = SystemsRuntime.get_env(:salix_agent, :subscription_storage_key)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :subscription_storage_key, key) end)
    route = config(tenant)
    SystemsRuntime.delete_env(:salix_agent, :subscription_storage_key)

    assert AccountPool.owns_route?(route)

    assert {:error, error} =
             AccountPool.dispatch(route, fn _ -> flunk("provider must not be called") end)

    assert error["retryable"] == false
    assert error["body"] =~ "subscription_proxy.storage_key"
    assert {:error, :not_configured} = AccountPool.list(tenant)
    assert :ordinary = AccountPool.dispatch(%{}, fn _ -> :ordinary end)
  end

  defp server(fun) do
    pid = start_supervised!({Worker, fun})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, pid)
  end

  defp account(tenant, attrs \\ %{}) do
    id = Store.id()

    {:ok, cipher} =
      Store.seal(tenant, id, %{"access_token" => "old-token", "refresh_token" => "refresh-token"})

    {:ok, a} =
      Store.create(
        tenant,
        Map.merge(
          %{
            "id" => id,
            "credential" => "subscription",
            "source" => "codex",
            "disabled" => false,
            "status" => "ok",
            "credentials" => cipher,
            "prepared" => false
          },
          attrs
        )
      )

    a
  end

  test "Claude pool OAuth projects access only and rejects disabled or foreign accounts", %{
    tenant: tenant
  } do
    id = Store.id()

    {:ok, cipher} =
      Store.seal(tenant, id, %{
        "access_token" => "claude-access",
        "refresh_token" => "private-refresh",
        "expired" => SystemsClock.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      })

    {:ok, record} =
      Store.create(tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => "claude",
        "disabled" => false,
        "status" => "ok",
        "credentials" => cipher
      })

    assert {:ok,
            %{"access_token" => "claude-access", "credential_kind" => "subscription_oauth"} =
              access} =
             AccountPool.runtime_access(tenant, id, "claude")

    refute Map.has_key?(access, "refresh_token")
    assert {:ok, [^id]} = Store.runtime_candidates(tenant, "claude")
    assert {:ok, []} = Store.runtime_candidates(tenant, "codex")
    assert {:error, _} = AccountPool.runtime_access(SalixStore.Ids.new_tenant_id(), id, "claude")
    assert {:error, _} = AccountPool.runtime_access(tenant, id, "codex")

    {:ok, _} =
      Store.query(
        "UPDATE subscription_accounts SET value=jsonb_set(value, '{disabled}', 'true') WHERE tenant_id=$1 AND id=$2 AND version=$3",
        [tenant, id, record["version"]]
      )

    assert {:ok, []} = Store.runtime_candidates(tenant, "claude")
    assert {:error, _} = AccountPool.runtime_access(tenant, id, "claude")
  end

  test "provider API keys are encrypted and expose only the static account allowlist", %{
    tenant: tenant
  } do
    attrs = %{
      "credential_kind" => "provider_api_key",
      "name" => "Team gateway",
      "connection" => %{
        "endpoint" => "https://models.example.test/v1",
        "protocol" => "anthropic_messages",
        "auth_scheme" => "api_key"
      },
      "credentials" => %{"api_key" => "secret-value"}
    }

    assert {:ok, public} = AccountPool.create(tenant, attrs)
    assert public["credential_kind"] == "provider_api_key"
    assert public["compatible_runtimes"] == ["claude"]
    assert public["saved"]
    refute Map.has_key?(public, "credentials")
    refute inspect(public) =~ "secret-value"

    assert {:ok, stored} = Store.get(tenant, public["id"])
    refute stored["credentials"] =~ "secret-value"

    assert {:ok, %{"api_key" => "secret-value"}} =
             Store.open(tenant, public["id"], stored["credentials"])

    assert {:error, :subscription_access_unavailable} =
             AccountPool.codex_access(tenant, public["id"])

    assert {:error, _} = AccountPool.quota(tenant, public["id"])
    assert {:error, :model_discovery_no_account} = Store.discovery_account(tenant, "custom")

    for bad <- [
          put_in(attrs, ["connection", "endpoint"], "http://models.example.test"),
          put_in(attrs, ["connection", "endpoint"], "https://user@models.example.test"),
          put_in(attrs, ["connection", "endpoint"], "https://models.example.test?key=x"),
          put_in(attrs, ["connection", "auth_scheme"], "api_key_helper"),
          Map.put(attrs, "name", "a" <> String.duplicate("\u0301", 321)),
          put_in(attrs, ["credentials", "api_key"], "bad\nkey")
        ] do
      assert {:error, :invalid_input} = AccountPool.create(tenant, bad)
    end
  end

  test "bound static accounts allow names and disablement but reject connection changes and deletion",
       %{tenant: tenant} do
    {:ok, account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "name" => "Initial",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "openai_responses",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "first"}
      })

    {:ok, _} =
      Store.query(
        "INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id) VALUES ($1,'project','workload',$2)",
        [tenant, account["id"]]
      )

    assert {:ok, renamed} =
             AccountPool.update(tenant, account["id"], %{
               "version" => account["version"],
               "name" => "Renamed"
             })

    assert renamed["name"] == "Renamed"

    change = %{
      "version" => renamed["version"],
      "connection" => %{
        "endpoint" => "https://new.example.test",
        "protocol" => "openai_responses",
        "auth_scheme" => "bearer"
      },
      "credentials" => %{"api_key" => "second"}
    }

    assert {:error, :account_in_use} = AccountPool.update(tenant, account["id"], change)

    assert {:error, :account_in_use} =
             AccountPool.delete(tenant, account["id"], renamed["version"])

    {:ok, _} =
      Store.query(
        "UPDATE runtime_subscription_bindings SET enabled=false WHERE tenant_id=$1 AND account_id=$2",
        [tenant, account["id"]]
      )

    assert {:error, :account_in_use} = AccountPool.update(tenant, account["id"], change)

    assert {:ok, disabled} =
             AccountPool.update(tenant, account["id"], %{
               "version" => renamed["version"],
               "disabled" => true
             })

    assert disabled["disabled"]
  end

  test "reset consumes once, refreshes quota, and replays the same result", %{tenant: tenant} do
    parent = SystemsRuntime.Proc.self()

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          SystemsRuntime.Proc.send(parent, {:reset_key, cmd["body"]["redeem_request_id"]})
          %{"code" => "reset", "windows_reset" => 2}

        "/quota" ->
          %{"body" => %{"rate_limit_reset_credits" => %{"available_count" => 0}}}
      end
    end)

    a = account(tenant, %{"prepared" => true})
    key = Store.id()
    attrs = %{"version" => a["version"], "request_id" => key}

    assert {:ok, %{"outcome" => "reset", "quota_refreshed" => true, "account" => public}} =
             AccountPool.reset_quota(tenant, a["id"], attrs)

    assert public["quota"]["reset_credits"]["available_count"] == 0
    refute Map.has_key?(public, "credentials")
    settle_receive({:reset_key, ^key})
    assert {:ok, %{"outcome" => "reset"}} = AccountPool.reset_quota(tenant, a["id"], attrs)
    settle_refute_receive({:reset_key, _})
  end

  test "uncertain reset keeps its key across reload and refuses a different attempt", %{
    tenant: tenant
  } do
    parent = SystemsRuntime.Proc.self()

    server(fn cmd ->
      SystemsRuntime.Proc.send(parent, {:operation, cmd["op"], cmd["body"]["redeem_request_id"]})
      {:error, 502, "reset_unavailable"}
    end)

    a = account(tenant, %{"prepared" => true})
    key = Store.id()
    attrs = %{"version" => a["version"], "request_id" => key}
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    settle_receive({:operation, "/quota/reset", ^key})
    assert {:ok, stored} = Store.get(tenant, a["id"])
    assert stored["reset_attempt"] == %{"request_id" => key, "outcome" => "pending"}

    assert {:error, :reset_in_progress} =
             AccountPool.reset_quota(tenant, a["id"], %{
               "version" => stored["version"],
               "request_id" => Store.id()
             })

    settle_refute_receive({:operation, _, _})
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    settle_receive({:operation, "/quota/reset", ^key})
  end

  test "a concurrent quota write does not lose the reset outcome", %{
    tenant: tenant
  } do
    a = account(tenant, %{"prepared" => true})
    calls = :atomics.new(1, signed: false)

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          if :atomics.add_get(calls, 1, 1) == 1 do
            # The quota poll writes while the reset is out.
            {:ok, current} = Store.get(tenant, a["id"])

            {:ok, _} =
              Store.update_background(
                tenant,
                Map.put(current, "quota", %{"windows" => [], "observed_at" => "concurrent-poll"}),
                current["version"]
              )

            %{"code" => "reset"}
          else
            %{"code" => "already_redeemed"}
          end

        # The follow-up read fails, so the account shows what the settle left.
        "/quota" ->
          {:error, 502, "quota_unavailable"}
      end
    end)

    attrs = %{"version" => a["version"], "request_id" => Store.id()}

    assert {:ok, %{"outcome" => "reset", "quota_refreshed" => false}} =
             AccountPool.reset_quota(tenant, a["id"], attrs)

    {:ok, current} = Store.get(tenant, a["id"])
    assert current["reset_attempt"]["outcome"] == "reset"
    assert current["quota"]["observed_at"] == "concurrent-poll"
    assert :atomics.get(calls, 1) == 1

    # The same key reads the recorded outcome instead of spending another credit.
    assert {:ok, %{"outcome" => "reset"}} = AccountPool.reset_quota(tenant, a["id"], attrs)
    assert :atomics.get(calls, 1) == 1
  end

  test "a second settle of the same reset key keeps the recorded outcome", %{tenant: tenant} do
    a = account(tenant, %{"prepared" => true})
    attrs = %{"version" => a["version"], "request_id" => Store.id()}
    calls = :atomics.new(1, signed: false)
    parent = SystemsRuntime.Proc.self()

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          if :atomics.add_get(calls, 1, 1) == 1 do
            # A retry with the same pending key runs to the end first.
            SystemsRuntime.Proc.send(
              parent,
              {:second, AccountPool.reset_quota(tenant, a["id"], attrs)}
            )

            %{"code" => "reset"}
          else
            %{"code" => "already_redeemed"}
          end

        "/quota" ->
          {:error, 502, "quota_unavailable"}
      end
    end)

    assert {:ok, %{"outcome" => "already_redeemed"}} =
             AccountPool.reset_quota(tenant, a["id"], attrs)

    assert {:ok, %{"outcome" => "already_redeemed"}} =
             SystemsRuntime.Proc.receive(do: ({:second, result} -> result))

    {:ok, current} = Store.get(tenant, a["id"])
    assert current["reset_attempt"]["outcome"] == "already_redeemed"
  end

  test "a slow quota answer from before a reset does not replace the quota the reset read", %{
    tenant: tenant
  } do
    a = account(tenant, %{"prepared" => true})
    polls = :atomics.new(1, signed: false)

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          %{"code" => "reset"}

        "/quota" ->
          if :atomics.add_get(polls, 1, 1) == 1 do
            # The poll's answer is slow: a reset and its follow-up read land first.
            attrs = %{"version" => a["version"], "request_id" => Store.id()}

            {:ok, %{"quota_refreshed" => true}} =
              AccountPool.reset_quota(tenant, a["id"], attrs)

            %{"body" => %{"plan_type" => "before-reset"}}
          else
            %{"body" => %{"plan_type" => "after-reset"}}
          end
      end
    end)

    assert {:error, :conflict} = AccountPool.quota(tenant, a["id"])
    {:ok, current} = Store.get(tenant, a["id"])
    assert current["quota"]["plan_type"] == "after-reset"
  end

  test "completed reset remains successful when the follow-up quota read fails", %{tenant: tenant} do
    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" -> %{"code" => "reset", "windows_reset" => 1}
        "/quota" -> {:error, 502, "quota_unavailable"}
      end
    end)

    a = account(tenant, %{"prepared" => true})

    assert {:ok, %{"outcome" => "reset", "quota_refreshed" => false}} =
             AccountPool.reset_quota(tenant, a["id"], %{
               "version" => a["version"],
               "request_id" => Store.id()
             })
  end

  test "reset rejects another tenant, unsupported provider, and stale account version", %{
    tenant: tenant
  } do
    server(fn _ -> flunk("must not contact provider") end)
    codex = account(tenant, %{"prepared" => true})
    claude = account(tenant, %{"source" => "claude", "prepared" => true})
    attrs = %{"version" => codex["version"], "request_id" => Store.id()}

    assert {:error, :not_found} =
             AccountPool.reset_quota(SalixStore.Ids.new_tenant_id(), codex["id"], attrs)

    assert {:error, :invalid_input} =
             AccountPool.reset_quota(tenant, claude["id"], %{
               attrs
               | "version" => claude["version"]
             })

    assert {:error, :conflict} =
             AccountPool.reset_quota(tenant, codex["id"], %{attrs | "version" => "stale"})
  end

  test "credential replacement prevents retrying an old reset against the new account", %{
    tenant: tenant
  } do
    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          {:error, 502, "reset_unavailable"}

        "/normalize" ->
          %{"credentials" => %{"access_token" => "new"}, "email" => "new@example.com"}
      end
    end)

    a = account(tenant, %{"prepared" => true})
    attrs = %{"version" => a["version"], "request_id" => Store.id()}
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    {:ok, pending} = Store.get(tenant, a["id"])

    assert {:ok, _} =
             AccountPool.update(tenant, a["id"], %{
               "version" => pending["version"],
               "credentials" => %{"access_token" => "new"}
             })

    assert {:error, :conflict} = AccountPool.reset_quota(tenant, a["id"], attrs)
  end

  defp config(tenant) do
    {:ok, c} =
      AccountPool.resolve_config(%{"account_pool" => "codex", "model" => "gpt-5.5"}, tenant)

    c
  end

  defp reply(_cmd),
    do: %{
      "credentials" => %{"access_token" => "rotated", "refresh_token" => "new-refresh"},
      "email" => "member@example.com"
    }

  for provider <- ["codex", "claude"] do
    @provider provider
    test "reconnecting #{@provider} replaces credentials on the existing tenant account", %{
      tenant: tenant
    } do
      server(fn cmd ->
        case cmd["op"] do
          "/normalize" ->
            %{
              "credentials" => cmd["body"]["credentials"],
              "email" => cmd["body"]["credentials"]["email"]
            }

          "/quota" ->
            %{"body" => %{"plan_type" => "pro"}}
        end
      end)

      attrs = %{
        "credential_kind" => "subscription_oauth",
        "provider" => @provider,
        "credentials" => %{"access_token" => "old", "email" => "Member@example.com"}
      }

      assert {:ok, first} = AccountPool.create(tenant, attrs)
      {:ok, stored} = Store.get(tenant, first["id"])

      {:ok, stale} =
        Store.update(
          tenant,
          Map.merge(stored, %{
            "disabled" => true,
            "status" => "reauthorization_required",
            "prepared" => true,
            "expires_at" => "2020-01-01T00:00:00Z",
            "cooldown_until" => "2099-01-01T00:00:00Z",
            "quota" => %{"windows" => []}
          }),
          stored["version"]
        )

      Store.query(
        "UPDATE subscription_accounts SET poll_delay_seconds=7200,next_poll_at=now()+interval '2 hours' WHERE tenant_id=$1 AND id=$2",
        [tenant, first["id"]]
      )

      credentials = %{
        "access_token" => "new",
        "refresh_token" => "new-refresh",
        "email" => " member@example.com "
      }

      assert {:ok, second} = AccountPool.create(tenant, %{attrs | "credentials" => credentials})
      assert second["id"] == first["id"]
      assert second["version"] != stale["version"]
      assert second["disabled"]
      assert second["status"] == "active"
      refute Map.has_key?(second, "credentials")
      assert {:ok, %{"accounts" => [^second]}} = AccountPool.list(tenant)
      assert {:ok, saved} = Store.get(tenant, first["id"])
      assert {:ok, ^credentials} = Store.open(tenant, first["id"], saved["credentials"])
      refute saved["prepared"]
      assert %{"windows" => []} = saved["quota"]
      for key <- ["cooldown_until", "expires_at"], do: refute(Map.has_key?(saved, key))

      assert {:ok, %{rows: [[0, true]]}} =
               Store.query(
                 "SELECT poll_delay_seconds,next_poll_at<=now() FROM subscription_accounts WHERE tenant_id=$1 AND id=$2",
                 [tenant, first["id"]]
               )

      assert {:error, :conflict} = Store.update(tenant, stale, stale["version"])
    end
  end

  test "device enrollment stays tenant scoped, respects its interval, and consumes the attempt",
       %{tenant: tenant} do
    parent = SystemsRuntime.Proc.self()

    server(fn cmd ->
      case cmd["op"] do
        "/oauth/device/begin" ->
          %{
            "provider" => "codex",
            "mode" => "device",
            "device_auth_id" => "private-id",
            "user_code" => "USER-CODE",
            "interval" => 5,
            "url" => "https://auth.openai.com/codex/device"
          }

        "/oauth/device/poll" ->
          SystemsRuntime.Proc.send(parent, :device_polled)
          %{"credentials" => %{"access_token" => "device-token"}}

        "/normalize" ->
          %{"email" => "device@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          %{"body" => %{"plan_type" => "pro"}}
      end
    end)

    assert {:ok, attempt} =
             AccountPool.begin_oauth(tenant, %{"provider" => "codex", "mode" => "device"})

    refute Map.has_key?(attempt, "device_auth_id")
    assert attempt["user_code"] == "USER-CODE"

    assert {:error, :authorization_unavailable} =
             AccountPool.complete_oauth(SalixStore.Ids.new_tenant_id(), attempt["id"], %{
               "code" => ""
             })

    assert {:ok, %{"status" => "pending", "interval" => 5}} =
             AccountPool.complete_oauth(tenant, attempt["id"], %{"code" => ""})

    refute_received :device_polled

    assert {:ok, %{rows: [[ciphertext]]}} =
             Store.query(
               "SELECT ciphertext FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2",
               [tenant, attempt["id"]]
             )

    assert {:ok, private} = Store.open(tenant, attempt["id"], ciphertext)
    assert {:ok, sealed} = Store.seal(tenant, attempt["id"], Map.put(private, "next_poll_at", 0))

    assert {:ok, _} =
             Store.query(
               "UPDATE subscription_oauth_attempts SET ciphertext=$3 WHERE tenant_id=$1 AND id=$2",
               [tenant, attempt["id"], sealed]
             )

    assert {:ok, account} = AccountPool.complete_oauth(tenant, attempt["id"], %{"code" => ""})
    assert account["provider"] == "codex"
    assert account["quota"]["plan_type"] == "pro"
    assert_received :device_polled

    assert {:error, :authorization_unavailable} =
             AccountPool.complete_oauth(tenant, attempt["id"], %{"code" => ""})
  end

  test "OAuth addition replaces an imported account", %{tenant: tenant} do
    server(fn cmd ->
      case cmd["op"] do
        "/oauth/begin" ->
          %{
            "provider" => "claude",
            "state" => cmd["body"]["state"],
            "url" => "https://example.com/authorize"
          }

        "/oauth/exchange" ->
          %{"credentials" => %{"access_token" => "oauth-token"}}

        "/normalize" ->
          %{"email" => "member@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          %{"body" => %{"plan_type" => "pro"}}
      end
    end)

    assert {:ok, imported} =
             AccountPool.create(tenant, %{
               "credential_kind" => "subscription_oauth",
               "provider" => "claude",
               "credentials" => %{"access_token" => "imported"}
             })

    assert {:ok, attempt} = AccountPool.begin_oauth(tenant, %{"provider" => "claude"})

    assert {:ok, connected} =
             AccountPool.complete_oauth(tenant, attempt["id"], %{"code" => "code"})

    assert connected["id"] == imported["id"]
    assert {:ok, %{"accounts" => [^connected]}} = AccountPool.list(tenant)
    assert {:ok, stored} = Store.get(tenant, connected["id"])

    assert {:ok, %{"access_token" => "oauth-token"}} =
             Store.open(tenant, connected["id"], stored["credentials"])
  end

  test "matching stays within tenant and provider and never merges unknown emails", %{
    tenant: tenant
  } do
    server(fn cmd ->
      %{
        "credentials" => cmd["body"]["credentials"],
        "email" => cmd["body"]["credentials"]["email"]
      }
    end)

    other_tenant = SalixStore.Ids.new_tenant_id()

    accounts =
      for {scope, provider, email} <- [
            {tenant, "codex", "member@example.com"},
            {tenant, "claude", "member@example.com"},
            {other_tenant, "codex", "member@example.com"},
            {tenant, "codex", "other@example.com"},
            {tenant, "codex", nil},
            {tenant, "codex", ""},
            {tenant, "codex", " "}
          ] do
        assert {:ok, account} =
                 AccountPool.create(scope, %{
                   "credential_kind" => "subscription_oauth",
                   "provider" => provider,
                   "credentials" => %{"access_token" => "token", "email" => email}
                 })

        account
      end

    assert accounts |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 7
  end

  test "one refresher, persisted credentials before execution, and no refresh token in inference",
       %{tenant: tenant} do
    owner = SystemsRuntime.Proc.self()

    server(fn cmd ->
      if cmd["op"] == "/prepare" do
        SystemsRuntime.Proc.send(owner, {:prepare, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :continue -> reply(cmd)
        end
      else
        SystemsRuntime.Proc.send(owner, {:selected_credential, cmd["credential"]})
        %{"ok" => true}
      end
    end)

    a = account(tenant)

    task =
      SystemsRuntime.Task.async(fn ->
        AccountPool.dispatch(config(tenant), fn opts ->
          {:ok, saved} = Store.get(tenant, a["id"])
          assert saved["status"] == "ok"
          {:ok, credentials} = Store.open(tenant, a["id"], saved["credentials"])
          assert credentials["access_token"] == "rotated"

          assert {:ok, _} =
                   opts["transport"].("subscription://worker/v1/responses",
                     json: %{"model" => "gpt-5.5"}
                   )

          {:final, "ok", %{}}
        end)
      end)

    settle_receive({:prepare, request})

    assert {:error, %{"status" => 503}} =
             AccountPool.dispatch(config(tenant), fn _ -> flunk("second refresher executed") end)

    SystemsRuntime.Proc.send(request, :continue)
    assert {:final, "ok", %{}} = settled_await(task)
    settle_receive({:selected_credential, %{"credentials" => selected}})
    assert selected["access_token"] == "rotated"
    refute Map.has_key?(selected, "refresh_token")
    {:ok, stored} = Store.get(tenant, a["id"])
    refute stored["credentials"] =~ "rotated"
    other = SalixStore.Ids.new_tenant_id()
    assert {:error, :not_found} = Store.get(other, a["id"])
    assert {:error, :unavailable} = Store.open(other, a["id"], stored["credentials"])
  end

  test "a late refresh cannot restore an account deleted during exchange", %{tenant: tenant} do
    owner = SystemsRuntime.Proc.self()

    server(fn conn ->
      SystemsRuntime.Proc.send(owner, {:prepare, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :continue -> reply(conn)
      end
    end)

    a = account(tenant)

    task =
      SystemsRuntime.Task.async(fn ->
        AccountPool.dispatch(config(tenant), fn _ -> flunk("deleted account executed") end)
      end)

    settle_receive({:prepare, request})
    {:ok, claimed} = Store.get(tenant, a["id"])
    assert {:ok, nil} = AccountPool.delete(tenant, a["id"], claimed["version"])
    SystemsRuntime.Proc.send(request, :continue)
    assert {:error, %{"status" => 503}} = settled_await(task)
    assert {:error, :not_found} = Store.get(tenant, a["id"])
  end

  test "SQL selection follows quota policy and excludes other tenants and exhausted short windows",
       %{tenant: tenant} do
    now = SystemsClock.system_time(:millisecond)

    window = fn pct, days, minutes ->
      %{
        "used_percent" => 100 - pct,
        "resets_at" => now + round(days * 86_400_000),
        "minutes" => minutes
      }
    end

    quota = fn windows -> %{"observed_at" => now, "windows" => windows} end

    regular = account(tenant, %{"quota" => quota.([window.(80, 4, 10_080)])})
    urgent = account(tenant, %{"quota" => quota.([window.(10, 0.5, 10_080)])})

    _exhausted =
      account(tenant, %{"quota" => quota.([window.(100, 0.1, 10_080), window.(0, 0.01, 300)])})

    _foreign =
      account(SalixStore.Ids.new_tenant_id(), %{"quota" => quota.([window.(100, 0.001, 10_080)])})

    assert {:ok, [first, second]} = Store.candidates(tenant, "codex", "gpt-5.5")
    assert first["id"] == urgent["id"]
    assert second["id"] == regular["id"]

    assert {:ok, disabled} =
             Store.update(tenant, Map.put(urgent, "disabled", true), urgent["version"])

    assert {:error, :conflict} = Store.update(tenant, urgent, urgent["version"])
    assert {:ok, [remaining]} = Store.candidates(tenant, "codex", "gpt-5.5")
    assert remaining["id"] == regular["id"]
    assert disabled["disabled"]
  end

  test "account logs connect selection refresh and cooldown without credentials", %{
    tenant: tenant
  } do
    server(&reply/1)
    a = account(tenant)
    previous = Logger.metadata()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log(
        [level: :info, format: {CommaLog.Formatter, :format}, metadata: :all],
        fn ->
          assert {:error, %{"status" => 429}} =
                   AccountPool.dispatch(
                     config(tenant),
                     fn _ ->
                       {:error, %{"status" => 429, "body" => "PRIVATE_PROVIDER_SENTINEL"}}
                     end,
                     fn -> false end,
                     agent_id: "agt1_log_test",
                     session_id: "ses1_log_test"
                   )

          assert {:error, %{"retry_after_ms" => _}} =
                   AccountPool.dispatch(config(tenant), fn _ ->
                     flunk("cooling account executed")
                   end)
        end
      )

    rows = log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    for event <- [
          "subscription_account_selected",
          "subscription_account_refresh_finish",
          "subscription_account_cooldown_finish"
        ] do
      row = Enum.find(rows, &(&1["msg"] == event))
      assert row["account_id"] == a["id"]
      assert row["tenant_id"] == tenant
      assert row["session_id"] == "ses1_log_test"
    end

    assert Enum.any?(
             rows,
             &(&1["msg"] == "subscription_account_selection" and &1["cooling_count"] == 1 and
                 &1["ready_count"] == 0)
           )

    assert Enum.any?(
             rows,
             &(&1["msg"] == "subscription_dispatch_finish" and is_integer(&1["retry_after_ms"]) and
                 &1["retry_after_ms"] > 0)
           )

    for secret <- [
          "PRIVATE_PROVIDER_SENTINEL",
          "old-token",
          "refresh-token",
          "rotated",
          "member@example.com",
          "credentials"
        ],
        do: refute(log =~ secret)

    assert Logger.metadata() == previous
  end

  test "legacy import preserves identity, credentials and disabled state without overwriting", %{
    tenant: tenant
  } do
    id = Store.id()
    key = String.duplicate("k", 32)
    nonce = SystemsRuntime.Proc.random_bytes(12)

    old = %{
      "id" => id,
      "provider" => "codex",
      "disabled" => true,
      "metadata" => %{"access_token" => "imported", "email" => "import@example.com"}
    }

    {body, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        Jason.encode!(old),
        tenant <> "\0" <> id,
        true
      )

    dir = Path.join(System.tmp_dir!(), "subscription-import-" <> Store.id())
    scope = Path.join(dir, Base.url_encode64(tenant, padding: false))
    File.mkdir_p!(scope)
    path = Path.join(scope, Base.url_encode64(id, padding: false) <> ".json.enc")
    File.write!(path, nonce <> body <> tag)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert {:ok, 1} = SalixAgent.SubscriptionImport.run(dir, tenant, key)
    assert {:ok, 1} = SalixAgent.SubscriptionImport.run(dir, tenant, key)
    assert File.exists?(path)
    {:ok, stored} = Store.get(tenant, id)
    assert stored["disabled"]
    assert {:ok, old["metadata"]} == Store.open(tenant, id, stored["credentials"])
    {:ok, _} = Store.update(tenant, Map.put(stored, "disabled", false), stored["version"])
    assert {:error, :divergent_import} = SalixAgent.SubscriptionImport.run(dir, tenant, key)
  end
end
