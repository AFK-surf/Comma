defmodule SalixAgent.SubscriptionOwnerTest do
  use ExUnit.Case, async: false
  alias SalixAgent.AccountPool
  alias SalixAgent.SubscriptionStore, as: Store

  defmodule Worker do
    use GenServer
    def start_link(fun), do: GenServer.start_link(__MODULE__, fun)
    def init(fun), do: {:ok, fun}

    def handle_call({:start, id, data, reply_to}, _from, fun) do
      Task.start(fn ->
        cmd = Jason.decode!(data)
        result = fun.(cmd)

        case result do
          {:error, status, code} ->
            send(
              reply_to,
              {:subscription, id, %{"type" => "error", "status" => status, "code" => code}}
            )

          _ ->
            send(
              reply_to,
              {:subscription, id,
               %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
            )

            send(reply_to, {:subscription, id, %{"type" => "done"}})
        end
      end)

      {:reply, :ok, fun}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  defmodule ImageResolver do
    def resolve(_agent_id) do
      {template, tenant} = Application.fetch_env!(:salix_agent, :subscription_image_test_template)
      SalixAgent.Templates.resolve_media_for_template(template, tenant)
    end
  end

  defmodule ImageArchive do
    def record(fact) do
      send(self(), {:image_archive, fact})
      :ok
    end
  end

  test "private image template selects its pool and writes the generated image", %{tenant: tenant} do
    image_storage()
    old_archive = Application.get_env(:salix_agent, :event_archive_mod)
    Application.put_env(:salix_agent, :event_archive_mod, ImageArchive)

    on_exit(fn ->
      if old_archive,
        do: Application.put_env(:salix_agent, :event_archive_mod, old_archive),
        else: Application.delete_env(:salix_agent, :event_archive_mod)
    end)

    account(tenant)
    parent = self()

    server(fn cmd ->
      case cmd["op"] do
        "/prepare" ->
          reply(cmd)

        "/v1/images/generations" ->
          send(parent, {:image_request, cmd})

          %{
            "data" => [%{"b64_json" => Base.encode64("generated image bytes")}],
            "output_format" => "png",
            "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
          }
      end
    end)

    cfg = image_config() |> Map.put("account_pool_tenant", SalixStore.Ids.new_tenant_id())
    cfg = put_in(cfg, ["provider_config", "base_url"], "https://untrusted.invalid")
    cfg = put_in(cfg, ["provider_config", "api_key"], "must-not-be-used")

    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{"name" => "Image subscription", "model" => "gpt-5.5", "image_config" => cfg},
        tenant
      )

    {:ok, resolved} =
      SalixAgent.Templates.resolve_media_for_template(template["template_id"], tenant)

    assert resolved["image_config"]["account_pool_tenant"] == tenant

    assert {:error, {:template_not_found, _}} =
             SalixAgent.Templates.resolve_media_for_template(
               template["template_id"],
               SalixStore.Ids.new_tenant_id()
             )

    Application.put_env(
      :salix_agent,
      :subscription_image_test_template,
      {template["template_id"], tenant}
    )

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

    assert_receive {:image_request, cmd}
    assert cmd["body"]["model"] == "gpt-image-2"
    assert cmd["body"]["prompt"] == "a blue leaf"
    assert cmd["body"]["quality"] == "low"
    assert cmd["credential"]["credentials"] == %{"access_token" => "rotated"}

    assert_receive {:image_archive,
                    %{boundary: :llm_request, agent_id: ^agent, tenant_id: ^tenant}}

    assert_receive {:image_archive,
                    %{
                      boundary: :llm_response,
                      agent_id: ^agent,
                      payload: %{
                        "kind" => "image",
                        "image" => %{"usage" => %{"output_tokens" => 5}}
                      }
                    }}

    {:ok, _} =
      SalixAgent.Templates.update_private(
        template["template_id"],
        %{
          "image_config" => %{},
          "provider_config" => %{"account_pool" => "codex"}
        },
        tenant
      )

    assert {_text, [%{"type" => "vfs_write"}]} =
             SalixAgent.Tools.Media.generate_image(
               %{"prompt" => "an inherited blue leaf", "path" => "/artifacts/inherited.png"},
               %{agent_id: agent, tenant_id: tenant}
             )

    assert_receive {:image_request, inherited}
    assert inherited["body"]["model"] == "gpt-image-2"
    assert inherited["credential"]["credentials"] == %{"access_token" => "rotated"}
  end

  test "empty image configuration follows the private template's current subscription source", %{
    tenant: tenant
  } do
    image_storage()

    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Automatic images",
          "model" => "gpt-5.5",
          "provider_config" => %{"account_pool" => "codex"}
        },
        tenant
      )

    id = template["template_id"]
    {:ok, media} = SalixAgent.Templates.resolve_media_for_template(id, tenant)
    assert media["image_config"]["model"] == "gpt-image-2"
    assert media["image_config"]["provider_config"]["account_pool"] == "codex"
    assert media["image_config"]["account_pool_tenant"] == tenant
    {:ok, stored} = SalixAgent.Templates.get(id, tenant)
    assert stored["image_config"] == %{}

    custom = %{
      "provider" => "openai",
      "model" => "custom-image",
      "base_url" => "https://images.example.test"
    }

    {:ok, _} = SalixAgent.Templates.update_private(id, %{"image_config" => custom}, tenant)
    {:ok, media} = SalixAgent.Templates.resolve_media_for_template(id, tenant)
    assert media["image_config"]["model"] == "custom-image"
    refute Map.has_key?(media["image_config"], "account_pool_tenant")

    {:ok, _} =
      SalixAgent.Templates.update_private(
        id,
        %{"image_config" => %{}, "provider_config" => %{"account_pool" => "claude"}},
        tenant
      )

    {:ok, media} = SalixAgent.Templates.resolve_media_for_template(id, tenant)
    refute Map.has_key?(media["image_config"], "account_pool_tenant")
    refute media["image_config"]["model"] == "gpt-image-2"
  end

  test "image pools fail closed without an owned account and reject global templates", %{
    tenant: tenant
  } do
    image_storage()
    account(SalixStore.Ids.new_tenant_id())
    server(fn _ -> flunk("must not use another tenant's credentials") end)

    attrs = %{
      "name" => "Image subscription",
      "model" => "gpt-5.5",
      "image_config" => image_config()
    }

    assert {:error, {:bad_request, _}} = SalixAgent.Templates.create(attrs)
    assert {:ok, template} = SalixAgent.Templates.create_private(attrs, tenant)

    assert {:error, {:bad_request, _}} =
             SalixAgent.Templates.update_private(
               template["template_id"],
               %{
                 "image_config" =>
                   put_in(image_config(), ["provider_config", "account_pool"], "claude")
               },
               tenant
             )

    {:ok, media} =
      SalixAgent.Templates.resolve_media_for_template(template["template_id"], tenant)

    assert {:error, error} =
             SalixAgent.LLM.generate_image("a leaf", [config: media["image_config"]], %{
               tenant_id: tenant
             })

    assert error["body"] =~ "subscription accounts unavailable"
  end

  test "image output received from a failed attempt is not generated again", %{tenant: tenant} do
    image_storage()
    account(tenant)
    account(tenant)
    parent = self()

    server(fn cmd ->
      case cmd["op"] do
        "/prepare" ->
          reply(cmd)

        "/v1/images/generations" ->
          send(parent, :image_attempt)
          %{"data" => []}
      end
    end)

    cfg = Map.put(image_config(), "account_pool_tenant", tenant)

    assert {:error, _} =
             SalixAgent.LLM.generate_image("a leaf", [config: cfg], %{tenant_id: tenant})

    assert_receive :image_attempt
    refute_received :image_attempt
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
            {:salix_agent, :subscription_image_test_template}
          ],
          do: {app, key, Application.get_env(app, key)}

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :media_resolver, ImageResolver)

    on_exit(fn ->
      for {app, key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)
  end

  # The background quota poller claims every due account in this database,
  # including the ones these tests create, because a new row is due at once.
  # It would then call the stub worker and rewrite the account version under
  # tests that own both. Keep that independent writer out of this module.
  setup_all do
    poller = Process.whereis(SalixAgent.SubscriptionQuotaWorker)
    if poller, do: :sys.suspend(poller)

    on_exit(fn ->
      if poller && Process.alive?(poller), do: :sys.resume(poller)
    end)

    :ok
  end

  setup do
    old = Application.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_agent, :subscription_worker, old),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

    {:ok, tenant: SalixStore.Ids.new_tenant_id()}
  end

  test "new subscription accounts return and persist one initial quota read", %{tenant: tenant} do
    parent = self()

    snapshot = %{
      "plan_type" => "pro",
      "windows" => [%{"period" => "week", "remaining_percent" => 75}]
    }

    server(fn cmd ->
      case cmd["op"] do
        "/normalize" ->
          %{"email" => "new@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          send(parent, {:initial_quota, cmd["body"]["provider"], cmd["body"]["credentials"]})
          snapshot
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

      assert_receive {:initial_quota, ^provider, ^credentials}
      refute_receive {:initial_quota, ^provider, _}
      assert account["quota"] == snapshot
      refute Map.has_key?(account, "credentials")
      assert {:ok, saved} = Store.get(tenant, account["id"])
      assert saved["quota"] == snapshot
      assert saved["version"] == account["version"]
    end
  end

  test "failed initial quota read preserves the saved subscription", %{tenant: tenant} do
    parent = self()

    server(fn cmd ->
      case cmd["op"] do
        "/normalize" ->
          %{"email" => "new@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          send(parent, :initial_quota_failed)
          {:error, 502, "quota_unavailable"}
      end
    end)

    assert {:ok, account} =
             AccountPool.create(tenant, %{
               "credential_kind" => "subscription_oauth",
               "provider" => "codex",
               "credentials" => %{"access_token" => "new-token"}
             })

    assert_receive :initial_quota_failed
    refute_receive :initial_quota_failed
    assert account["status"] == "active"
    assert {:ok, saved} = Store.get(tenant, account["id"])
    assert saved["version"] == account["version"]

    assert {:ok, %{"access_token" => "new-token"}} =
             Store.open(tenant, saved["id"], saved["credentials"])

    assert {:ok, _} =
             AccountPool.update(tenant, account["id"], %{
               "version" => account["version"],
               "disabled" => true
             })
  end

  test "missing storage key fails subscription requests without calling the provider", %{
    tenant: tenant
  } do
    key = Application.get_env(:salix_agent, :subscription_storage_key)
    on_exit(fn -> Application.put_env(:salix_agent, :subscription_storage_key, key) end)
    route = config(tenant)
    Application.delete_env(:salix_agent, :subscription_storage_key)

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
    Application.put_env(:salix_agent, :subscription_worker, pid)
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
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "disabled" => false,
            "status" => "active",
            "credentials" => cipher,
            "prepared" => false
          },
          attrs
        )
      )

    a
  end

  test "runtime candidates skip global exhaustion and cooldown without hiding later accounts", %{
    tenant: tenant
  } do
    future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
    window = %{"period" => "week", "remaining_percent" => 0, "reset_at" => future}

    for {id, attrs} <- [
          {"00-empty", %{"quota" => %{"windows" => [window]}}},
          {"01-empty", %{"quota" => %{"windows" => [window]}}},
          {"02-cooling", %{"cooldown_until" => future}},
          {"03-available", %{"quota" => %{"windows" => [%{window | "remaining_percent" => 10}]}}},
          {"04-unknown", %{}},
          {"05-reset", %{"quota" => %{"windows" => [%{window | "reset_at" => past}]}}},
          {"06-model", %{"quota" => %{"windows" => [Map.put(window, "model", "special")]}}}
        ] do
      assert {:ok, _} =
               Store.create(
                 tenant,
                 Map.merge(
                   %{
                     "id" => id,
                     "credential_kind" => "subscription_oauth",
                     "provider" => "codex",
                     "disabled" => false,
                     "status" => "active"
                   },
                   attrs
                 )
               )
    end

    assert {:ok, ["03-available", "04-unknown", "05-reset"]} =
             Store.runtime_candidates(tenant, "codex")

    assert {:ok, ["06-model"]} = Store.runtime_candidates(tenant, "codex", "05-reset")
    assert Store.runtime_quota_exhausted?(tenant, "00-empty")

    for id <- ~w(02-cooling 03-available 04-unknown 05-reset 06-model missing) do
      refute Store.runtime_quota_exhausted?(tenant, id)
    end

    refute Store.runtime_quota_exhausted?(SalixStore.Ids.new_tenant_id(), "00-empty")
    assert {:ok, []} = Store.runtime_candidates(tenant, "claude")
  end

  test "Claude pool OAuth projects access only and rejects disabled or foreign accounts", %{
    tenant: tenant
  } do
    id = Store.id()

    {:ok, cipher} =
      Store.seal(tenant, id, %{
        "access_token" => "claude-access",
        "refresh_token" => "private-refresh",
        "expired" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      })

    {:ok, record} =
      Store.create(tenant, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "claude",
        "disabled" => false,
        "status" => "active",
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
    assert public["compatible_runtimes"] == ["pi", "claude"]
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

  test "account locking serializes binding creation before a connection update", %{tenant: tenant} do
    {:ok, account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "name" => "Concurrent",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "openai_responses",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "first"}
      })

    parent = self()

    binder =
      Task.async(fn ->
        Store.locked_account(tenant, account["id"], fn _current ->
          send(parent, :account_locked)
          receive do: (:create_binding -> :ok)

          Store.query(
            "INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id) VALUES ($1,'project','workload',$2)",
            [tenant, account["id"]]
          )
        end)
      end)

    assert_receive :account_locked

    editor =
      Task.async(fn ->
        AccountPool.update(tenant, account["id"], %{
          "version" => account["version"],
          "connection" => %{
            "endpoint" => "https://new.example.test",
            "protocol" => "openai_responses",
            "auth_scheme" => "bearer"
          },
          "credentials" => %{"api_key" => "second"}
        })
      end)

    refute Task.yield(editor, 50)
    send(binder.pid, :create_binding)
    assert {:ok, %Postgrex.Result{num_rows: 1}} = Task.await(binder)
    assert {:error, :account_in_use} = Task.await(editor)
  end

  test "binding usage is indexed, tenant scoped, and paginated at 25", %{tenant: tenant} do
    {:ok, account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "name" => "Paged",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "openai_completions",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "secret"}
      })

    for n <- 1..26 do
      {:ok, _} =
        Store.query(
          "INSERT INTO runtime_subscription_bindings (tenant_id,project_id,workload_id,account_id) VALUES ($1,$2,$3,$4)",
          [tenant, "project-#{n}", "workload-#{n}", account["id"]]
        )
    end

    assert {:ok, %{"bindings" => first, "next" => cursor}} =
             AccountPool.list_bindings(tenant, account["id"])

    assert length(first) == 25
    assert is_integer(cursor)
    assert Enum.all?(first, &(&1["enabled"] == true))

    assert {:ok, %{"bindings" => [last], "next" => nil}} =
             AccountPool.list_bindings(tenant, account["id"], cursor)

    assert last["project_id"] == "project-26"

    assert {:error, :not_found} =
             AccountPool.list_bindings(SalixStore.Ids.new_tenant_id(), account["id"])
  end

  test "reset consumes once, refreshes quota, and replays the same result", %{tenant: tenant} do
    parent = self()

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          send(parent, {:reset_key, cmd["body"]["redeem_request_id"]})
          %{"code" => "reset", "windows_reset" => 2}

        "/quota" ->
          %{"windows" => [], "reset_credits" => %{"available_count" => 0}}
      end
    end)

    a = account(tenant, %{"prepared" => true})
    key = Store.id()
    attrs = %{"version" => a["version"], "request_id" => key}

    assert {:ok, %{"outcome" => "reset", "quota_refreshed" => true, "account" => public}} =
             AccountPool.reset_quota(tenant, a["id"], attrs)

    assert public["quota"]["reset_credits"]["available_count"] == 0
    refute Map.has_key?(public, "credentials")
    assert_receive {:reset_key, ^key}
    assert {:ok, %{"outcome" => "reset"}} = AccountPool.reset_quota(tenant, a["id"], attrs)
    refute_receive {:reset_key, _}
  end

  test "uncertain reset keeps its key across reload and refuses a different attempt", %{
    tenant: tenant
  } do
    parent = self()

    server(fn cmd ->
      send(parent, {:operation, cmd["op"], cmd["body"]["redeem_request_id"]})
      {:error, 502, "reset_unavailable"}
    end)

    a = account(tenant, %{"prepared" => true})
    key = Store.id()
    attrs = %{"version" => a["version"], "request_id" => key}
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    assert_receive {:operation, "/quota/reset", ^key}
    assert {:ok, stored} = Store.get(tenant, a["id"])
    assert stored["reset_attempt"] == %{"request_id" => key, "outcome" => "pending"}

    assert {:error, :reset_in_progress} =
             AccountPool.reset_quota(tenant, a["id"], %{
               "version" => stored["version"],
               "request_id" => Store.id()
             })

    refute_receive {:operation, _, _}
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    assert_receive {:operation, "/quota/reset", ^key}
  end

  test "a concurrent quota write preserves the pending reset for same-key recovery", %{
    tenant: tenant
  } do
    a = account(tenant, %{"prepared" => true})
    calls = :atomics.new(1, signed: false)

    server(fn cmd ->
      case cmd["op"] do
        "/quota/reset" ->
          if :atomics.add_get(calls, 1, 1) == 1 do
            {:ok, current} = Store.get(tenant, a["id"])

            {:ok, _} =
              Store.update(
                tenant,
                Map.put(current, "quota", %{"windows" => [], "observed_at" => "concurrent-poll"}),
                current["version"]
              )

            %{"code" => "reset"}
          else
            %{"code" => "already_redeemed"}
          end

        "/quota" ->
          %{"windows" => [], "reset_credits" => %{"available_count" => 0}}
      end
    end)

    attrs = %{"version" => a["version"], "request_id" => Store.id()}
    assert {:error, :reset_pending} = AccountPool.reset_quota(tenant, a["id"], attrs)
    {:ok, current} = Store.get(tenant, a["id"])
    assert current["quota"]["observed_at"] == "concurrent-poll"
    assert current["reset_attempt"]["outcome"] == "pending"

    assert {:ok, %{"outcome" => "already_redeemed", "quota_refreshed" => true}} =
             AccountPool.reset_quota(tenant, a["id"], attrs)
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
    claude = account(tenant, %{"provider" => "claude", "prepared" => true})
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
            %{"plan_type" => "pro", "windows" => []}
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
      assert saved["quota"] == %{"plan_type" => "pro", "windows" => []}
      for key <- ["cooldown_until", "expires_at"], do: refute(Map.has_key?(saved, key))

      assert {:ok, %{rows: [[0, true]]}} =
               Store.query(
                 "SELECT poll_delay_seconds,next_poll_at<=now() FROM subscription_accounts WHERE tenant_id=$1 AND id=$2",
                 [tenant, first["id"]]
               )

      assert {:error, :conflict} = Store.update(tenant, stale, stale["version"])
    end
  end

  test "concurrent imports keep one account and the final import replaces its credentials", %{
    tenant: tenant
  } do
    server(fn cmd ->
      case cmd["op"] do
        "/normalize" ->
          %{"credentials" => cmd["body"]["credentials"], "email" => "member@example.com"}

        "/quota" ->
          %{"plan_type" => "pro", "windows" => []}
      end
    end)

    results =
      1..8
      |> Task.async_stream(
        fn n ->
          AccountPool.create(tenant, %{
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "credentials" => %{"access_token" => "token-#{n}"}
          })
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, {:ok, account}} -> account end)

    assert results |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 1

    assert {:ok, final} =
             AccountPool.create(tenant, %{
               "credential_kind" => "subscription_oauth",
               "provider" => "codex",
               "credentials" => %{"access_token" => "final"}
             })

    assert {:ok, %{"accounts" => [^final]}} = AccountPool.list(tenant)
    {:ok, stored} = Store.get(tenant, final["id"])

    assert {:ok, %{"access_token" => "final"}} =
             Store.open(tenant, final["id"], stored["credentials"])
  end

  test "device enrollment stays tenant scoped, respects its interval, and consumes the attempt",
       %{tenant: tenant} do
    parent = self()

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
          send(parent, :device_polled)
          %{"credentials" => %{"access_token" => "device-token"}}

        "/normalize" ->
          %{"email" => "device@example.com", "credentials" => cmd["body"]["credentials"]}

        "/quota" ->
          %{"plan_type" => "pro", "windows" => []}
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
          %{"plan_type" => "pro", "windows" => []}
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
    owner = self()

    server(fn cmd ->
      if cmd["op"] == "/prepare" do
        send(owner, {:prepare, self()})

        receive do
          :continue -> reply(cmd)
        end
      else
        send(owner, {:selected_credential, cmd["credential"]})
        %{"ok" => true}
      end
    end)

    a = account(tenant)

    task =
      Task.async(fn ->
        AccountPool.dispatch(config(tenant), fn opts ->
          {:ok, saved} = Store.get(tenant, a["id"])
          assert saved["status"] == "active"
          {:ok, credentials} = Store.open(tenant, a["id"], saved["credentials"])
          assert credentials["access_token"] == "rotated"

          assert {:ok, _} =
                   opts["transport"].("subscription://worker/v1/responses",
                     json: %{"model" => "gpt-5.5"}
                   )

          {:final, "ok", %{}}
        end)
      end)

    assert_receive {:prepare, request}, 2_000

    assert {:error, %{"status" => 503}} =
             AccountPool.dispatch(config(tenant), fn _ -> flunk("second refresher executed") end)

    send(request, :continue)
    assert {:final, "ok", %{}} = Task.await(task)
    assert_receive {:selected_credential, %{"credentials" => selected}}
    assert selected["access_token"] == "rotated"
    refute Map.has_key?(selected, "refresh_token")
    {:ok, stored} = Store.get(tenant, a["id"])
    refute stored["credentials"] =~ "rotated"
    other = SalixStore.Ids.new_tenant_id()
    assert {:error, :not_found} = Store.get(other, a["id"])
    assert {:error, :unavailable} = Store.open(other, a["id"], stored["credentials"])
  end

  test "a late refresh cannot restore an account deleted during exchange", %{tenant: tenant} do
    owner = self()

    server(fn conn ->
      send(owner, {:prepare, self()})

      receive do
        :continue -> reply(conn)
      end
    end)

    a = account(tenant)

    task =
      Task.async(fn ->
        AccountPool.dispatch(config(tenant), fn _ -> flunk("deleted account executed") end)
      end)

    assert_receive {:prepare, request}, 2_000
    {:ok, claimed} = Store.get(tenant, a["id"])
    assert {:ok, nil} = AccountPool.delete(tenant, a["id"], claimed["version"])
    send(request, :continue)
    assert {:error, %{"status" => 503}} = Task.await(task)
    assert {:error, :not_found} = Store.get(tenant, a["id"])
  end

  test "SQL selection follows quota policy and excludes other tenants and exhausted short windows",
       %{tenant: tenant} do
    window = fn pct, days, period ->
      %{
        "remaining_percent" => pct,
        "reset_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), round(days * 86400))),
        "period" => period
      }
    end

    quota = fn windows ->
      %{"observed_at" => DateTime.to_iso8601(DateTime.utc_now()), "windows" => windows}
    end

    regular = account(tenant, %{"quota" => quota.([window.(80, 4, "week")])})
    urgent = account(tenant, %{"quota" => quota.([window.(10, 0.5, "week")])})

    _exhausted =
      account(tenant, %{"quota" => quota.([window.(100, 0.1, "week"), window.(0, 0.01, "short")])})

    _foreign =
      account(SalixStore.Ids.new_tenant_id(), %{"quota" => quota.([window.(100, 0.001, "week")])})

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

  @tag subscription_timeout_regression: true
  test "a cooling pool reports when to retry and prefers ready accounts", %{tenant: tenant} do
    cooling =
      account(tenant, %{
        "prepared" => true,
        "cooldown_until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 30))
      })

    assert {:error, %{"status" => 503, "retry_after_ms" => delay}} =
             AccountPool.dispatch(config(tenant), fn _ -> flunk("cooling account executed") end)

    assert delay > 20_000 and delay <= 30_000

    for _ <- 1..3 do
      account(tenant, %{
        "prepared" => true,
        "cooldown_until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 30))
      })
    end

    ready = account(tenant, %{"prepared" => true})
    assert {:ok, candidates} = Store.candidates(tenant, "codex", "gpt-5.5")
    assert length(candidates) == 3
    assert hd(candidates)["id"] == ready["id"]
    assert :ready = AccountPool.dispatch(config(tenant), fn _ -> :ready end)

    assert {:ok, _} = Store.update(tenant, Map.put(ready, "disabled", true), ready["version"])

    assert {:ok, _} =
             Store.update(tenant, Map.delete(cooling, "cooldown_until"), cooling["version"])

    assert :recovered = AccountPool.dispatch(config(tenant), fn _ -> :recovered end)
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

  test "an empty pool does not request a cooldown wait", %{tenant: tenant} do
    assert {:error, error} =
             AccountPool.dispatch(config(tenant), fn _ -> flunk("empty pool executed") end)

    refute Map.has_key?(error, "retry_after_ms")
  end

  test "execution retries stay bounded and stop after stream output", %{tenant: tenant} do
    for _ <- 1..4, do: account(tenant, %{"prepared" => true})
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    callback = fn _ ->
      Agent.update(counter, &(&1 + 1))
      {:error, %{"status" => 429}}
    end

    assert {:error, %{"status" => 429}} = AccountPool.dispatch(config(tenant), callback)
    assert Agent.get(counter, & &1) == 3

    assert {:error, %{"status" => 429}} =
             AccountPool.dispatch(config(tenant), callback, fn -> true end)

    assert Agent.get(counter, & &1) == 4
  end

  test "local worker capacity refusal does not rotate or cool healthy accounts", %{tenant: tenant} do
    accounts = for _ <- 1..3, do: account(tenant, %{"prepared" => true})
    owner = self()

    server(fn cmd ->
      send(owner, {:capacity_attempt, cmd["op"]})
      {:error, 429, "worker_busy"}
    end)

    assert {:error, %{"status" => 429, "retryable" => true}} =
             AccountPool.dispatch(config(tenant), fn opts ->
               SalixLlm.OpenAIResponses.complete(
                 [%{"role" => "user", "content" => "hello"}],
                 [],
                 opts
               )
             end)

    assert_received {:capacity_attempt, "/v1/responses"}
    refute_received {:capacity_attempt, _}

    for account <- accounts do
      assert {:ok, saved} = Store.get(tenant, account["id"])
      refute saved["cooldown_until"]
      assert saved["version"] == account["version"]
    end
  end

  test "a refresh rejected before execution keeps credentials available for retry", %{
    tenant: tenant
  } do
    accounts = for _ <- 1..3, do: account(tenant)
    owner = self()

    server(fn cmd ->
      send(owner, {:refresh_admission, cmd["op"]})
      {:error, 429, "worker_busy"}
    end)

    assert {:error, %{"status" => 429, "retryable" => true}} =
             AccountPool.dispatch(config(tenant), fn _ ->
               flunk("inference ran without preparation")
             end)

    assert_received {:refresh_admission, "/prepare"}
    refute_received {:refresh_admission, _}

    for account <- accounts do
      assert {:ok, saved} = Store.get(tenant, account["id"])
      assert saved["status"] == "active"
      assert saved["credentials"] == account["credentials"]
      refute saved["prepared"]
      refute saved["cooldown_until"]
    end
  end

  test "a rejected refresh cannot restore over a concurrent account edit", %{tenant: tenant} do
    account = account(tenant)

    server(fn _cmd ->
      {:ok, claimed} = Store.get(tenant, account["id"])
      {:ok, _} = Store.update(tenant, Map.put(claimed, "disabled", true), claimed["version"])
      {:error, 429, "worker_busy"}
    end)

    assert {:error, _} =
             AccountPool.dispatch(config(tenant), fn _ -> flunk("disabled account executed") end)

    assert {:ok, saved} = Store.get(tenant, account["id"])
    assert saved["disabled"]
    assert saved["status"] == "reauthorization_required"
  end

  test "an ambiguous refresh failure still requires reauthorization", %{tenant: tenant} do
    account = account(tenant)
    server(fn _ -> {:error, 503, "worker_down"} end)

    assert {:error, _} =
             AccountPool.dispatch(config(tenant), fn _ ->
               flunk("ambiguous credential executed")
             end)

    assert {:ok, saved} = Store.get(tenant, account["id"])
    assert saved["status"] == "reauthorization_required"
  end

  test "legacy import preserves identity, credentials and disabled state without overwriting", %{
    tenant: tenant
  } do
    id = Store.id()
    key = String.duplicate("k", 32)
    nonce = :crypto.strong_rand_bytes(12)

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
