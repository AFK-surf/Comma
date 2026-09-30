defmodule BridgeForTeams.TriageContextTest do
  @moduledoc """
  Freeze contract for the read-only BFT Triage context port: sealed source
  authority, product project/member facts, the Slack context normalization, and
  the fresh answered recheck.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Agents, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.Schema.{Agent, Project, ProjectMembership, User}

  defmodule ProductSource do
    def resolve_connect(authority, _opts) do
      send(self(), {:product_source_authority, authority})

      {:ok,
       %{
         "connect_id" => "imc-native-triage",
         "connect_generation" => "generation-7",
         "workspace_id" => "T1",
         "approved_channel_id" => "C1",
         "group_id" => "group-atlas",
         "provider" => "slack"
       }}
    end

    def load_product(_connect, opts) do
      send(self(), {:batch_knowledge_query, opts[:knowledge_query]})
      send(self(), {:trajectory_target, opts[:trajectory_target]})

      {:ok,
       %{
         project: %Project{
           id: "project-atlas",
           name: "Atlas",
           slug: "atlas",
           status: "active",
           salix_group_id: "group-atlas",
           updated_at: ~U[2026-08-14 04:20:00Z]
         },
         members: [
           %ProjectMembership{
             id: "membership-lin",
             role: "admin",
             user_id: "member-lin",
             user: %User{id: "member-lin", name: "Lin", email: "lin@example.test"}
           }
         ],
         member_roster: %{
           completeness: :complete,
           truncated: false,
           limit: 25,
           returned_count: 1
         },
         meetings: [
           %{
             "meeting_id" => "meeting-weekly-7",
             "status" => "done",
             "title" => "Atlas Weekly",
             "start_at" => 1_776_000_000,
             "summary" => %{
               "key_points" => ["Login incident follow-up stays with Lin."],
               "action_items" => [
                 %{
                   "description" => "Close the login incident follow-up",
                   "owner" => "Lin",
                   "deadline" => "2026-08-18"
                 }
               ]
             }
           }
         ]
       }}
    end
  end

  defmodule TaskTrajectoryProductSource do
    defdelegate resolve_connect(authority, opts), to: ProductSource

    def load_product(connect, opts) do
      {:ok, product} = ProductSource.load_product(connect, opts)
      {:ok, Map.put(product, :trajectory, Process.get(:task_trajectory))}
    end
  end

  defmodule SealedEmptyMeetingSource do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def triage_knowledge_context(_project, _group, _agent, opts) do
      send(self(), {:knowledge_options, opts})
      {:ok, %{items: [%{source_ref: "triage-context://due-reminder"}], complete: true}}
    end

    def list_group_meetings_bounded(_group_id, _opts) do
      {:ok, %{"meetings" => [], "completeness" => "complete", "truncated" => false}}
    end
  end

  defmodule PaginatedWorkerSource do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def page_group_agents(_tenant, _group, opts) do
      cursor = opts[:cursor]
      send(self(), {:worker_page, cursor, opts[:limit]})
      Map.fetch!(Process.get(:worker_pages), cursor)
    end

    def triage_knowledge_context(_, _, _, _), do: {:error, :unavailable}
    def list_group_meetings_bounded(_, _), do: {:error, :meeting_source_unsealed}
  end

  defmodule UnsealedMeetingSource do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def triage_knowledge_context(_project, _group, _agent, _opts),
      do: {:error, :unavailable}

    def list_group_meetings_bounded(_group_id, _opts),
      do: {:error, :meeting_source_unsealed}
  end

  defmodule GroundingProductSource do
    def resolve_connect(authority, opts) do
      {:ok, connect} = ProductSource.resolve_connect(authority, opts)

      {:ok,
       Map.merge(connect, %{
         "tenant_id" => "tenant-atlas",
         "inbound_agent_id" => "salix-agent-atlas",
         "app_id" => "A1",
         "installation_generation" => "installation-generation-4"
       })}
    end

    def load_product(connect, opts) do
      {:ok, product} = ProductSource.load_product(connect, opts)
      project = %{product.project | org_id: "org-atlas"}

      agent = %Agent{
        id: "agent-atlas",
        project_id: project.id,
        salix_agent_id: "salix-agent-atlas",
        role: "router",
        salix: %{
          "name" => "Atlas Router",
          "status" => "active",
          "agent_id" => "salix-agent-atlas"
        }
      }

      {:ok, %{product | project: project} |> Map.put(:agent, agent)}
    end

    def read_sourced_context_authority(project, connect, authority, _opts) do
      {:ok,
       %{
         tenant_id: connect["tenant_id"],
         group_id: project.salix_group_id,
         connect_id: connect["connect_id"],
         connect_generation: connect["installation_generation"],
         workspace_id: connect["workspace_id"],
         app_id: "A1",
         channel: %{
           id: authority["channel_id"],
           is_member: true,
           name: "triage-room",
           visibility: "public",
           authority_revision: String.duplicate("a", 64)
         }
       }}
    end
  end

  defmodule IneligibleGroundingProductSource do
    defdelegate resolve_connect(authority, opts), to: GroundingProductSource
    defdelegate load_product(connect, opts), to: GroundingProductSource

    def read_sourced_context_authority(_project, _connect, _authority, _opts),
      do: {:error, :channel_ineligible}
  end

  defmodule DriftedGroundingProductSource do
    defdelegate resolve_connect(authority, opts), to: GroundingProductSource
    defdelegate load_product(connect, opts), to: GroundingProductSource

    def read_sourced_context_authority(project, connect, authority, opts) do
      {:ok, current} =
        GroundingProductSource.read_sourced_context_authority(
          project,
          connect,
          authority,
          opts
        )

      {:ok, %{current | app_id: "A-other-installation"}}
    end
  end

  defmodule SourcedContextGrounder do
    def ground_for_triage(agent_id, question, capability) do
      send(self(), {:sourced_context_grounding, agent_id, question, capability})

      {:ok,
       %{
         status: :resolved,
         entities: [],
         facts: [
           %{
             id: "ctxfact_reconnect",
             kind: :decision,
             content: "Reconnect creates a fresh import run",
             about: [],
             source_refs: [
               %{type: "sourced_context_publication", ref: "publication-7"},
               %{type: "sourced_context_object", ref: "object-9"}
             ]
           }
         ]
       }}
    end
  end

  defmodule TruncatedProductSource do
    def resolve_connect(authority, opts), do: ProductSource.resolve_connect(authority, opts)

    def load_product(connect, opts) do
      {:ok, product} = ProductSource.load_product(connect, opts)

      {:ok,
       Map.put(product, :member_roster, %{
         completeness: :truncated,
         truncated: true,
         limit: 25,
         returned_count: length(product.members)
       })}
    end
  end

  defmodule MixedMeetingsProductSource do
    def resolve_connect(authority, opts), do: ProductSource.resolve_connect(authority, opts)

    def load_product(connect, opts) do
      {:ok, product} = ProductSource.load_product(connect, opts)

      meetings = [
        %{
          "meeting_id" => "meeting-in-progress",
          "status" => "active",
          "title" => "Atlas Standup",
          "summary" => nil
        },
        %{
          "meeting_id" => "meeting-weekly-7",
          "status" => "done",
          "title" => "Atlas Weekly",
          "summary" => %{
            "key_points" => ["Login incident follow-up stays with Lin."],
            "action_items" => []
          }
        },
        %{
          "meeting_id" => "meeting-blank-summary",
          "status" => "done",
          "title" => "Atlas Retro",
          "summary" => %{"key_points" => ["", "   "], "action_items" => []}
        }
      ]

      {:ok, %{product | meetings: meetings}}
    end
  end

  defmodule ThreadReader do
    def read(authority, connect, opts) do
      send(opts[:test_pid], {:thread_read, authority, connect})

      {:ok,
       %{
         "checked_at" => "2026-08-14T04:30:00Z",
         "messages" => [
           %{
             "ts" => "200.001",
             "user" => "member-lin",
             "actor_kind" => "human",
             "text" => "Login incident follow-up stays with Lin."
           },
           %{
             "ts" => "200.002",
             "user" => "member-peng",
             "actor_kind" => "human",
             "text" => "Atlas 登录事故的负责人是谁？"
           },
           # Our OWN bot's placeholder. It is an agent message like any other,
           # and it is still not an answer: the recheck excludes this connect's
           # own posts by id, so a "Thinking…" of ours can never settle the
           # skip terminal on our behalf.
           %{
             "ts" => "200.003",
             "user" => "U1",
             "actor_kind" => "agent",
             "text" => "Thinking…"
           }
         ]
       }}
    end
  end

  describe "production investigation Worker pagination" do
    setup do
      previous = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, SealedEmptyMeetingSource)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
          else: Application.delete_env(:bridge_for_teams_core, :salix_client)
      end)

      suffix = System.unique_integer([:positive])
      {:ok, org} = Orgs.create_org(%{name: "Worker pages", slug: "worker-pages-#{suffix}"})
      {:ok, project} = Projects.create_project(org.id, %{name: "Workers", slug: "workers"})
      fixture = BridgeForTeams.TestSupport.CanonicalAgentClient

      {:ok, router} =
        fixture.create_provisioned_agent(project.id, %{"name" => "Router", "role" => "router"})

      {:ok, worker} =
        fixture.create_provisioned_agent(project.id, %{
          "name" => "Investigator",
          "role" => "worker"
        })

      Application.put_env(:bridge_for_teams_core, :salix_client, PaginatedWorkerSource)

      %{
        connect: %{
          "group_id" => project.salix_group_id,
          "inbound_agent_id" => router.salix_agent_id
        },
        worker: worker
      }
    end

    test "keeps a Worker when a filtered storage page has a continuation", %{
      connect: connect,
      worker: worker
    } do
      Process.put(:worker_pages, %{
        nil => {:ok, %{items: [worker.salix], next_cursor: "page-2"}},
        "page-2" => {:ok, %{items: [], next_cursor: nil}}
      })

      assert {:ok, product} = BridgeForTeams.TriageContext.ProductSource.load_product(connect, [])

      assert Enum.map(product.investigation_workers, & &1.salix_agent_id) == [
               worker.salix_agent_id
             ]

      assert_receive {:worker_page, nil, 64}
      assert_receive {:worker_page, "page-2", 64}
      refute_receive {:worker_page, _, _}
    end

    test "finds a later Worker when the roster completes on the fourth page", %{
      connect: connect,
      worker: worker
    } do
      Process.put(:worker_pages, %{
        nil => {:ok, %{items: [], next_cursor: "page-2"}},
        "page-2" => {:ok, %{items: [worker.salix], next_cursor: "page-3"}},
        "page-3" => {:ok, %{items: [], next_cursor: "page-4"}},
        "page-4" => {:ok, %{items: [], next_cursor: nil}}
      })

      assert {:ok, product} = BridgeForTeams.TriageContext.ProductSource.load_product(connect, [])

      assert Enum.map(product.investigation_workers, & &1.salix_agent_id) == [
               worker.salix_agent_id
             ]

      for cursor <- [nil, "page-2", "page-3", "page-4"],
          do: assert_receive({:worker_page, ^cursor, 64})

      refute_receive {:worker_page, _, _}
    end

    test "does not use a partial roster when a later page fails", %{
      connect: connect,
      worker: worker
    } do
      Process.put(:worker_pages, %{
        nil => {:ok, %{items: [worker.salix], next_cursor: "page-2"}},
        "page-2" => {:error, :unavailable}
      })

      assert {:ok, product} = BridgeForTeams.TriageContext.ProductSource.load_product(connect, [])
      assert product.investigation_workers == []
      assert_receive {:worker_page, "page-2", 64}
    end

    test "stops after four pages without using the incomplete roster", %{
      connect: connect,
      worker: worker
    } do
      Process.put(:worker_pages, %{
        nil => {:ok, %{items: [worker.salix], next_cursor: "page-2"}},
        "page-2" => {:ok, %{items: [], next_cursor: "page-3"}},
        "page-3" => {:ok, %{items: [], next_cursor: "page-4"}},
        "page-4" => {:ok, %{items: [], next_cursor: "page-5"}}
      })

      assert {:ok, product} = BridgeForTeams.TriageContext.ProductSource.load_product(connect, [])
      assert product.investigation_workers == []

      for cursor <- [nil, "page-2", "page-3", "page-4"],
          do: assert_receive({:worker_page, ^cursor, 64})

      refute_receive {:worker_page, _, _}
    end
  end

  test "production product source carries an incomplete bounded roster instead of failing" do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      SealedEmptyMeetingSource
    )

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Roster #{suffix}", slug: "roster-#{suffix}"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Roster #{suffix}", slug: "roster-#{suffix}"})

    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "router", "role" => "router"})

    for ordinal <- 1..26 do
      {:ok, member} = Accounts.create_user(%{email: "roster-#{suffix}-#{ordinal}@example.com"})
      {:ok, _membership} = Memberships.put_project_member(project.id, member.id, "user")
    end

    assert {:ok, product} =
             BridgeForTeams.TriageContext.ProductSource.load_product(
               %{
                 "group_id" => project.salix_group_id,
                 "inbound_agent_id" => agent.salix_agent_id
               },
               knowledge_query: "好",
               recheck_context_refs: ["triage-context://due-reminder"]
             )

    assert length(product.members) == 25
    assert_receive {:knowledge_options, knowledge_opts}
    assert knowledge_opts[:entry_ids] == ["due-reminder"]
    assert knowledge_opts[:query] == "好"
    assert [%{current_wakeup: true}] = product.retained_context

    assert product.member_roster == %{
             completeness: :truncated,
             truncated: true,
             limit: 25,
             returned_count: 25
           }
  end

  test "production product source keeps Slack Triage available while Meetings is not ready" do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, UnsealedMeetingSource)

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{name: "Meeting optional #{suffix}", slug: "meeting-optional-#{suffix}"})

    {:ok, project} =
      Projects.create_project(org.id, %{
        name: "Meeting optional #{suffix}",
        slug: "meeting-optional-#{suffix}"
      })

    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "router", "role" => "router"})

    assert {:ok, product} =
             BridgeForTeams.TriageContext.ProductSource.load_product(
               %{
                 "group_id" => project.salix_group_id,
                 "inbound_agent_id" => agent.salix_agent_id
               },
               []
             )

    assert product.meetings == []
    assert product.meeting_source_status == :not_ready
  end

  defmodule ConfiguredThreadReader do
    def read(_authority, _connect, opts) do
      {:ok,
       %{
         "checked_at" => "2026-08-14T04:30:00Z",
         "messages" => Keyword.fetch!(opts, :messages)
       }}
    end
  end

  defmodule StaleProductSource do
    def resolve_connect(_authority, opts) do
      send(opts[:test_pid], :current_connect_read)

      {:ok,
       %{
         "connect_id" => "imc-native-triage",
         "connect_generation" => "generation-stale",
         "workspace_id" => "T-other",
         "group_id" => "group-atlas",
         "provider" => "slack"
       }}
    end

    def load_product(_connect, opts) do
      send(opts[:test_pid], :forbidden_project_read)
      send(opts[:test_pid], :forbidden_memberships_read)
      send(opts[:test_pid], :forbidden_meetings_read)
      raise "stale receipt must not read product facts"
    end
  end

  defmodule ChannelDriftProductSource do
    def resolve_connect(_authority, opts) do
      send(opts[:test_pid], :current_connect_read)

      {:ok,
       %{
         "connect_id" => "imc-native-triage",
         "connect_generation" => "generation-7",
         "workspace_id" => "T1",
         "approved_channel_id" => "C-new",
         "group_id" => "group-atlas",
         "provider" => "slack"
       }}
    end

    def load_product(_connect, opts) do
      send(opts[:test_pid], :forbidden_project_read)
      send(opts[:test_pid], :forbidden_memberships_read)
      send(opts[:test_pid], :forbidden_meetings_read)
      raise "stale channel authority must not read product facts"
    end
  end

  defmodule ForbiddenThreadReader do
    def read(_authority, _connect, opts) do
      send(opts[:test_pid], :forbidden_thread_read)
      raise "stale connect authority must fail before Slack or Memory assembly"
    end
  end

  defmodule InjectedActiveConnectReader do
    def find_active_im_connect_by_id(_connect_id),
      do: raise("injected active-connect reader was called")
  end

  test "identity allowlist ignores a substituted active-connect reader" do
    previous = Application.get_env(:bridge_for_teams_core, :triage_active_connect_reader)

    Application.put_env(
      :bridge_for_teams_core,
      :triage_active_connect_reader,
      InjectedActiveConnectReader
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :triage_active_connect_reader, previous),
        else: Application.delete_env(:bridge_for_teams_core, :triage_active_connect_reader)
    end)

    sha = String.duplicate("a", 64)

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "historical_thread_reenactment",
      "source_authority" => %{
        "connect_id" => "imc-identity",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" => [
        %{
          "message_ts" => "200.002",
          "endpoint_provenance" => %{
            "schema" => "comma.slack-endpoint-provenance.v1",
            "captured_at_ms" => 1,
            "callback_api_app_id" => "A1",
            "fast_path_bot_user_id" => "U1",
            "endpoint_revision_sha256" => sha
          }
        }
      ]
    }

    allowlist = %{
      "schema" => "comma.triage-identity-selector.v2",
      "provider" => "slack",
      "operation" => "clickhouse.thread_current",
      "tenant_id" => "tenant-1",
      "group_id" => "group-1",
      "connect_id" => "imc-identity",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "approved_channel_id" => "C1",
      "root_ts" => "200.001",
      "inbound_agent_id" => "agent-1",
      "app_id" => "A1",
      "bot_user_id" => "U1",
      "bot_id" => "B1",
      "endpoint_revision_sha256" => sha,
      "project_id" => "project-1",
      "project_status" => "active",
      "agent_id" => "agent-1",
      "agent_role" => "router",
      "agent_name" => "BFT",
      "self_agent_identity_revision_sha256" => sha,
      "source_origin_sha256" => sha
    }

    assert {:error, :not_found} =
             BridgeForTeams.TriageContext.freeze(input,
               identity_allowlist: allowlist,
               identity_fence_handle: identity_fence_handle()
             )
  end

  test "identity allowlist rejects current-connect selector drift before Product reads" do
    n = System.unique_integer([:positive])
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    inbound_agent_id = SalixStore.Ids.new_agent_id(group_id)
    connect_id = "imc-identity-selector-#{n}"

    connect_generation = SalixStore.ULID.generate()

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "connect_generation" => connect_generation,
      "workspace_id" => "T#{n}",
      "approved_channel_id" => "C#{n}",
      "inbound_agent_id" => inbound_agent_id,
      "app_id" => "A#{n}",
      "bot_user_id" => "U#{n}",
      "bot_id" => "B#{n}",
      "bot_token" => "xoxb-test-only",
      "oauth_completed_at" => 1,
      "triage_enabled" => true,
      "deleted_at" => nil,
      "disabled_at" => nil
    }

    {:ok, endpoint_revision} = SalixIM.Triage.IdentityContract.endpoint_revision_sha256(connect)

    assert {:ok, _group} =
             SalixStore.CasRecord.create(SalixStore.Keys.ctl_group(group_id), %{
               "tenant_id" => connect["tenant_id"],
               "group_id" => group_id,
               "router_agent_id" => connect["inbound_agent_id"],
               "router_conversation_id" => "conv-#{group_id}"
             })

    {:ok, _record} =
      SalixStore.CasRecord.create(SalixStore.Keys.ctl_im_connect(group_id, connect_id), connect)

    assert {:ok, _channel} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => connect["tenant_id"],
               "group_id" => group_id,
               "connect_id" => connect_id,
               "channel_id" => connect["approved_channel_id"],
               "installation_generation" => connect_generation,
               "workspace_id" => connect["workspace_id"],
               "channel_name" => "identity-selector"
             })

    assert {:ok, current_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               connect["tenant_id"],
               group_id,
               connect_id,
               connect["approved_channel_id"]
             )

    previous = Application.get_env(:bridge_for_teams_core, :triage_active_connect_reader)

    Application.put_env(
      :bridge_for_teams_core,
      :triage_active_connect_reader,
      SalixIM.ProviderConnects
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :triage_active_connect_reader, previous),
        else: Application.delete_env(:bridge_for_teams_core, :triage_active_connect_reader)
    end)

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "historical_thread_reenactment",
      "source_authority" => %{
        "connect_id" => connect_id,
        "connect_generation" => current_authority["connect_generation"],
        "workspace_id" => connect["workspace_id"],
        "channel_id" => connect["approved_channel_id"],
        "thread_ts" => "200.001"
      },
      "events" => [
        %{
          "message_ts" => "200.002",
          "endpoint_provenance" => %{
            "schema" => "comma.slack-endpoint-provenance.v1",
            "captured_at_ms" => 1,
            "callback_api_app_id" => connect["app_id"],
            "fast_path_bot_user_id" => connect["bot_user_id"],
            "endpoint_revision_sha256" => endpoint_revision
          }
        }
      ]
    }

    sha = String.duplicate("a", 64)

    allowlist = %{
      "schema" => "comma.triage-identity-selector.v2",
      "provider" => "slack",
      "operation" => "clickhouse.thread_current",
      "tenant_id" => connect["tenant_id"],
      "group_id" => group_id,
      "connect_id" => connect_id,
      "connect_generation" => current_authority["connect_generation"],
      "workspace_id" => "T-drifted",
      "approved_channel_id" => connect["approved_channel_id"],
      "root_ts" => "200.001",
      "inbound_agent_id" => connect["inbound_agent_id"],
      "app_id" => connect["app_id"],
      "bot_user_id" => connect["bot_user_id"],
      "bot_id" => connect["bot_id"],
      "endpoint_revision_sha256" => endpoint_revision,
      "project_id" => "missing-project",
      "project_status" => "active",
      "agent_id" => connect["inbound_agent_id"],
      "agent_role" => "router",
      "agent_name" => "BFT",
      "self_agent_identity_revision_sha256" => sha,
      "source_origin_sha256" => sha
    }

    assert {:error, :identity_allowlist_connect_drift} =
             BridgeForTeams.TriageContext.freeze(input,
               identity_allowlist: allowlist,
               identity_fence_handle: identity_fence_handle()
             )
  end

  test "batch knowledge lookup retains the topic before repeated short feedback" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" =>
        Enum.with_index(["电视播放调查", "好", "好", "还是不行"], 2)
        |> Enum.map(fn {text, index} ->
          %{
            "event_id" => "Ev-#{index}",
            "message_ts" => "200.00#{index}",
            "actor_id" => "member-peng",
            "text" => text
          }
        end)
    }

    assert {:ok, _} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: ProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive {:batch_knowledge_query, query}
    assert query =~ "电视播放调查"
    assert query =~ "还是不行"
    assert length(Regex.scan(~r/好/u, query)) == 1

    large_events =
      Enum.map(1..8, fn index ->
        Map.merge(hd(input["events"]), %{
          "event_id" => "Ev-large-#{index}",
          "message_ts" => "200.#{100 + index}",
          "text" => "#{index}" <> String.duplicate("🧪", 600)
        })
      end)

    assert {:ok, _} =
             BridgeForTeams.TriageContext.freeze(
               %{input | "events" => large_events ++ [List.last(input["events"])]},
               product_source: ProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive {:batch_knowledge_query, bounded_query}
    assert String.valid?(bounded_query)
    assert byte_size(bounded_query) <= 2_048
    assert String.starts_with?(bounded_query, "还是不行")
  end

  test "channel-batch history selects the latest physical reply thread before reading old Tasks" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "__channel__",
      "scope_kind" => "channel"
    }

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-last",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "What did the investigation find?",
          "bucket" => %{"thread_ts" => "200.001"}
        },
        %{
          "event_id" => "Ev-earlier",
          "message_ts" => "199.002",
          "actor_id" => "member-peng",
          "text" => "Another topic",
          "bucket" => %{"thread_ts" => "199.001"}
        }
      ]
    }

    assert {:ok, _frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: ProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive {:trajectory_target, target}
    assert target == authority |> Map.put("thread_ts", "200.001") |> Map.delete("scope_kind")
  end

  test "a follow-up freezes attributed recent Task messages with an explicit partial-history boundary" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "200.001"
    }

    task_context = %{
      availability: "available",
      conversation_id: "cnv1_1234567890",
      task_status: "ready_for_review",
      history_window: "latest_three_messages",
      recent_messages: [
        %{
          agent_id: "worker-lin",
          message_id: "message-result",
          text_excerpt: "The trace confirms the destination was rejected; no send succeeded.",
          excerpt_only: true,
          has_other_content: false
        }
      ]
    }

    Process.put(:task_trajectory, %{
      target: authority,
      status: "available",
      outcomes: [
        %{
          event_ref: "prior-execution",
          state: "applied",
          communication: nil,
          companion_reaction: nil,
          effect: nil,
          companion_effect: nil,
          updated_at_ms: 1,
          delegations: [
            %{
              index: 0,
              status: "routed",
              task: "Check the missing delivery",
              task_context: task_context
            }
          ]
        }
      ]
    })

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-follow-up",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "What did the investigation find?"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: TaskTrajectoryProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    history =
      Enum.find(frozen["team_project_memory"]["facts"], &(&1["kind"] == "prior_triage_work"))

    assert history["text"] =~
             "The trace confirms the destination was rejected; no send succeeded."

    assert history["text"] =~ "worker-lin"
    assert history["text"] =~ "message-result"
    assert history["text"] =~ "latest_three_messages"
    assert history["text"] =~ "excerpt_only"
    assert history["text"] =~ "not verified source facts"
    refute history["text"] =~ ~s("delivered":true)
  end

  test "freezes durable Slack authority with product project/member and sourced meeting facts" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "200.001"
    }

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-atlas-question",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Atlas 登录事故的负责人是谁？"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: ProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive {:thread_read, ^authority, %{"group_id" => "group-atlas"}}, 100

    assert frozen["slack_context"] == %{
             "expression_context" => %{
               "schema" => "comma.triage-expression-context.v1",
               "mode" => "project",
               "allow_reactions" => true,
               "allowed_emojis" =>
                 ~w(+1 clap eyes heart joy pray raised_hands sparkles tada thinking_face),
               "catalog" => %{
                 "status" => "unavailable",
                 "complete?" => false,
                 "custom_emojis" => []
               },
               "observed_reactions" => [],
               "guidance" =>
                 "Use reactions for lightweight acknowledgement. Prefer a fitting workspace custom emoji when its name or observed use makes the meaning clear; do not guess opaque emoji names."
             },
             "messages" => [
               %{
                 "actor_id" => "member-lin",
                 "actor_kind" => "human",
                 "message_ts" => "200.001",
                 "file_attachments" => %{"items" => [], "total_count" => 0, "truncated" => false},
                 "reactions" => [],
                 "text" => "Login incident follow-up stays with Lin.",
                 "source_ref" => "slack://T1/C1/200.001/200.001"
               },
               %{
                 "actor_id" => "member-peng",
                 "actor_kind" => "human",
                 "message_ts" => "200.002",
                 "file_attachments" => %{"items" => [], "total_count" => 0, "truncated" => false},
                 "reactions" => [],
                 "text" => "Atlas 登录事故的负责人是谁？",
                 "source_ref" => "slack://T1/C1/200.001/200.002"
               },
               %{
                 "actor_id" => "U1",
                 "actor_kind" => "agent",
                 "message_ts" => "200.003",
                 "file_attachments" => %{"items" => [], "total_count" => 0, "truncated" => false},
                 "reactions" => [],
                 "text" => "Thinking…",
                 "source_ref" => "slack://T1/C1/200.001/200.003"
               }
             ],
             "source_refs" => [
               "slack://T1/C1/200.001/200.001",
               "slack://T1/C1/200.001/200.002",
               "slack://T1/C1/200.001/200.003"
             ]
           }

    assert get_in(frozen, ["team_project_memory", "project", "key"]) == "atlas"

    assert get_in(frozen, ["team_project_memory", "member_roster"]) == %{
             "completeness" => "complete",
             "truncated" => false,
             "limit" => 25,
             "returned_count" => 1
           }

    assert get_in(frozen, ["team_project_memory", "members"]) == [
             %{
               "key" => "member-lin",
               "display_name" => "Lin",
               "rbac_role" => "admin",
               "source_ref" => "bft://projects/project-atlas/members/member-lin"
             }
           ]

    assert Enum.map(get_in(frozen, ["team_project_memory", "facts"]), & &1["kind"]) == [
             "meeting_key_point",
             "meeting_action_item"
           ]

    assert get_in(frozen, ["team_project_memory", "facts", Access.at(1)]) == %{
             "deadline" => "2026-08-18",
             "kind" => "meeting_action_item",
             "owner" => "Lin",
             "text" => "Close the login incident follow-up",
             "source_ref" => "meeting://meeting-weekly-7/action-item/0"
           }

    assert frozen["answered_recheck"] == %{
             "answered" => false,
             "checked_at" => "2026-08-14T04:30:00Z",
             "source_refs" => [
               "slack://T1/C1/200.001/200.001",
               "slack://T1/C1/200.001/200.002",
               "slack://T1/C1/200.001/200.003"
             ]
           }
  end

  test "adds authorized published Slack context to the frozen Triage memory" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "200.001"
    }

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_mode" => "callback",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-reconnect-question",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Atlas reconnect 应该怎么处理？"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: GroundingProductSource,
               thread_reader: {ThreadReader, test_pid: self()},
               sourced_context_grounder: SourcedContextGrounder
             )

    assert_receive {:sourced_context_grounding, "agent-atlas", question, capability}
    assert question == "Atlas reconnect 应该怎么处理？"
    assert capability["org_id"] == "org-atlas"
    assert capability["project_id"] == "project-atlas"
    assert get_in(capability, ["caller", "salix_agent_id"]) == "salix-agent-atlas"
    assert get_in(capability, ["audience", "channel_id"]) == "C1"
    assert get_in(capability, ["audience", "scope"]) == "project-public-channels:v1"

    assert get_in(capability, ["audience", "connect_generation"]) ==
             "installation-generation-4"

    assert get_in(capability, ["audience", "triage_authority_generation"]) == "generation-7"
    assert get_in(capability, ["audience", "app_id"]) == "A1"
    assert get_in(capability, ["audience", "visibility"]) == "public"
    assert get_in(capability, ["audience", "shared"]) == false

    assert get_in(capability, ["audience", "authority_revision"]) ==
             String.duplicate("a", 64)

    imported_fact =
      frozen["team_project_memory"]["facts"]
      |> Enum.find(&(&1["kind"] == "slack_history_decision"))

    assert imported_fact["text"] == "Reconnect creates a fresh import run"

    assert imported_fact["source_ref"] ==
             "sourced-context://publications/publication-7/facts/ctxfact_reconnect"

    assert imported_fact["source_ref"] in frozen["team_project_memory"]["source_refs"]
  end

  test "refuses sourced context when the current Slack audience cannot be reverified" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "200.001"
    }

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_mode" => "callback",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-unverified-audience",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Should imported context be visible here?"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: IneligibleGroundingProductSource,
               thread_reader: {ThreadReader, test_pid: self()},
               sourced_context_grounder: SourcedContextGrounder
             )

    refute_receive {:sourced_context_grounding, _, _, _}

    refute Enum.any?(
             frozen["team_project_memory"]["facts"],
             &(&1["kind"] == "slack_history_decision")
           )
  end

  test "refuses sourced context from another Slack app installation" do
    authority = %{
      "connect_id" => "imc-native-triage",
      "connect_generation" => "generation-7",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "200.001"
    }

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_mode" => "callback",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-other-installation",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Should another Slack app's imported context be visible here?"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: DriftedGroundingProductSource,
               thread_reader: {ThreadReader, test_pid: self()},
               sourced_context_grounder: SourcedContextGrounder
             )

    refute_receive {:sourced_context_grounding, _, _, _}

    refute Enum.any?(
             frozen["team_project_memory"]["facts"],
             &(&1["kind"] == "slack_history_decision")
           )
  end

  test "a truncated member roster remains explicit in the model decision context" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" => [
        %{
          "event_id" => "Ev-truncated-roster",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Who owns this?"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: TruncatedProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert get_in(frozen, ["team_project_memory", "member_roster"]) == %{
             "completeness" => "truncated",
             "truncated" => true,
             "limit" => 25,
             "returned_count" => 1
           }
  end

  test "meeting source refs follow the facts, not the meetings the freeze happened to read" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" => [
        %{
          "event_id" => "Ev-atlas-question",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Atlas 登录事故的负责人是谁？"
        }
      ]
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: MixedMeetingsProductSource,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    memory = frozen["team_project_memory"]

    # Only the summarized meeting with a non-blank key point produces a fact,
    # so it is the only meeting that may contribute a source ref.
    assert Enum.map(memory["facts"], & &1["source_ref"]) == [
             "meeting://meeting-weekly-7/key-point/0"
           ]

    assert memory["source_refs"] == [
             "bft://projects/project-atlas",
             "bft://projects/project-atlas/members/member-lin",
             "meeting://meeting-weekly-7"
           ]

    # Shared test vector: the verifier rebuilds the ref list from the facts
    # alone, so the freeze and the verifier must produce the same list or every
    # identity run with an in-progress meeting fails :identity_projection_invalid.
    assert memory["source_refs"] ==
             SalixIM.Triage.IdentityContract.raw_memory_source_refs(
               get_in(memory, ["project", "source_ref"]),
               Enum.map(memory["members"], & &1["source_ref"]),
               memory["facts"]
             )

    assert SalixIM.Triage.IdentityContract.valid_raw_memory?(memory, %{
             "project_status" => "active"
           })
  end

  test "fails closed before Slack projection when connect generation or workspace is stale" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" => []
    }

    assert {:error, :stale_source_authority} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: StaleProductSource,
               test_pid: self(),
               thread_reader: {ForbiddenThreadReader, test_pid: self()}
             )

    assert_receive :current_connect_read, 100
    refute_receive :forbidden_project_read, 40
    refute_receive :forbidden_memberships_read, 40
    refute_receive :forbidden_meetings_read, 40
    refute_receive :forbidden_thread_read, 40
  end

  test "fails closed before product or Slack reads when the approved channel changed" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C-old",
        "thread_ts" => "200.001"
      },
      "events" => []
    }

    assert {:error, :stale_source_authority} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: ChannelDriftProductSource,
               test_pid: self(),
               thread_reader: {ForbiddenThreadReader, test_pid: self()}
             )

    assert_receive :current_connect_read, 100
    refute_receive :forbidden_project_read, 40
    refute_receive :forbidden_memberships_read, 40
    refute_receive :forbidden_meetings_read, 40
    refute_receive :forbidden_thread_read, 40
  end

  test "rejects Slack context timestamps with more than six fractional digits" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "events" => [
        %{
          "event_id" => "Ev-overprecise-history",
          "message_ts" => "200.002",
          "actor_id" => "member-peng",
          "text" => "Who owns Atlas?"
        }
      ]
    }

    assert {:error, :invalid_slack_timestamp} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: ProductSource,
               thread_reader:
                 {ConfiguredThreadReader,
                  messages: [
                    %{
                      "ts" => "200.1234567",
                      "user" => "member-peng",
                      "actor_kind" => "human",
                      "text" => "Who owns Atlas?"
                    }
                  ]}
             )
  end

  defp identity_fence_handle do
    %SalixIM.Triage.IdentityFenceHandle{runtime: self(), capability: make_ref()}
  end

  test "default product source reads the real BFT project/member rows and Salix meeting summary" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{"email" => "triage-real-#{n}@example.test", "name" => "Lin"})

    {:ok, org} = Orgs.create_org(%{"name" => "Triage #{n}", "slug" => "triage-#{n}"})
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Atlas",
        "slug" => "atlas-#{n}",
        "created_by_user_id" => user.id
      })

    group_id = project.salix_group_id
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    {:ok, router} =
      Agents.update_agent(router, %{
        "name" => "Triage Router",
        "system_prompt" => "Review the bounded triage context."
      })

    agent_id = router.salix_agent_id

    Repo.insert!(%ProjectMembership{project_id: project.id, user_id: user.id, role: "admin"})

    meeting_id = "meeting-triage-real-#{n}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once(meeting_id,
        state: %{
          "group_id" => group_id,
          "provider" => "slack",
          "title" => "Atlas Weekly",
          "status" => "done",
          "start_at" => 1_776_000_000,
          "summary" => %{
            "key_points" => ["Login incident follow-up stays with Lin."],
            "action_items" => [
              %{
                "description" => "Close the login incident follow-up",
                "owner" => "Lin",
                "deadline" => "2026-08-18"
              }
            ]
          }
        }
      )

    :ok = SalixStore.MeetingGroupProjections.mark_ready(%{"mode" => "test"})
    :ok = SalixStore.MeetingGroupProjectionReadiness.refresh()

    connect_generation = SalixStore.ULID.generate()

    connect = %{
      "tenant_id" => org.salix_tenant_id,
      "connect_id" => "imc-native-real-#{n}",
      "connect_generation" => connect_generation,
      "workspace_id" => "T-real-#{n}",
      "approved_channel_id" => "C-real",
      "group_id" => group_id,
      "inbound_agent_id" => agent_id,
      "provider" => "slack",
      "app_id" => "A-real-#{n}",
      "bot_user_id" => "U-real-#{n}",
      "bot_id" => "B-real-#{n}",
      "bot_token" => "xoxb-test-only",
      "oauth_completed_at" => 1,
      "triage_enabled" => true,
      "disabled_at" => nil,
      "deleted_at" => nil
    }

    assert {:ok, ^connect} =
             SalixStore.CasRecord.create(
               SalixStore.Keys.ctl_im_connect(group_id, connect["connect_id"]),
               connect
             )

    assert {:ok, _channel} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => group_id,
               "connect_id" => connect["connect_id"],
               "channel_id" => connect["approved_channel_id"],
               "installation_generation" => connect_generation,
               "workspace_id" => connect["workspace_id"],
               "channel_name" => "triage-real"
             })

    assert {:ok, current_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               org.salix_tenant_id,
               group_id,
               connect["connect_id"],
               connect["approved_channel_id"]
             )

    authority =
      current_authority
      |> Map.take(~w(connect_id connect_generation workspace_id))
      |> Map.put("channel_id", "C-real")
      |> Map.put("thread_ts", "300.001")

    worker = Process.whereis(SalixIM.Triage.ProductEffectWorker)
    if worker, do: :sys.suspend(worker)
    on_exit(fn -> if worker && Process.alive?(worker), do: :sys.resume(worker) end)
    seed_trajectory_round!(project, router, authority, "prior-work-#{n}")

    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "source_authority" => authority,
      "events" => [
        %{
          "event_id" => "Ev-real",
          "message_ts" => "300.002",
          "actor_id" => "member-peng",
          "text" => "Who owns the Atlas login follow-up?"
        }
      ]
    }

    workers_before =
      Agents.list_agents(project.id) |> Enum.map(& &1.salix_agent_id) |> Enum.sort()

    assert {:ok, scheduled} =
             BridgeForTeams.TriageContext.freeze(
               Map.put(input, "source_mode", "scheduled_recheck"),
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert Agents.list_agents(project.id) |> Enum.map(& &1.salix_agent_id) |> Enum.sort() ==
             workers_before

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(input,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert get_in(frozen, ["team_project_memory", "project", "name"]) == "Atlas"
    assert scheduled["answered_recheck"] == frozen["answered_recheck"]

    history =
      Enum.find(frozen["team_project_memory"]["facts"], &(&1["kind"] == "prior_triage_work"))

    assert is_map(history)
    assert history["text"] =~ ~s("state":"pending")
    assert history["text"] =~ ~s("status":"proposed")
    assert history["text"] =~ "Inspect the playback logs"
    refute history["text"] =~ "outside the excerpt"
    assert byte_size(history["text"]) < 2_000

    assert SalixIM.Triage.IdentityContract.valid_raw_memory?(frozen["team_project_memory"], %{
             "project_status" => "active"
           })

    assert {:ok, [claim]} =
             SalixStore.TriageProductRuntime.claim_obligations("trajectory-freeze", limit: 1)

    assert claim.payload["target"] == authority

    assert {:ok, _} =
             SalixStore.TriageProductRuntime.settle_claim(claim, %{
               adapter: :audit_sink,
               outcome: :applied,
               external_writes: 0,
               communication: %{
                 "kind" => "reply",
                 "text" => "A codec issue is a candidate, not confirmed.",
                 "status" => "captured"
               },
               metadata: %{"mode" => "local_shadow"}
             })

    next_input = %{
      input
      | "events" => [
          %{
            "event_id" => "Ev-next",
            "message_ts" => "300.003",
            "actor_id" => "member-peng",
            "text" => "还是不行"
          }
        ]
    }

    assert {:ok, next_frozen} =
             BridgeForTeams.TriageContext.freeze(next_input,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    updated =
      Enum.find(next_frozen["team_project_memory"]["facts"], &(&1["kind"] == "prior_triage_work"))

    assert updated["source_ref"] == history["source_ref"]
    assert updated["text"] =~ ~s("state":"applied")
    assert updated["text"] =~ ~s("status":"captured")
    assert updated["text"] =~ ~s("external_writes":0)
    refute updated["text"] =~ ~s("status":"delivered")
    assert updated["text"] =~ "A codec issue is a candidate, not confirmed."

    assert {:ok, []} =
             SalixStore.TriageProductRuntime.claim_obligations("trajectory-freeze", limit: 1)

    assert [%{"key" => member_id, "rbac_role" => "admin", "display_name" => "Lin"} = member] =
             get_in(frozen, ["team_project_memory", "members"])

    assert member_id == user.id
    refute Map.has_key?(member, "role")
    refute Map.has_key?(member, "responsibility")

    assert Enum.any?(get_in(frozen, ["team_project_memory", "facts"]), fn fact ->
             fact["source_ref"] == "meeting://#{meeting_id}/action-item/0" and
               fact["owner"] == "Lin"
           end)
  end

  defp seed_trajectory_round!(project, agent, target, run_id) do
    namespace = "trajectory-freeze-test"
    namespace_key = SalixStore.Crypto.hex(namespace)

    SalixStore.Repo.query!(
      """
      INSERT INTO triage_runs (record_key, namespace_key, run_id, body)
      VALUES ($1, $2, $3, $4)
      """,
      [
        "trajectory-test://#{run_id}",
        namespace_key,
        run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => run_id,
          "authoritative" => true,
          "created_at" => 1,
          "status" => "evaluated"
        }
      ]
    )

    id = "triage-product-" <> SalixStore.Crypto.hex(run_id)

    payload = %{
      "schema" => "comma.triage-product-obligation.v1",
      "obligation_id" => id,
      "namespace" => namespace,
      "fence_key" => "test/fence/#{run_id}",
      "run_id" => run_id,
      "target" => target,
      "product_identity" => %{
        "project_id" => project.id,
        "project_salix_group_id" => project.salix_group_id,
        "agent_id" => agent.id,
        "salix_agent_id" => agent.salix_agent_id
      },
      "communication" => %{
        "kind" => "reply",
        "text" =>
          "Inspect the playback logs " <> String.duplicate("界", 200) <> "outside the excerpt",
        "source_refs" => []
      },
      "context_candidates" => [],
      "delegations" => [],
      "target_cutoff" => %{"event_message_timestamps" => ["300.001"]},
      "settled_at" => 1
    }

    SalixStore.Repo.query!(
      """
      INSERT INTO triage_product_obligations (namespace_key, run_id, obligation_id, payload)
      VALUES ($1, $2, $3, $4)
      """,
      [namespace_key, run_id, id, payload]
    )
  end
end
