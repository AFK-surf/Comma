defmodule CommaWeb.SalixClientTaskRunTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.CommaWeb", "Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Ecto.Query
  alias CommaWeb.SalixClient
  alias SalixIM.ConversationServer
  alias SalixStore.{AgentVMM, CodingSandboxes, Compute, Ids, Repo, StationTaskSessions}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    SalixAgent.TestSupport.configure_platform_models!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Task run"})

    on_exit(fn ->
      Repo.query!("DELETE FROM station_task_sessions WHERE group_id = $1", [group])
      environments = from(e in Compute.Environment, where: e.tenant_id == ^tenant, select: e.id)

      Repo.delete_all(
        from(w in Compute.Workload, where: w.environment_id in subquery(environments))
      )

      Repo.delete_all(
        from(a in Compute.Allocation, where: a.environment_id in subquery(environments))
      )

      Repo.delete_all(
        from(b in Compute.ProviderBinding, where: b.environment_id in subquery(environments))
      )

      Repo.delete_all(from(e in Compute.Environment, where: e.tenant_id == ^tenant))
      Repo.delete_all(from(r in AgentVMM.Registration, where: r.tenant_id == ^tenant))
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    %{
      tenant: tenant,
      group: group,
      workspace: %{"salix_tenant_id" => tenant, "default_group_id" => group}
    }
  end

  test "a coding sandbox reports its subscription runtime default rather than the platform model",
       f do
    conversation =
      task!(f, %{
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{"owner" => "acme", "name" => "api"}
      })

    {:ok, _workload} =
      CodingSandboxes.create(%{
        tenant_id: f.tenant,
        group_id: f.group,
        conversation_id: conversation,
        workspace: "comma:" <> f.group,
        repo: %{"owner" => "acme", "name" => "api"},
        start: %{"runtime" => "codex"}
      })

    assert {:ok, %{"place" => %{"kind" => "sandbox"}, "model" => model}} =
             SalixClient.task_run(f.workspace, conversation)

    assert model == %{
             "kind" => "runtime",
             "provider" => "codex",
             "name" => nil,
             "vendor" => "openai"
           }
  end

  test "a sandbox lent no workspace Codex account reports the platform model it runs Codex on",
       f do
    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      SalixAgent.TestSupport.platform_model_base_url(),
      "gpt-test",
      %{"protocol" => "responses"}
    )

    codex = %{"kind" => "runtime", "provider" => "codex", "name" => nil, "vendor" => "openai"}

    assert sandbox_model!(f, %{}) == %{"kind" => "platform"}

    account = codex_account!(f)
    assert sandbox_model!(f, %{}) == codex

    # A sandbox pinned to one account is lent only that account.
    assert sandbox_model!(f, %{account_id: "another-account"}) == %{"kind" => "platform"}
    assert sandbox_model!(f, %{account_id: account}) == codex
  end

  test "a sandbox Task's model is the one its station's Session runs now, and its station's models are listed while it is connected",
       f do
    conversation = task!(f, %{"runs_on" => %{"kind" => "sandbox"}})
    device = CodingSandboxes.device_id(conversation)

    {:ok, _workload} =
      CodingSandboxes.create(%{
        tenant_id: f.tenant,
        group_id: f.group,
        conversation_id: conversation,
        workspace: "comma:" <> f.group,
        requester: "usr_ada",
        start: %{"runtime" => "codex"}
      })

    # Switched to Claude Code: the Session taking part now was started with it.
    join!(f, conversation, device, %{"runtime" => "claude"})

    assert {:ok, %{"place" => place, "model" => %{"provider" => "claude"}}} =
             SalixClient.task_run(f.workspace, conversation)

    refute Map.has_key?(place, "repo")
    refute Map.has_key?(place, "task_models")
    # Not connected: nothing says it can show its screen.
    refute Map.has_key?(place, "screen_owner")

    {:ok, _transport, record} =
      SalixEnv.Registry.connect(
        to_string(node()),
        %{
          "tenant_id" => f.tenant,
          "group_id" => f.group,
          "device_id" => device,
          "connector_id" => CodingSandboxes.connector_id(conversation),
          "station_id" => String.duplicate("ab", 32),
          "capabilities" => %{
            "tasks" => 2,
            "task_models" => %{"claude" => ["claude-opus-5-5"], "codex" => []},
            "screen_view" => true
          }
        },
        transport_id: CodingSandboxes.transport_id(conversation)
      )

    # Its station says the models it runs, and that it can show its screen: to the Task's owner, whose client
    # alone offers it.
    assert {:ok, %{"place" => place}} = SalixClient.task_run(f.workspace, conversation)
    assert place["task_models"] == %{"claude" => ["claude-opus-5-5"], "codex" => []}
    assert place["screen_owner"] == "usr_ada"
    assert place["screen_device"] == device
    refute Map.has_key?(place, "screen_active")

    # A Session's browser is open on its display: there is something to show the owner now.
    {:ok, _} =
      SalixEnv.Registry.update_meta(record["connector_run_id"], fn meta ->
        put_in(meta, ["capabilities", "screen_active"], true)
      end)

    assert {:ok, %{"place" => %{"screen_active" => true, "screen_owner" => "usr_ada"}}} =
             SalixClient.task_run(f.workspace, conversation)
  end

  test "a sandbox Task the Router made shows its screen to the Comma user who asked for it, and no one else",
       f do
    connected = fn conversation ->
      device = CodingSandboxes.device_id(conversation)

      {:ok, _workload} =
        CodingSandboxes.create(%{
          tenant_id: f.tenant,
          group_id: f.group,
          conversation_id: conversation,
          workspace: "comma:" <> f.group,
          start: %{"runtime" => "codex"}
        })

      {:ok, _transport, _record} =
        SalixEnv.Registry.connect(
          to_string(node()),
          %{
            "tenant_id" => f.tenant,
            "group_id" => f.group,
            "device_id" => device,
            "connector_id" => CodingSandboxes.connector_id(conversation),
            "station_id" => String.duplicate("ab", 32),
            "capabilities" => %{"tasks" => 2, "screen_view" => true}
          },
          transport_id: CodingSandboxes.transport_id(conversation)
        )

      {:ok, %{"place" => place}} = SalixClient.task_run(f.workspace, conversation)
      place
    end

    # The server writes who asked as it makes the Task, where no other create may
    # (`SalixIM.SourceRefProtection`): this test makes it as that server does.
    contracts = SystemsRuntime.get_env(:salix_im, :protected_source_ref_contracts)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, contracts)
    end)

    asked_by = fn principal ->
      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, [])

      conversation =
        task!(f, %{
          "runs_on" => %{"kind" => "sandbox"},
          "source_refs" => %{"ifc_requester" => principal}
        })

      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, contracts)
      conversation
    end

    # No owner and no requester of the sandbox: the person whose message the Router made it from.
    assert connected.(asked_by.("comma_user|usr_ada"))["screen_owner"] == "usr_ada"
    # Asked for in a Slack chat, by no Comma user: no one is shown it.
    refute Map.has_key?(connected.(asked_by.("provider_user|conn_1|U1")), "screen_owner")
  end

  test "a dynamic Group VMM Station reports the platform default and keeps an explicit model",
       f do
    device = vmm_station!(f)
    conversation = task!(f)
    join!(f, conversation, device, %{"runtime" => "codex"})

    assert {:ok,
            %{
              "place" => %{"kind" => "station", "device_id" => ^device},
              "model" => %{"kind" => "platform"}
            }} =
             SalixClient.task_run(f.workspace, conversation)

    named = task!(f)
    join!(f, named, device, %{"runtime" => "codex", "model" => "named-codex-model"})

    assert {:ok,
            %{
              "model" => %{
                "kind" => "runtime",
                "provider" => "codex",
                "name" => "named-codex-model"
              }
            }} =
             SalixClient.task_run(f.workspace, named)
  end

  test "a physical Station keeps its runtime default", f do
    conversation = task!(f)
    join!(f, conversation, "physical-task-run", %{"runtime" => "codex"})

    assert {:ok, %{"place" => %{"kind" => "station"}, "model" => model}} =
             SalixClient.task_run(f.workspace, conversation)

    assert model == %{
             "kind" => "runtime",
             "provider" => "codex",
             "name" => nil,
             "vendor" => "openai"
           }
  end

  test "task_activity_participants returns [router, primary] with real agent names on a multi-session task",
       f do
    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(f.group), %{
        "tenant_id" => f.tenant,
        "group_id" => f.group,
        "name" => "Lead Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(f.tenant, f.group, %{
        "name" => "Code Worker",
        "role" => "worker"
      })

    conversation =
      task!(f, %{
        "created_by_agent_id" => router["agent_id"],
        "task_worker_agent_id" => worker["agent_id"]
      })

    {:ok, router_p} =
      ConversationServer.ensure_group_conversation_agent_participant(f.group, conversation, %{
        "actor_type" => "agent",
        "agent_id" => router["agent_id"],
        "agent_name" => "Lead Router",
        "role_label" => "delegator",
        "state" => "active",
        "payload" => %{"session_id" => router["router_session_id"]},
        "notification_filter" => %{"messages" => "all", "statuses" => "none"}
      })

    {:ok, primary_p} =
      ConversationServer.ensure_group_conversation_agent_participant(f.group, conversation, %{
        "actor_type" => "agent",
        "agent_id" => worker["agent_id"],
        "agent_name" => "Code Worker",
        "role_label" => "worker",
        "state" => "active",
        "payload" => %{"session_id" => Ids.new_session_id()},
        "notification_filter" => %{"messages" => "all", "statuses" => "none"}
      })

    {:ok, _secondary_p} =
      ConversationServer.ensure_group_conversation_agent_participant(f.group, conversation, %{
        "actor_type" => "agent",
        "agent_id" => worker["agent_id"],
        "agent_name" => "Code Worker",
        "role_label" => "worker",
        "target_key" => "reviewer",
        "state" => "active",
        "payload" => %{"session_id" => Ids.new_session_id()},
        "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"}
      })

    assert {:ok, participants} =
             SalixClient.task_activity_participants(f.workspace, conversation)

    assert Enum.map(participants, & &1["participant_id"]) == [
             router_p["participant_id"],
             primary_p["participant_id"]
           ]

    assert Enum.map(participants, & &1["name"]) == ["Lead Router", "Code Worker"]

    assert {:ok, worker_sessions} =
             SalixClient.task_worker_sessions(f.workspace, conversation)

    assert length(worker_sessions) == 2

    assert [
             %{
               "participant_id" => primary_pid,
               "slot" => "lead",
               "is_primary" => true
             },
             %{
               "participant_id" => secondary_pid,
               "slot" => "reviewer",
               "is_primary" => false
             }
           ] = worker_sessions

    assert primary_pid == primary_p["participant_id"]
    assert is_binary(secondary_pid) and secondary_pid != primary_pid
  end

  test "Coding.Usage.public_usage strips internal session IDs and preserves models map, partial, and unreadable slots" do
    raw = %{
      "modelCalls" => 15,
      "inputTokens" => 1500,
      "cachedTokens" => 300,
      "outputTokens" => 250,
      "model" => "claude-sonnet-4-6",
      "partial" => true,
      "models" => %{
        "claude-sonnet-4-6" => %{
          "modelCalls" => 10,
          "inputTokens" => 1000,
          "cachedTokens" => 200,
          "outputTokens" => 150
        },
        "gpt-5.3-codex" => %{
          "modelCalls" => 5,
          "inputTokens" => 500,
          "cachedTokens" => 100,
          "outputTokens" => 100
        }
      },
      "sessions" => %{
        "sess_sentinel_live_991" => %{"modelCalls" => 10}
      },
      "retired_sessions" => %{
        "sess_sentinel_retired_992" => %{"modelCalls" => 2}
      },
      "by_slot" => %{
        "lead" => %{
          "session" => "sess_sentinel_live_991",
          "agent_id" => "agt_secret_1",
          "is_primary" => true,
          "usage" => %{
            "modelCalls" => 10,
            "inputTokens" => 1000,
            "cachedTokens" => 200,
            "outputTokens" => 150,
            "model" => "claude-sonnet-4-6"
          }
        },
        "auditor" => %{
          "session" => "sess_sentinel_retired_992",
          "is_primary" => false,
          "unreadable" => true,
          "usage" => nil
        }
      }
    }

    public = CommaWeb.Coding.Usage.public_usage(raw)
    encoded = Jason.encode!(public)

    refute encoded =~ "sess_sentinel_live_991"
    refute encoded =~ "sess_sentinel_retired_992"
    refute encoded =~ "agt_secret_1"
    refute encoded =~ "retired_sessions"
    refute Map.has_key?(public, "sessions")

    assert public["modelCalls"] == 15
    assert public["partial"] == true
    assert Map.keys(public["models"]) |> Enum.sort() == ["claude-sonnet-4-6", "gpt-5.3-codex"]
    assert public["by_slot"]["lead"]["usage"]["modelCalls"] == 10
    assert public["by_slot"]["auditor"]["usage"] == nil
    assert public["by_slot"]["auditor"]["unreadable"] == true
  end

  test "pick_primary_station_row selects primary deterministically regardless of station row order" do
    lead_row = %{
      session: "ses_lead",
      start: %{
        "participant_id" => "ptc_lead",
        "slot" => "lead",
        "runtime" => "claude",
        "model" => "claude-sonnet-4-6"
      }
    }

    reviewer_row = %{
      session: "ses_reviewer",
      start: %{
        "participant_id" => "ptc_reviewer",
        "slot" => "reviewer",
        "runtime" => "codex",
        "model" => "gpt-5.3-codex"
      }
    }

    primary_info = %{"participant_id" => "ptc_lead", "session_slot" => "lead"}

    assert SalixClient.pick_primary_station_row([reviewer_row, lead_row], primary_info) ==
             lead_row

    assert SalixClient.pick_primary_station_row([lead_row, reviewer_row], primary_info) ==
             lead_row
  end

  defp task!(f, attrs \\ %{}) do
    {:ok, conversation} =
      ConversationServer.create_group_conversation(
        f.group,
        Map.merge(%{"kind" => "agent_task", "title" => "Model read"}, attrs)
      )

    conversation["conversation_id"]
  end

  defp sandbox_model!(f, attrs) do
    conversation = task!(f, %{"runs_on" => %{"kind" => "sandbox"}})

    {:ok, _workload} =
      CodingSandboxes.create(
        Map.merge(
          %{
            tenant_id: f.tenant,
            group_id: f.group,
            conversation_id: conversation,
            workspace: "comma:" <> f.group,
            start: %{"runtime" => "codex"}
          },
          attrs
        )
      )

    assert {:ok, %{"place" => %{"kind" => "sandbox"}, "model" => model}} =
             SalixClient.task_run(f.workspace, conversation)

    model
  end

  defp codex_account!(f) do
    id = "codex-" <> SalixAgent.SubscriptionStore.id()
    {:ok, sealed} = SalixAgent.SubscriptionStore.seal(f.tenant, id, %{"access_token" => "a"})

    {:ok, _} =
      SalixAgent.SubscriptionStore.create(f.tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "disabled" => false,
        "credentials" => sealed
      })

    on_exit(fn ->
      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE id=$1", [id])
    end)

    id
  end

  test "pick_primary_station_row selects untagged legacy lead over explicit reviewer and returns nil for secondary-only rows" do
    explicit_reviewer = %{
      device_id: "dev_a",
      session: "sess_rev",
      start: %{"slot" => "reviewer", "is_primary" => false, "model" => "gpt-6.2-sol"}
    }

    untagged_lead = %{
      device_id: "dev_b",
      session: "sess_lead",
      start: %{"model" => "claude-opus-5"}
    }

    assert SalixClient.pick_primary_station_row([explicit_reviewer, untagged_lead], nil) ==
             untagged_lead

    assert SalixClient.pick_primary_station_row([untagged_lead, explicit_reviewer], nil) ==
             untagged_lead

    assert SalixClient.pick_primary_station_row([explicit_reviewer], nil) == nil
    assert SalixClient.select_primary_station_row("grp_any", "cnv_any", []) == nil
  end

  test "task_run returns station place with nil model when only an explicit secondary station row exists",
       f do
    conversation = task!(f)

    join!(f, conversation, "physical-secondary-only", %{
      "slot" => "reviewer",
      "is_primary" => false,
      "runtime" => "codex",
      "model" => "gpt-6.2-sol"
    })

    assert {:ok,
            %{
              "place" => %{"kind" => "station", "device_id" => "physical-secondary-only"},
              "model" => nil
            }} = SalixClient.task_run(f.workspace, conversation)
  end

  defp join!(f, conversation, device, start) do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: f.tenant,
        group_id: f.group,
        conversation_id: conversation,
        device_id: device,
        session: "session-" <> conversation,
        agent_id: Ids.new_agent_id(f.group),
        start: start
      })
  end

  defp vmm_station!(f) do
    id = "host-task-run-" <> f.group

    {:ok, _registration} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: id,
        tenant_id: f.tenant,
        group_id: f.group,
        device_id: "host-device-" <> f.group,
        credential: String.duplicate("e", 32)
      })

    {:ok, pool} = Compute.ensure_managed_default_pool(f.tenant, "agent_vmm")

    {:ok, environment} =
      Compute.create_environment(%{
        id: "env-" <> f.group,
        tenant_id: f.tenant,
        owner_type: "project",
        owner_id: "project-" <> f.group,
        pool_id: pool.id
      })

    {:ok, _binding} =
      Compute.create_provider_binding(%{
        id: "binding-" <> f.group,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: id
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
      set: [status: "ready", desired_enabled: true]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration(id, "test", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    {:ok, _workload} = Compute.ensure_group_station(f.tenant, f.group)
    {:ok, record} = Compute.group_station(f.tenant, f.group)
    record["device_id"]
  end
end
