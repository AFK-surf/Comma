defmodule CommaWeb.ProactiveMailTest do
  use Comma.DataCase, async: false
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias CommaWeb.{ProactiveMail, ProactiveWatch}
  alias SalixStore.{Ids, Loops}

  test "internal reminder source shows conversation messages without system context" do
    result = %{
      "conversation_id" => "home",
      "state" => %{"private" => "session context"},
      "messages" => [
        %{
          "actor_type" => "system",
          "kind" => "message",
          "content" => [%{"type" => "text", "text" => "internal instructions"}]
        },
        %{
          "actor_type" => "user",
          "kind" => "message",
          "content" => [%{"type" => "text", "text" => "Please remind me tomorrow"}]
        },
        %{"actor_type" => "system", "kind" => "app_event", "content" => []},
        %{
          "actor_type" => "agent",
          "kind" => "message",
          "content" => [%{"type" => "text", "text" => "I will remind you"}]
        }
      ]
    }

    assert %{
             "conversation_id" => "home",
             "messages" => [
               %{"body" => "Please remind me tomorrow"},
               %{"body" => "I will remind you"}
             ]
           } =
             ProactiveWatch.preview(result, %{"tool" => "im_api.internal.read_conversation"})
  end

  defmodule Provider do
    use Agent
    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)
    def mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))
    def calls, do: Agent.get(__MODULE__, & &1.calls)
    defp state, do: Agent.get(__MODULE__, & &1)

    defp called(name),
      do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [name | calls] end))

    def settings(tenant), do: get(tenant)
    def get_connected_account(settings, id), do: get_connected_account(settings, id, [])

    def execute_tool(settings, slug, _group, args, _opts) do
      called({:execute, slug, args})

      endpoint =
        if slug == "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
          do: "/threads/#{args["thread_id"]}?full",
          else: "/messages/#{args["message_id"]}?full"

      with {:ok, result} <-
             proxy_execute(settings, "proxy", %{"method" => "GET", "endpoint" => endpoint}, []),
           do: {:ok, %{"successful" => true, "data" => result["data"]}}
    end

    def get(_tenant), do: {:ok, %{"scope" => "system", "webhook_configured" => true}}

    def get_connected_account(_settings, "ca_owner", _opts) do
      called(:account)
      s = state()

      {:ok,
       %{
         "id" => "ca_owner",
         "user_id" => if(s.mode == :foreign, do: "foreign", else: s.group),
         "status" => "ACTIVE",
         "toolkit" => %{"slug" => "gmail"}
       }}
    end

    def upsert_trigger(_settings, group, account, slug, config) do
      called({:trigger, group, account, slug, config})
      {:ok, %{"trigger_id" => if(state().mode == :invalid_trigger, do: nil, else: "ti_mail")}}
    end

    def create_proxy_session(_settings, group, account, "gmail", _opts) do
      called({:proxy, group, account})
      {:ok, "proxy"}
    end

    def delete_proxy_session(_settings, "proxy"), do: called(:proxy_deleted)

    def proxy_execute(_settings, "proxy", %{"method" => "GET", "endpoint" => url}, _opts) do
      called(url)
      s = state()

      second = String.contains?(url, "/messages/m2?") or String.contains?(url, "/threads/t2?")

      message = %{
        "id" =>
          if(s.mode == :fresh_thread_message, do: "m3", else: if(second, do: "m2", else: "m1")),
        "threadId" => if(second, do: "t2", else: "t1"),
        "internalDate" => "1000",
        "labelIds" => ~w(INBOX UNREAD),
        "payload" => %{
          "mimeType" => "text/plain",
          "headers" => [
            %{
              "name" => "Subject",
              "value" =>
                if(s.mode == :fresh_thread_message,
                  do: "New contract needs review",
                  else: "Contract approval"
                )
            }
          ],
          "body" => %{
            "data" =>
              Base.url_encode64(
                "Please approve the contract by Friday." <>
                  if(s.mode == :escaped, do: String.duplicate("\"\n", 2000), else: ""),
                padding: false
              )
          }
        }
      }

      data =
        cond do
          String.ends_with?(url, "/profile") ->
            %{"emailAddress" => "owner@example.test"}

          String.contains?(url, "/messages/") ->
            message

          String.contains?(url, "/threads/") ->
            if s.mode == :revoke,
              do: Comma.MemberSourceConsents.forget_connection(s.workspace, "ca_owner")

            case s.mode do
              {:complete, group, id} ->
                SalixIM.ConversationServer.update_group_conversation(group, id, %{
                  "status" => "completed"
                })

              _ ->
                :ok
            end

            %{"id" => message["threadId"], "messages" => [message]}
        end

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  setup do
    # Queue assertions concern this test's work, not rows left by multi-connection suites.
    Comma.Repo.delete_all(from(job in Oban.Job, where: job.queue == "comma_external"))
    SalixAgent.TestSupport.stop_all_agents()

    old =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_web, :composio_client_mod},
            {:salix_web, :composio_settings_mod},
            {:salix_agent, :proactive_mail_adapter},
            {:salix_agent, :loop_authorization_adapter},
            {:salix_agent, :proactive_adapter},
            {:salix_agent, :composio_store_mod},
            {:salix_agent, :composio_client_mod},
            {:salix_agent, :schedules_mod},
            {:salix_agent, :decide}
          ],
          do: {app, key, Application.get_env(app, key)}

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :composio_client_mod, Provider)
    Application.put_env(:salix_web, :composio_settings_mod, Provider)
    Application.put_env(:salix_agent, :proactive_mail_adapter, ProactiveMail)
    Application.put_env(:salix_agent, :loop_authorization_adapter, CommaWeb.ProactiveWatch)
    Application.put_env(:salix_agent, :proactive_adapter, CommaWeb.Proactive)
    Application.put_env(:salix_agent, :composio_store_mod, Provider)
    Application.put_env(:salix_agent, :composio_client_mod, Provider)
    Application.put_env(:salix_agent, :schedules_mod, SalixCluster.Schedules)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(old, fn {app, key, value} ->
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "role" => "router"
      })

    SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => router["agent_id"]})

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "mail-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace =
      Comma.Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_mail_#{System.unique_integer([:positive])}",
          owner_user_id: user["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: router["agent_id"],
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "mail-test-#{tenant}",
          name: "Mail",
          status: "active"
        })
      )

    membership =
      Comma.Repo.insert!(
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user["id"],
          role: "owner",
          status: "active"
        })
      )

    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace.id, "gmail", "ca_owner")

    ctx = %{
      agent_id: router["agent_id"],
      session_id: router["router_session_id"],
      tenant_id: tenant,
      group_id: group,
      billing_context: %{},
      trusted_origin: %{
        "provider" => "internal",
        "participant_id" => user["id"],
        "source_actor_type" => "user"
      }
    }

    {:ok, row} =
      Loops.create(%{
        "id" => Ids.new_loop_id(),
        "tenant_id" => tenant,
        "group_id" => group,
        "agent_id" => ctx.agent_id,
        "session_id" => ctx.session_id,
        "elf_path" => "/loops/mail.elf",
        "elf_sha256" => "fixture",
        "ifc" => %{"creator" => "comma_user|" <> user["id"]},
        "created_at" => System.system_time(:millisecond)
      })

    start_supervised!(
      {Provider, %{group: group, workspace: workspace.id, mode: :normal, calls: []}}
    )

    %{ctx: ctx, user: user, workspace: workspace, membership: membership, row: row}
  end

  test "Routine reads reuse the current snapshot without collection and fence stale owners", f do
    assert {:ok, %{"state" => "empty", "snapshot" => nil}} =
             CommaWeb.ProactiveWatch.read(
               %{"tool" => "recommendation.read", "arguments" => %{}},
               f.ctx
             )

    assert {:error, :not_found} =
             Comma.Recommendations.get_runtime_profile(f.workspace.id, f.user["id"])

    snapshot = %{"cards" => [%{"id" => "github", "items" => [%{"id" => "review-123"}]}]}

    profile =
      Comma.Repo.insert!(%Comma.Data.RecommendationProfile{
        workspace_id: f.workspace.id,
        user_id: f.user["id"],
        relevance_mode: "generic",
        sources: [%{"enabled" => true}],
        snapshot: snapshot,
        source_revision: 1,
        snapshot_source_revision: 1
      })

    assert {:ok, %{"state" => "fresh", "snapshot" => ^snapshot}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    Comma.Repo.update!(Ecto.Changeset.change(profile, last_error: ":source_collection_failed"))

    assert {:ok,
            %{
              "state" => "stale",
              "snapshot" => ^snapshot,
              "lastError" => "source_collection_failed"
            }} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    Comma.Repo.update!(Ecto.Changeset.change(profile, source_revision: 2))
    assert {:ok, %{"snapshot" => nil}} = CommaWeb.RecommendationRuntime.read(f.ctx)

    assert {:error, :comma_home_router_required} =
             CommaWeb.RecommendationRuntime.read(%{f.ctx | session_id: "stale"})

    assert {:error, _} = CommaWeb.RecommendationRuntime.read(%{f.ctx | trusted_origin: nil})
    assert Provider.calls() == []
  end

  test "selected non-mail work shares handled state across refreshes and rejects revocation", f do
    profile = routine_profile!(f)
    assert {:ok, %{"attention_items" => [item]}} = CommaWeb.RecommendationRuntime.read(f.ctx)
    args = Map.merge(item, %{"text" => "Review this change", "request_id" => "routine-first"})
    assert {:ok, first} = track_source(args, f.ctx)
    assert first["account_id"] == "ca_slack"

    assert {:error, :routine_source_changed} =
             track_source(Map.put(args, "observation_id", "invented"), f.ctx)

    assert {:ok, handled} =
             CommaWeb.Proactive.act(
               %{
                 "action" => "handled",
                 "key" => first["key"],
                 "request_id" => "done"
               },
               f.ctx
             )

    assert {:ok, %{"attention_items" => [], "snapshot" => %{"cards" => []}}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    {:ok, workspace, _, _} = CommaWeb.HomeMail.context(f.user, %{}, f.ctx.group_id)

    assert {:ok, %{"snapshot" => %{"cards" => [], "summary" => [%{"text" => greeting}]}}} =
             CommaWeb.RecommendationRuntime.ensure(f.user, %{}, workspace)

    assert greeting == hd(String.split(hd(profile.snapshot["summary"])["text"], "\n\n"))
    refute greeting =~ "Review request"

    assert item["evidence"] == %{
             "kind" => "published_routine_snapshot",
             "generated_at" => 1,
             "generation" => 1
           }

    changed_title =
      put_in(profile.snapshot, ["prompts", "s1r1", "objective"], "A different title")

    updated =
      Comma.Repo.update!(
        Ecto.Changeset.change(profile, snapshot: Map.put(changed_title, "generation", 2))
      )

    assert {:ok, %{"attention_items" => []}} = CommaWeb.RecommendationRuntime.read(f.ctx)

    assert {:error, :mail_source_handled} =
             track_source(
               Map.merge(
                 args,
                 %{"request_id" => "repeat", "generation" => handled["generation"]}
               ),
               f.ctx
             )

    fresh =
      put_in(
        updated.snapshot,
        ["prompts", "s1r1", "context"],
        "New author reply needs a decision"
      )

    fresh =
      CommaWeb.ProactiveRoutine.attach(fresh, [%{"sourceId" => "ca_slack", "toolkit" => "slack"}])

    Comma.Repo.update!(Ecto.Changeset.change(updated, snapshot: fresh))
    assert {:ok, %{"attention_items" => [new]}} = CommaWeb.RecommendationRuntime.read(f.ctx)
    refute new["observation_id"] == item["observation_id"]

    assert {:ok, next} =
             track_source(
               Map.merge(new, %{
                 "text" => "Read the new reply",
                 "request_id" => "new-reply",
                 "generation" => handled["generation"]
               }),
               f.ctx
             )

    assert next["key"] == first["key"]
    assert next["state"] == "active"
    assert :ok = Comma.MemberSourceConsents.forget_connection(f.workspace.id, "ca_slack")

    assert {:ok, %{"snapshot" => nil, "state" => "error"}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    assert {:error, :routine_result_not_fresh} =
             CommaWeb.RecommendationRuntime.read(item["read"]["arguments"], f.ctx)

    assert Provider.calls() == []
  end

  test "Routine failure references expire and explicit scheduling retains one schedule", f do
    profile = routine_profile!(f)
    Comma.Repo.update!(Ecto.Changeset.change(profile, last_error: ":source_collection_failed"))
    assert {:ok, %{"attention_items" => [failure]}} = CommaWeb.RecommendationRuntime.read(f.ctx)
    assert failure["source_ref"] == "routine:status"

    assert {:ok, first_failure} =
             track_source(
               Map.merge(failure, %{
                 "request_id" => "routine-failed",
                 "text" => "Routine refresh failed; reconnect the source."
               }),
               f.ctx
             )

    assert {:ok, handled_failure} =
             CommaWeb.Proactive.act(
               %{
                 "action" => "handled",
                 "key" => first_failure["key"],
                 "request_id" => "handled-failure"
               },
               f.ctx
             )

    Comma.Repo.update!(Ecto.Changeset.change(Comma.Repo.reload!(profile), last_error: nil))

    assert {:error, :routine_failure_no_longer_current} =
             CommaWeb.RecommendationRuntime.read(%{"scope" => "status"}, f.ctx)

    Comma.Repo.update!(
      Ecto.Changeset.change(Comma.Repo.reload!(profile),
        last_error: ":source_collection_failed",
        requested_generation: 2
      )
    )

    assert {:ok, %{"attention_items" => [new_failure]}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    refute new_failure["observation_id"] == failure["observation_id"]

    assert {:ok, _} =
             track_source(
               Map.merge(new_failure, %{
                 "text" => "A later run failed",
                 "request_id" => "failed-again",
                 "generation" => handled_failure["generation"]
               }),
               f.ctx
             )

    Comma.Repo.update!(Ecto.Changeset.change(Comma.Repo.reload!(profile), last_error: nil))
    assert {:ok, %{"attention_items" => [item]}} = CommaWeb.RecommendationRuntime.read(f.ctx)

    args =
      Map.merge(item, %{
        "action" => "remind",
        "request_id" => "routine-snooze",
        "run_at" => System.system_time(:millisecond) + 60_000
      })

    assert {:ok, first} = CommaWeb.Proactive.act(args, f.ctx)
    assert {:ok, second} = CommaWeb.Proactive.act(args, f.ctx)
    assert first["state"] == "snoozed"
    assert first["schedule_id"] == second["schedule_id"]
    SalixCluster.Schedules.delete(first["schedule_id"])
    assert Provider.calls() == []
  end

  test "partial Routine source failures stay visible until the published warning clears", f do
    profile = routine_profile!(f)

    snapshot =
      Map.put(profile.snapshot, "warnings", [
        %{"code" => "partial_sources", "message" => "Slack collection failed"}
      ])

    Comma.Repo.update!(Ecto.Changeset.change(profile, snapshot: snapshot))

    assert {:ok, %{"attention_items" => [_, failure]}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)

    assert failure["source_ref"] == "routine:status"
    assert failure["body"] =~ "Slack collection failed"

    Comma.Repo.update!(
      Ecto.Changeset.change(Comma.Repo.reload!(profile), snapshot: profile.snapshot)
    )

    assert {:error, :routine_failure_no_longer_current} =
             CommaWeb.RecommendationRuntime.read(failure["read"]["arguments"], f.ctx)
  end

  test "Routine mail uses the existing thread state and current Task rather than a second reminder",
       f do
    decision!(:resolved)
    present!(f)
    id = linked_task!(f)
    profile = routine_profile!(f, "gmail", "ca_owner")
    [dto] = profile.snapshot["attentionItems"]
    snapshot = Map.put(profile.snapshot, "attentionItems", [Map.put(dto, "taskId", id)])

    snapshot =
      CommaWeb.RecommendationMailTasks.project(snapshot, [
        %{
          "sourceId" => "ca_owner",
          "toolkit" => "gmail",
          "mailTasks" => %{
            dto["sourceUrl"] => %{
              "conversation_id" => id,
              "title" => "Review request",
              "status" => "active"
            }
          }
        }
      ])

    assert [%{"kind" => "inline-task"}] = hd(hd(snapshot["cards"])["items"])["parts"]
    Comma.Repo.update!(Ecto.Changeset.change(profile, snapshot: snapshot))
    assert {:ok, %{"attention_items" => [item]}} = CommaWeb.RecommendationRuntime.read(f.ctx)
    assert item["source_ref"] == "t1"
    assert item["observation_id"] == "m1"
    assert item["task_id"] == id
    assert item["body"] == "Please review my change"
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    [value] = status["sources"]
    assert value["key"] == SalixIM.MailInteraction.key(item["source_id"], item["source_ref"])

    assert {:ok, presented} =
             track_source(
               Map.merge(item, %{
                 "text" => "Wait for the reply in this Task",
                 "request_id" => "routine-active-task",
                 "generation" => value["generation"]
               }),
               f.ctx
             )

    assert presented["task_id"] == id
    assert presented["read"] == item["live_read"]

    assert {:ok, scheduled} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "action" => "snooze",
               "key" => presented["key"],
               "generation" => presented["generation"],
               "request_id" => "routine-wait",
               "run_at" => System.system_time(:millisecond) + 3600_000,
               "reason" => "Wait for reply"
             })

    assert {:ok, %{failed: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"])
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)

    assert [%{"state" => "handled", "saving" => false, "task_id" => ^id} = source] =
             status["sources"]

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert Enum.count(messages, fn message ->
             Enum.any?(
               message["content"],
               &String.contains?(&1["text"] || "", "Fresh source evidence")
             )
           end) == 1

    assert {:ok, _} =
             SalixIM.ConversationServer.deliver_task_mail_followup(
               f.ctx.group_id,
               id,
               f.ctx.agent_id,
               source,
               "due:" <> scheduled["schedule_id"]
             )

    assert {:ok, ^messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    for {field, wrong} <- [{"account_id", "other-account"}, {"thread_id", "other-thread"}] do
      assert {:error, :mail_task_source_changed} =
               SalixIM.ConversationServer.deliver_task_mail_followup(
                 f.ctx.group_id,
                 id,
                 f.ctx.agent_id,
                 Map.put(source, field, wrong),
                 "wrong-" <> field
               )
    end

    assert {:ok, ^messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert {:ok, _} =
             SalixIM.ConversationServer.update_group_conversation(f.ctx.group_id, id, %{
               "status" => "completed"
             })

    assert {:error, :mail_task_stopped} =
             track_source(
               Map.merge(item, %{
                 "text" => "Review",
                 "request_id" => "routine-task",
                 "generation" => value["generation"]
               }),
               f.ctx
             )

    assert {:ok, :stopped} =
             SalixIM.ConversationServer.deliver_task_mail_followup(
               f.ctx.group_id,
               id,
               f.ctx.agent_id,
               source,
               "routine-late-retry"
             )

    assert {:ok, ^messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert {:ok, _} =
             CommaWeb.Proactive.act(
               %{"action" => "handled", "key" => value["key"], "request_id" => "mail-done"},
               f.ctx
             )

    assert {:ok, %{"attention_items" => [], "snapshot" => %{"cards" => []}}} =
             CommaWeb.RecommendationRuntime.read(f.ctx)
  end

  defp routine_profile!(f, toolkit \\ "slack", account \\ "ca_slack") do
    {:ok, :ok} = Comma.MemberSourceConsents.record(f.user, %{}, f.workspace.id, toolkit, account)
    receipt = Comma.MemberSourceConsents.binding(f.workspace.id, f.user["id"], toolkit)

    source = %{
      "kind" => "composio",
      "toolkit" => toolkit,
      "appId" => toolkit,
      "appName" => "Slack",
      "connectionId" => account,
      "enabled" => true
    }

    url =
      if toolkit == "gmail",
        do: "https://mail.google.com/mail/#inbox/m1",
        else: "https://slack.com/archives/C1/p123"

    record = %{
      "text" => "Please review my change",
      "permalink" => url,
      "ts" => to_string(System.system_time(:second)),
      "subject" => "Please review my change",
      "threadId" => "t1",
      "messageId" => "m1",
      "webUrl" => url
    }

    fact = %{
      "sourceId" => account,
      "toolkit" => toolkit,
      "appName" => "Slack",
      "data" => %{
        "messages" => if(toolkit == "gmail", do: [record], else: %{"matches" => [record]})
      }
    }

    context = Comma.RecommendationDraft.prepare([fact], %{account => [url]}, "member")

    assert {:ok, compiled} =
             Comma.RecommendationDraft.compile(
               %{"selected" => [%{"id" => "s1r1", "recommendation" => "Review request"}]},
               context,
               %{relevance_mode: "member", generation: 1, source_revision: 1},
               [],
               now_ms: 1
             )

    snapshot = CommaWeb.ProactiveRoutine.attach(compiled, [fact])

    assert :ok = Comma.RecommendationContract.validate(snapshot)

    Comma.Repo.insert!(%Comma.Data.RecommendationProfile{
      workspace_id: f.workspace.id,
      user_id: f.user["id"],
      relevance_mode: "member",
      sources: [source],
      snapshot: snapshot,
      source_revision: 1,
      snapshot_source_revision: 1,
      published_metrics: %{"variant" => "member"},
      published_member_subjects: %{
        account => Map.merge(receipt, %{"user_id" => f.user["id"], "toolkit" => toolkit})
      }
    })
  end

  test "Home entry starts one source collection chain and retires earlier default Loops", f do
    {:ok, session} = Comma.Accounts.create_session(f.user["id"])

    defaults =
      for key <- ~w(home gmail) do
        {:ok, row} =
          Loops.create(%{
            "id" => Ids.new_loop_id(),
            "tenant_id" => f.ctx.tenant_id,
            "group_id" => f.ctx.group_id,
            "agent_id" => f.ctx.agent_id,
            "session_id" => f.ctx.session_id,
            "elf_path" => "/loops/proactive/#{key}.elf",
            "elf_sha256" => "fixture",
            "status" => "paused",
            "config" => %{"comma_proactive" => %{"user_id" => f.user["id"]}},
            "created_at" => System.system_time(:millisecond)
          })

        row
      end

    enter = fn ->
      conn =
        Plug.Test.conn(:post, "/v1/comma/groups/#{f.ctx.group_id}/assistant-chat", "{}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> session["token"])
        |> CommaWeb.Router.call(CommaWeb.Router.init([]))

      assert conn.status == 200, conn.resp_body
    end

    checks = fn ->
      Enum.filter(Comma.Repo.all(Oban.Job), &(&1.worker == "CommaWeb.MemberSourceIngest"))
    end

    enter.()
    enter.()
    assert [%{state: "available"}] = checks.()
    assert %{success: 1, failure: 0} = Oban.drain_queue(Comma.Oban, queue: :comma_external)

    for row <- defaults,
        do:
          assert({:error, :not_found} = Loops.get_by_agent_path(f.ctx.agent_id, row["elf_path"]))

    # A Router-authored watch is not a product default and stays.
    assert {:ok, _} = Loops.get_by_agent_path(f.ctx.agent_id, f.row["elf_path"])

    assert [%{state: "scheduled"} = next] =
             Enum.filter(checks.(), &(&1.state != "completed"))

    assert_in_delta DateTime.diff(next.scheduled_at, DateTime.utc_now()), 900, 60

    enter.()
    assert [%{id: id}] = Enum.filter(checks.(), &(&1.state != "completed"))
    assert id == next.id
  end

  test "generic source reads retain pinned account consent before and after execution", f do
    read = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
        "connected_account_id" => "ca_owner",
        "arguments" => %{"thread_id" => "t1"}
      }
    }

    assert {:ok, data} = CommaWeb.ProactiveWatch.read(read, f.ctx)
    assert get_in(data, ["data", "id"]) == "t1"
    Provider.mode(:revoke)
    assert {:error, :proactive_source_revoked} = CommaWeb.ProactiveWatch.read(read, f.ctx)
    before = Provider.calls()
    assert {:error, :consented_source_required} = CommaWeb.ProactiveWatch.read(read, f.ctx)
    assert before == Provider.calls()
  end

  test "direct discovery cannot bypass the bounded read recipe", f do
    read = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "GMAIL_FETCH_EMAILS",
        "connected_account_id" => "ca_owner",
        "arguments" => %{"max_results" => 1000}
      }
    }

    before = Provider.calls()
    assert {:error, :consented_source_required} = CommaWeb.ProactiveWatch.read(read, f.ctx)
    assert Provider.calls() == before
  end

  test "explicit snooze replaces a presented reminder and fences stale actions", f do
    {:ok, _home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    read = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
        "connected_account_id" => "ca_owner",
        "arguments" => %{"thread_id" => "t1"}
      }
    }

    args = %{
      "source_ref" => "t1",
      "observation_id" => "m1",
      "read" => read,
      "title" => "Contract",
      "url" => "https://mail.google.com/mail/#inbox/t1",
      "text" => "Dana needs your approval on the contract today. Want me to draft the reply?",
      "request_id" => "generic-present"
    }

    assert {:ok, value} = track_source(args, f.ctx)

    assert home_messages(f) == []
    reply!(f.ctx, args["text"] <> "\n[Contract](" <> args["url"] <> ")", "router-reminder")
    # Tracking does not send. The Router chooses a separate ordinary reply.
    assert [%{"content" => [%{"type" => "text", "text" => text}]}] = home_messages(f)
    assert text =~ "Want me to draft the reply?"
    assert text =~ "[Contract](https://mail.google.com/mail/#inbox/t1)"

    assert {:ok, scheduled} =
             CommaWeb.Proactive.act(
               %{
                 "key" => value["key"],
                 "action" => "snooze",
                 "request_id" => "explicit-snooze",
                 "generation" => value["generation"],
                 "run_at" => System.system_time(:millisecond) + 60_000
               },
               f.ctx
             )

    assert scheduled["state"] == "snoozed"
    assert {:ok, _} = SalixCluster.Schedules.get(scheduled["schedule_id"])
    SalixCluster.Schedules.delete(scheduled["schedule_id"])
    # The Router confirms a snooze in its own reply; the state change adds no message.
    assert length(home_messages(f)) == 1

    assert {:error, :mail_source_changed} =
             CommaWeb.Proactive.act(
               %{
                 "key" => value["key"],
                 "action" => "handled",
                 "request_id" => "stale-handled",
                 "generation" => value["generation"]
               },
               f.ctx
             )
  end

  test "explicit reminders enroll while automatic attention is off and retries retain one schedule",
       f do
    args = %{
      "action" => "remind",
      "source_ref" => "t1",
      "observation_id" => "m1",
      "title" => "Contract",
      "request_id" => "manual-new",
      "run_at" => System.system_time(:millisecond) + 60_000,
      "read" => %{
        "tool" => "composio.execute",
        "arguments" => %{
          "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
          "connected_account_id" => "ca_owner",
          "arguments" => %{"thread_id" => "t1"}
        }
      }
    }

    assert {:ok, first} = CommaWeb.Proactive.act(args, f.ctx)
    assert {:ok, second} = CommaWeb.Proactive.act(args, f.ctx)
    assert first["schedule_id"] == second["schedule_id"]
    SalixCluster.Schedules.delete(first["schedule_id"])
  end

  test "product binding capacity rejects a seventeenth binding but permits existing settings",
       f do
    ids =
      for n <- 1..16 do
        {:ok, row} =
          Loops.create(%{
            "id" => Ids.new_loop_id(),
            "tenant_id" => f.ctx.tenant_id,
            "group_id" => f.ctx.group_id,
            "agent_id" => f.ctx.agent_id,
            "session_id" => f.ctx.session_id,
            "elf_path" => "/loops/bound-#{n}.elf",
            "elf_sha256" => "fixture",
            "status" => "paused",
            "config" => %{"comma_proactive" => %{}},
            "created_at" => System.system_time(:millisecond)
          })

        row["id"]
      end

    assert {:error, :mail_monitor_capacity} = Loops.update_mail_binding(f.row["id"], &{:ok, &1})
    assert {:ok, _} = Loops.update_mail_binding(hd(ids), &{:ok, &1})
    assert {:ok, rows} = Loops.proactive_monitors(f.ctx.agent_id)
    assert length(rows) == 16
  end

  test "the same Task survives link, fresh follow-up and completion", f do
    worker =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(f.ctx.group_id), %{
        "tenant_id" => f.ctx.tenant_id,
        "group_id" => f.ctx.group_id,
        "role" => "worker"
      })

    assert {:ok, task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               f.ctx.group_id,
               f.ctx.agent_id,
               worker["agent_id"],
               %{
                 "title" => "Wait for contract reply",
                 "content" => "Read the mail and report; do not send email.",
                 "client_request_id" => "mail-task"
               }
             )

    id = task["conversation_id"]

    assert {:ok, %{"conversation_id" => ^id}} =
             ProactiveMail.link_task(%{"conversation_id" => id, "message_id" => "m1"}, f.ctx)

    assert {:ok, %{"state" => "needs_decision", "mail" => mail}} =
             ProactiveMail.followup(%{"conversation_id" => id}, f.ctx)

    assert hd(mail["messages"])["body"] =~ "approve the contract"

    Provider.mode({:complete, f.ctx.group_id, id})

    assert {:ok, %{"state" => "stopped"} = stopped} =
             ProactiveMail.followup(%{"conversation_id" => id}, f.ctx)

    refute Map.has_key?(stopped, "mail")

    before = Provider.calls()

    assert {:ok, %{"state" => "stopped", "task_status" => "completed"}} =
             ProactiveMail.followup(%{"conversation_id" => id}, f.ctx)

    assert Provider.calls() == before

    assert {:ok, %{"conversation_id" => ^id, "status" => "completed"}} =
             SalixIM.Conversations.get_group_conversation_record(f.ctx.group_id, id)
  end

  defmodule MailDecision do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, {test, mode}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test, {:mail_decision, self(), request})

      if mode == :hold do
        receive do
          :continue -> :ok
        after
          5_000 -> raise "decision was not released"
        end
      end

      if mode == :error do
        Plug.Conn.send_resp(conn, 503, "test model unavailable")
      else
        choice =
          case mode do
            :resolved -> "resolved"
            mode when mode in [:quiet, :malformed, :uncertain] -> "quiet"
            _ -> "notify"
          end

        probability = if mode == :malformed, do: 0.99, else: 1.0

        response = %{
          "model" => "fixture",
          "answers" => %{
            "attention" => %{
              "type" => "choice",
              "choice" => choice,
              "confidence" => if(mode == :uncertain, do: 0.6, else: 1.0),
              "probabilities" =>
                Map.new(
                  request["questions"]["attention"]["criteria"],
                  fn {key, _} -> {key, if(key == choice, do: probability, else: 0.0)} end
                )
            }
          },
          "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end
  end

  defp decision!(mode \\ :notify) do
    server =
      start_supervised!(
        {Bandit,
         plug: {MailDecision, {self(), mode}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:salix_agent, :decide,
      endpoint: "http://127.0.0.1:#{port}/decide",
      api_key: "fixture",
      model: "fixture"
    )
  end

  defp track_source(args, ctx),
    do: CommaWeb.Proactive.act(args |> Map.delete("text") |> Map.put("action", "track"), ctx)

  # Retained Gmail state predates generic source read recipes. Preserve that
  # durable shape to exercise recovery, rechecks and draft actions after upgrade.
  defp track_mail(args, ctx) do
    with {:ok, _, user} <- ProactiveMail.scope(ctx),
         {:ok, home} <- SalixIM.RouterConversationInput.ensure(ctx.group_id),
         {:ok, mail} <- ProactiveMail.read(%{"message_id" => args["message_id"]}, ctx) do
      command =
        Map.take(args, ~w(generation request_id))
        |> Map.merge(%{
          "action" => "track",
          "key" =>
            SalixIM.MailInteraction.key(mail["source"]["connection_id"], mail["thread_id"]),
          "account_id" => mail["source"]["connection_id"],
          "thread_id" => mail["thread_id"],
          "message_id" => mail["message_id"],
          "source_url" => mail["url"],
          "subject" => "Mail"
        })

      with {:ok, command} <-
             CommaWeb.HomeMail.retire_completed_task(command, ctx, home["conversation_id"]) do
        SalixIM.ConversationServer.mail_interaction(
          ctx.group_id,
          home["conversation_id"],
          user,
          ctx.agent_id,
          command
        )
      end
    end
  end

  defp reply!(ctx, text, request) do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(ctx.group_id)

    assert {:ok, _} =
             SalixIM.Provider.call_api(ctx.agent_id, "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => home["conversation_id"],
                 "request_id" => request,
                 "content" => [%{"type" => "text", "text" => text}]
               }
             })
  end

  defp present!(f, message \\ "m1", request \\ "incoming-mail") do
    assert {:ok, value} =
             track_mail(
               %{
                 "message_id" => message,
                 "request_id" => request,
                 "text" => "Please approve the contract by Friday."
               },
               f.ctx
             )

    reply!(f.ctx, "Please approve the contract by Friday.", "reply:" <> message <> ":" <> request)
    value
  end

  defp home_messages(f) do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        f.ctx.group_id,
        home["conversation_id"]
      )

    Enum.filter(messages, &(&1["kind"] == "message"))
  end

  defp router_inputs(f) do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        f.ctx.group_id,
        home["conversation_id"]
      )

    Enum.filter(messages, &is_map(&1["agent_input"]))
  end

  test "Home controls persist one schedule, replace it, and stop stale delivery", f do
    value = present!(f)
    assert [%{"content" => [%{"type" => "text"}]}] = home_messages(f)
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert [%{"generation" => 1} = source] = status["sources"]
    assert source["saving"] == false
    key = source["key"]
    at = System.system_time(:millisecond) + 3600_000

    args = %{
      "key" => key,
      "action" => "snooze",
      "generation" => value["generation"],
      "request_id" => "snooze-1",
      "run_at" => at
    }

    assert {:ok, first} = CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, args)
    assert {:ok, ^first} = CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, args)
    assert {:ok, original} = SalixCluster.Schedules.get(first["schedule_id"])

    assert {:ok, second} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               args
               | "generation" => first["generation"],
                 "request_id" => "snooze-2",
                 "run_at" => at + 3600_000
             })

    assert second["schedule_id"] != first["schedule_id"]
    assert {:error, :not_found} = SalixCluster.Schedules.get(first["schedule_id"])

    assert {:ok, _} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => key,
               "action" => "handled",
               "generation" => second["generation"],
               "request_id" => "handled"
             })

    assert {:error, :not_found} = SalixCluster.Schedules.get(second["schedule_id"])

    assert {:ok, :fired} =
             ProactiveMail.receive_schedule(original["payload"],
               schedule_id: first["schedule_id"],
               scheduled_for: at
             )

    assert length(home_messages(f)) == 1
    assert {:ok, reloaded} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert hd(reloaded["sources"])["state"] == "handled"

    assert {:error, :mail_source_changed} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               args
               | "request_id" => "stale"
             })

    assert {:error, _} = CommaWeb.HomeMail.status(%{"id" => "foreign"}, %{}, f.ctx.group_id)
  end

  test "a recheck still fires after the Router records that it notified the owner", f do
    decision!()
    value = present!(f)

    assert {:ok, %{"sources" => [%{"key" => key}]}} =
             CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)

    at = System.system_time(:millisecond) + 3600_000

    assert {:ok, snoozed} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => key,
               "action" => "snooze",
               "generation" => value["generation"],
               "request_id" => "snooze-1",
               "run_at" => at,
               "reason" => "Before the deadline"
             })

    id = snoozed["schedule_id"]
    before = length(router_inputs(f))

    assert {:ok, %{"state" => "snoozed", "decision" => %{"decision" => "notify"}}} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => key,
               "action" => "notify",
               "generation" => snoozed["generation"],
               "request_id" => "notify-1"
             })

    assert {:ok, %{fired: [^id], failed: []}} = SalixCluster.Schedules.run_once(now: at)
    assert length(router_inputs(f)) == before + 1
  end

  test "mail one-shot uses fresh evidence and the shared test clock with IFC off", f do
    decision!()
    run_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    assert {:ok, scheduled} =
             ProactiveMail.schedule(
               %{
                 "message_id" => "m1",
                 "run_at" => run_at,
                 "reason" => "Remind me if still awaiting approval"
               },
               f.ctx
             )

    id = scheduled["schedule_id"]
    assert {:ok, definition} = SalixCluster.Schedules.get(id)
    assert definition["receiver"] == "comma_mail"
    assert definition["payload"]["generation"] == scheduled["generation"]

    assert {:ok, %{fired: [^id], failed: []}} =
             SalixCluster.Schedules.run_once(now: scheduled["run_at"])

    assert_receive {:mail_decision, _, request}

    assert request["state"]["source"]["messages"] |> hd() |> Map.fetch!("body") =~
             "Please approve"

    assert home_messages(f) == []
    assert [%{"agent_input" => %{"content" => reminder}}] = router_inputs(f)
    assert reminder =~ "A reminder you asked for"
    assert {:error, :not_found} = SalixCluster.Schedules.get(id)
    assert {:ok, %{fired: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"] + 1)
  end

  test "internal reminder follow-up sends visible Home evidence to Decide", f do
    decision!()
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)
    home_id = home["conversation_id"]

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               f.ctx.group_id,
               home_id,
               %{
                 "actor_type" => "user",
                 "user_id" => f.user["id"],
                 "participant_id" => home["user_participant_id"],
                 "content" => [
                   %{"type" => "text", "text" => "Please remind me to check the card"},
                   %{"type" => "file", "file_name" => "card-evidence.pdf"}
                 ],
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               f.ctx.group_id,
               home_id,
               %{
                 "actor_type" => "user",
                 "user_id" => f.user["id"],
                 "participant_id" => home["user_participant_id"],
                 "content" => [
                   %{
                     "type" => "dynamic_ui",
                     "version" => 1,
                     "ui_ref" => "private-card-ref",
                     "path" => "/private/card.html",
                     "summary" => "Check the interactive card",
                     "text" => "Check the interactive card"
                   }
                 ],
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    read = %{
      "tool" => "im_api.internal.read_conversation",
      "arguments" => %{
        "connect_id" => "internal",
        "conversation_id" => home_id,
        "query" => "Current owner commitment",
        "tail" => 12,
        "limit" => 12
      }
    }

    assert {:ok, presented} =
             track_source(
               %{
                 "source_ref" => "conversation:" <> home_id,
                 "observation_id" => "first-reminder",
                 "read" => read,
                 "title" => "Check the card",
                 "text" => "Check the reminder card",
                 "request_id" => "internal-present"
               },
               f.ctx
             )

    reply!(f.ctx, "Check the reminder card", "router-internal-reminder")

    assert {:ok, scheduled} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => presented["key"],
               "action" => "snooze",
               "generation" => presented["generation"],
               "request_id" => "internal-snooze",
               "run_at" => System.system_time(:millisecond) + 60_000
             })

    assert {:ok, %{failed: []}} =
             SalixCluster.Schedules.run_once(now: scheduled["run_at"])

    assert_receive {:mail_decision, _, request}, 5_000
    source = request["state"]["source"]
    assert Enum.any?(source["messages"], &String.contains?(&1["body"], "check the card"))

    assert Enum.any?(source["messages"], fn message ->
             String.contains?(message["body"], "check the card") and
               message["has_attachments"] == true
           end)

    assert Enum.any?(source["messages"], fn message ->
             String.contains?(message["body"], "Check the reminder card") and
               message["has_attachments"] == false
           end)

    assert Enum.any?(source["messages"], fn message ->
             String.contains?(message["body"], "Check the interactive card") and
               message["has_attachments"] == true
           end)

    refute Map.has_key?(source, "content")
    refute inspect(source) =~ "card-evidence.pdf"
    refute inspect(source) =~ "/private/card.html"
    refute inspect(source) =~ "private-card-ref"
    refute source["evidence_truncated"]
  end

  test "handled commits while a model is running and fences its final visible append", f do
    decision!(:hold)
    present!(f)
    run_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    assert {:ok, scheduled} =
             ProactiveMail.schedule(
               %{"message_id" => "m1", "run_at" => run_at, "reason" => "Remind me"},
               f.ctx
             )

    task = Task.async(fn -> SalixCluster.Schedules.run_once(now: scheduled["run_at"]) end)
    assert_receive {:mail_decision, pending, _}, 5_000

    assert {:ok, _} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "action" => "handled",
               "key" => SalixIM.MailInteraction.key("ca_owner", "t1"),
               "generation" => scheduled["generation"],
               "request_id" => "handled-during-model"
             })

    send(pending, :continue)
    assert {:ok, %{failed: []}} = Task.await(task, 10_000)
    assert length(home_messages(f)) == 1
  end

  test "a failed recheck hands the requested reminder to the Router", f do
    decision!(:error)
    present!(f)
    run_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    assert {:ok, scheduled} =
             ProactiveMail.schedule(
               %{"message_id" => "m1", "run_at" => run_at, "reason" => "Remind me"},
               f.ctx
             )

    assert {:ok, %{failed: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"])
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert hd(status["sources"])["state"] == "active"
    assert [_original] = home_messages(f)
    assert [%{"agent_input" => %{"content" => reminder}}] = router_inputs(f)
    assert reminder =~ "I could not check its latest state"
  end

  test "a failed append resumes from the owner and request IDs are scoped to the source", f do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    prefix =
      SalixStore.Keys.ctl_group_conversation_messages_segments_prefix(
        f.ctx.group_id,
        home["conversation_id"]
      )

    SalixStore.S3.Fake.set_fault({:fail, 503, :put, {:prefix, prefix}})

    assert {:error, _} =
             track_mail(
               %{
                 "message_id" => "m1",
                 "request_id" => "same-request",
                 "text" => "Please approve the contract by Friday."
               },
               f.ctx
             )

    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    source = hd(status["sources"])
    assert source["saving"]

    assert {:ok, %{"saving" => false}} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "action" => "resume",
               "key" => source["key"],
               "generation" => source["generation"],
               "request_id" => "resume"
             })

    present!(f, "m2", "same-request")
    assert length(home_messages(f)) == 1
    assert {:ok, %{"sources" => sources}} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert length(sources) == 2
  end

  defp linked_task!(f) do
    worker =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(f.ctx.group_id), %{
        "tenant_id" => f.ctx.tenant_id,
        "group_id" => f.ctx.group_id,
        "role" => "worker"
      })

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        f.ctx.group_id,
        f.ctx.agent_id,
        worker["agent_id"],
        %{
          "title" => "Mail draft",
          "content" => "Draft only",
          "client_request_id" => "linked-draft"
        }
      )

    {:ok, _} =
      ProactiveMail.link_task(
        %{"conversation_id" => task["conversation_id"], "message_id" => "m1"},
        f.ctx
      )

    task["conversation_id"]
  end

  test "an owned Task that needs its owner reaches the Router once and closes when it moves on",
       f do
    worker =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(f.ctx.group_id), %{
        "tenant_id" => f.ctx.tenant_id,
        "group_id" => f.ctx.group_id,
        "role" => "worker"
      })

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        f.ctx.group_id,
        f.ctx.agent_id,
        worker["agent_id"],
        %{
          "title" => "Connector fix scope",
          "content" => "Fix the connector test",
          "owner_user_id" => f.user["id"],
          "client_request_id" => "task-attention"
        }
      )

    id = task["conversation_id"]
    key = SalixIM.MailInteraction.key("task", id)

    set_status = fn status ->
      assert {:ok, _} =
               SalixIM.Provider.call_api(
                 f.ctx.agent_id,
                 "internal",
                 "internal.update_conversation",
                 %{
                   "connect_id" => "internal",
                   "params" => %{"conversation_id" => id, "status" => status}
                 }
               )

      job = %Oban.Job{args: %{"group_id" => f.ctx.group_id, "task_id" => id}}
      assert :ok = CommaWeb.ProactiveTask.perform(job)
      {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
      Enum.find(status["sources"], &(&1["key"] == key))
    end

    before = length(router_inputs(f))

    # The escalation reaches the Router as automatic evidence with a read recipe.
    assert %{"state" => "active", "automatic" => true, "task_id" => ^id} =
             set_status.("escalated")

    assert [%{"agent_input" => %{"content" => text}}] = Enum.drop(router_inputs(f), before)
    assert text =~ "Connector fix scope"
    assert text =~ "im_api.internal.read_conversation"

    # The same escalation, observed again, hands over nothing new.
    assert :ok =
             CommaWeb.ProactiveTask.perform(%Oban.Job{
               args: %{"group_id" => f.ctx.group_id, "task_id" => id}
             })

    assert length(router_inputs(f)) == before + 1

    # The Task moves on: the matter closes. A new escalation starts new attention.
    assert %{"state" => "handled"} = set_status.("active")
    assert %{"state" => "active"} = set_status.("failed")
    assert length(router_inputs(f)) == before + 2

    # Handled while the Task still failed, then the same status again later:
    # the Task left in between, so the new failure reaches the Router.
    {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    value = Enum.find(status["sources"], &(&1["key"] == key))

    assert {:ok, %{"state" => "handled"}} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => key,
               "action" => "handled",
               "generation" => value["generation"],
               "request_id" => "owner-handled"
             })

    # Only escalated or failed statuses queue a check; the collection chain
    # records the leave, also for a handled matter.
    assert {:ok, _} =
             SalixIM.Provider.call_api(
               f.ctx.agent_id,
               "internal",
               "internal.update_conversation",
               %{
                 "connect_id" => "internal",
                 "params" => %{"conversation_id" => id, "status" => "active"}
               }
             )

    {:ok, _, ctx, home} = CommaWeb.HomeMail.context(f.user, %{}, f.ctx.group_id)
    assert :ok = CommaWeb.ProactiveTask.reconcile(ctx, home, f.user["id"])
    assert %{"state" => "active"} = set_status.("failed")
    assert length(router_inputs(f)) == before + 3
  end

  test "status publication recovery checks one Task status version once" do
    snapshot = %{
      "agent_group_id" => "grp_recovery",
      "conversation_id" => "cnv_recovery",
      "status" => "escalated",
      "provider_status_version" => 3
    }

    jobs = fn ->
      Comma.Repo.all(from(job in Oban.Job, where: job.worker == "CommaWeb.ProactiveTask"))
    end

    assert :ok = CommaWeb.ProactiveTask.task_status_changed(snapshot)
    [job] = jobs.()

    # Recovery replays the same version after the check ran: nothing new.
    Comma.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    assert :ok = CommaWeb.ProactiveTask.task_status_changed(snapshot)
    assert [_] = jobs.()

    assert :ok =
             CommaWeb.ProactiveTask.task_status_changed(%{
               snapshot
               | "provider_status_version" => 4
             })

    assert length(jobs.()) == 2

    # Other statuses, of any product's Tasks, touch no Comma state.
    assert :ok =
             CommaWeb.ProactiveTask.task_status_changed(%{
               snapshot
               | "status" => "ready_for_review",
                 "provider_status_version" => 5
             })

    assert length(jobs.()) == 2
  end

  test "a due append failure preserves its schedule and resumes the exact saved result", f do
    decision!()
    present!(f)

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "message_id" => "m1",
          "run_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
          "reason" => "Remind me"
        },
        f.ctx
      )

    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    prefix =
      SalixStore.Keys.ctl_group_conversation_messages_segments_prefix(
        f.ctx.group_id,
        home["conversation_id"]
      )

    SalixStore.S3.Fake.set_fault({:fail, 503, :put, {:prefix, prefix}})
    assert {:ok, first} = SalixCluster.Schedules.run_once(now: scheduled["run_at"])
    assert first.failed != []
    assert {:ok, _} = SalixCluster.Schedules.get(scheduled["schedule_id"])
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert hd(status["sources"])["saving"]
    assert_receive {:mail_decision, _, _}

    assert {:ok, %{failed: []}} =
             SalixCluster.Schedules.run_once(now: scheduled["run_at"] + 60_000)

    refute_receive {:mail_decision, _, _}, 100
    # The original visible message stays. The resumed due event wakes only the Router.
    assert length(home_messages(f)) == 1
    assert length(router_inputs(f)) == 1
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    refute hd(status["sources"])["saving"]
    assert {:error, :not_found} = SalixCluster.Schedules.get(scheduled["schedule_id"])
  end

  test "a Task completed during Decide stops the follow-up before visible append", f do
    decision!(:hold)
    present!(f)
    id = linked_task!(f)

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "conversation_id" => id,
          "run_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
          "reason" => "Check draft"
        },
        f.ctx
      )

    running = Task.async(fn -> SalixCluster.Schedules.run_once(now: scheduled["run_at"]) end)
    assert_receive {:mail_decision, pending, _}, 5_000

    assert {:ok, _} =
             SalixIM.ConversationServer.update_group_conversation(f.ctx.group_id, id, %{
               "status" => "completed"
             })

    send(pending, :continue)
    assert {:ok, %{failed: []}} = Task.await(running, 10_000)
    # Only the original reminder: the completed Task stopped the due one.
    assert length(home_messages(f)) == 1
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert hd(status["sources"])["state"] == "handled"
  end

  test "a resolved reply continues the same active Task once and never reopens a completed Task",
       f do
    decision!(:resolved)
    present!(f)
    id = linked_task!(f)

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "conversation_id" => id,
          "run_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
          "reason" => "Wait for reply"
        },
        f.ctx
      )

    assert {:ok, %{failed: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"])

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert Enum.count(messages, fn m ->
             Enum.any?(m["content"], &String.contains?(&1["text"] || "", "Fresh source evidence"))
           end) == 1

    {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    source = hd(status["sources"])
    assert source["state"] == "handled"
    assert source["task_id"] == id

    assert {:ok, _} =
             SalixIM.ConversationServer.deliver_task_mail_followup(
               f.ctx.group_id,
               id,
               f.ctx.agent_id,
               source,
               "due:" <> scheduled["schedule_id"]
             )

    assert {:ok, repeated} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert length(repeated) == length(messages)

    assert {:ok, _} =
             SalixIM.ConversationServer.update_group_conversation(f.ctx.group_id, id, %{
               "status" => "completed"
             })

    assert {:ok, :stopped} =
             SalixIM.ConversationServer.deliver_task_mail_followup(
               f.ctx.group_id,
               id,
               f.ctx.agent_id,
               source,
               "late-retry"
             )

    assert {:ok, %{"status" => "completed"}} =
             SalixIM.Conversations.get_group_conversation_record(f.ctx.group_id, id)
  end

  test "long escaped mail and Home history fit the real decision input budget", f do
    Provider.mode(:escaped)
    decision!()
    present!(f)
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    for n <- 1..3 do
      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_agent_message(
                 f.ctx.group_id,
                 home["conversation_id"],
                 f.ctx.agent_id,
                 %{
                   "kind" => "message",
                   "content" => [%{"type" => "text", "text" => String.duplicate("\"\n", 3500)}],
                   "idempotency_key" => "long-#{n}"
                 }
               )
    end

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "message_id" => "m1",
          "run_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
          "reason" => "Remind me"
        },
        f.ctx
      )

    assert {:ok, %{failed: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"])
    assert_receive {:mail_decision, _, request}
    assert byte_size(Jason.encode!(request)) <= 12_288
    assert hd(request["state"]["source"]["messages"])["body"] =~ "approve the contract"
    assert {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert hd(status["sources"])["state"] == "active"
  end

  test "draft click creates one canonical Task and retries recover it", f do
    worker =
      SalixAgent.TestSupport.create_control_agent!(f.workspace.salix_worker_agent_id, %{
        "tenant_id" => f.ctx.tenant_id,
        "group_id" => f.ctx.group_id,
        "role" => "worker"
      })

    assert worker["agent_id"] == f.workspace.salix_worker_agent_id
    present!(f)
    {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    value = hd(status["sources"])

    args = %{
      "key" => value["key"],
      "action" => "draft",
      "generation" => value["generation"],
      "request_id" => "draft-click"
    }

    assert {:ok, %{"task_id" => id}} = CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, args)

    assert {:ok, %{"task_id" => ^id}} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, args)

    assert {:ok, task} = SalixIM.Conversations.get_group_conversation_record(f.ctx.group_id, id)
    assert task["source_refs"]["comma_mail"]["message_id"] == "m1"

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert Enum.any?(messages, fn m -> inspect(m["content"]) =~ "approve the contract" end)
  end

  test "fresh mail after Task completion resets draft ownership and source metadata", f do
    present!(f)
    id = linked_task!(f)
    {:ok, before} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    old = hd(before["sources"])

    {:ok, _} =
      SalixIM.ConversationServer.update_group_conversation(f.ctx.group_id, id, %{
        "status" => "completed"
      })

    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    Provider.mode(:fresh_thread_message)

    assert {:ok, fresh} =
             track_source(
               %{
                 "source_ref" => "t1",
                 "observation_id" => "m3",
                 "title" => "New contract needs review",
                 "url" => "https://mail.google.com/mail/#inbox/m3",
                 "read" => %{
                   "tool" => "composio.execute",
                   "arguments" => %{
                     "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
                     "connected_account_id" => "ca_owner",
                     "arguments" => %{"thread_id" => "t1"}
                   }
                 },
                 "generation" => old["generation"],
                 "request_id" => "fresh-after-completion",
                 "text" => "New contract needs review"
               },
               f.ctx
             )

    assert fresh["task_id"] == nil
    refute fresh["delegate_request_id"] == old["delegate_request_id"]
    assert fresh["subject"] == "New contract needs review"
    assert fresh["source_url"] =~ "m3"

    assert {:ok, %{"status" => "completed"}} =
             SalixIM.Conversations.get_group_conversation_record(f.ctx.group_id, id)
  end

  test "handled source disappears from Routine and a fresh thread message leaves the old Task closed",
       f do
    present!(f)
    id = linked_task!(f)
    {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    old = hd(status["sources"])

    assert {:ok, _} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => old["key"],
               "action" => "handled",
               "generation" => old["generation"],
               "request_id" => "handled-old"
             })

    collection = %{
      facts: [
        %{
          "sourceId" => "ca_owner",
          "toolkit" => "gmail",
          "data" => %{
            "messages" => [
              %{
                "messageId" => "m1",
                "threadId" => "t1",
                "webUrl" => "https://mail.google.com/mail/#inbox/m1"
              }
            ]
          }
        }
      ]
    }

    prepared =
      CommaWeb.RecommendationMailTasks.prepare(collection, %{
        "default_group_id" => f.ctx.group_id,
        "router_agent_id" => f.ctx.agent_id
      })

    assert hd(prepared.facts)["data"]["messages"] == []

    assert {:ok, _} =
             SalixIM.ConversationServer.update_group_conversation(f.ctx.group_id, id, %{
               "status" => "completed"
             })

    fresh_collection =
      put_in(collection, [:facts], [
        put_in(hd(collection.facts), ["data", "messages"], [
          %{
            "messageId" => "m3",
            "threadId" => "t1",
            "webUrl" => "https://mail.google.com/mail/#inbox/m3"
          }
        ])
      ])

    fresh =
      CommaWeb.RecommendationMailTasks.prepare(fresh_collection, %{
        "default_group_id" => f.ctx.group_id,
        "router_agent_id" => f.ctx.agent_id
      })

    assert [%{"messageId" => "m3"}] = hd(fresh.facts)["data"]["messages"]
    assert hd(fresh.facts)["mailTasks"]["https://mail.google.com/mail/#inbox/m3"] == nil

    Provider.mode(:fresh_thread_message)

    assert {:ok, current} =
             track_mail(
               %{
                 "message_id" => "m3",
                 "generation" => old["generation"] + 1,
                 "request_id" => "fresh-mail",
                 "text" => "A new contract needs review"
               },
               f.ctx
             )

    assert current["state"] == "active"
    assert current["task_id"] == nil
    refute current["delegate_request_id"] == old["delegate_request_id"]

    assert {:ok, %{"status" => "completed"}} =
             SalixIM.Conversations.get_group_conversation_record(f.ctx.group_id, id)
  end

  @tag :spinfoam
  test "bundled Loop upgrades retained mail work and rebinds its Session without duplicate delivery",
       f do
    alias SalixAgent.{Fleet, InternalSessionStore, SpinfoamFixture}
    alias SalixAgent.Loops.Host
    alias SalixAgent.LLM.Mock
    old_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, Mock)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, old_llm) end)

    binding =
      Comma.MemberSourceConsents.binding(f.workspace.id, f.user["id"], "gmail")
      |> Map.merge(%{
        "user_id" => f.user["id"],
        "workspace_id" => f.workspace.id,
        "enabled" => true
      })

    event = %{
      "event_id" => "mail-visible",
      "topic" => "mail",
      "payload" => %{"message_id" => "m1"}
    }

    {:ok, old} =
      Loops.update(f.row["id"], fn row ->
        {:ok,
         Map.merge(row, %{
           "status" => "active",
           "elf_path" => "/loops/comma-mail-v1.elf",
           "config" => %{"comma_mail" => binding}
         })}
      end)

    {:ok, _} = Loops.admit_event(old, event, System.system_time(:millisecond), 32, 60_000)
    {:ok, _} = SalixAgent.Loops.pause(f.ctx.agent_id, old["id"])

    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)
    {:ok, _} = InternalSessionStore.prepare_commit(f.ctx.agent_id, f.ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(f.ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(f.ctx.agent_id)
    SpinfoamFixture.compile!(SpinfoamFixture.idle_program())
    decision!()

    source = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
        "connected_account_id" => "ca_owner",
        "arguments" => %{"message_id" => "m1"}
      }
    }

    Mock.script([
      {:assistant, "",
       [
         %{
           id: "home-mail",
           name: "call",
           args: %{
             "tool" => "proactive.act",
             "params" => %{
               "source_ref" => "t1",
               "observation_id" => "m1",
               "read" => source,
               "title" => "Contract approval",
               "request_id" => "mail-visible",
               "action" => "track"
             }
           }
         }
       ]},
      {:assistant, "",
       [
         %{
           id: "home-reply",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => home["conversation_id"],
               "content" => [
                 %{"type" => "text", "text" => "Please approve the contract by Friday."}
               ],
               "request_id" => "router-mail-visible"
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    {:ok, loop} =
      CommaWeb.Proactive.watch(
        %{
          "key" => "gmail",
          "source_ref" => "t1",
          "intent" => "Watch the contract",
          "source" => source,
          "trigger" => %{"slug" => "GMAIL_NEW_GMAIL_MESSAGE"}
        },
        f.ctx
      )

    id = loop["loop_id"]
    await(fn -> is_binary(Host.object_for_loop(id)) end)

    assert id == f.row["id"]

    assert {:ok, _} = SalixAgent.Loops.send_event(f.ctx.agent_id, id, event)
    await(fn -> Loops.acked?(id, "mail-visible") end)

    assert_receive {:mail_decision, _, _},
                   1000,
                   inspect(
                     SalixAgent.InternalSession.get(
                       elem(InternalSessionStore.read(f.ctx.agent_id, f.ctx.session_id), 1),
                       :messages
                     ),
                     limit: :infinity
                   )

    messages = fn ->
      {:ok, conversation} =
        SalixIM.Conversations.get_group_conversation_with_messages(
          f.ctx.group_id,
          home["conversation_id"]
        )

      Enum.filter(
        conversation["messages"],
        &String.contains?(inspect(&1["content"]), "Please approve")
      )
    end

    await(fn -> length(messages.()) == 1 end)
    assert {:ok, %{"duplicate" => true}} = SalixAgent.Loops.send_event(f.ctx.agent_id, id, event)
    assert length(messages.()) == 1

    await(fn ->
      {:ok, session} = InternalSessionStore.read(f.ctx.agent_id, f.ctx.session_id)

      transcript =
        session |> SalixAgent.InternalSession.get(:messages) |> inspect(limit: :infinity)

      String.contains?(transcript, "Please approve the contract by Friday.")
    end)

    assert Enum.any?(
             Provider.calls(),
             &match?({:execute, "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", _}, &1)
           )

    {:ok, _} = SalixAgent.Loops.pause(f.ctx.agent_id, id)
    {:ok, _} = Loops.update(id, &{:ok, Map.put(&1, "session_id", "retired-session")})

    args = %{
      "key" => "gmail",
      "source_ref" => "t1",
      "intent" => "Watch the contract",
      "source" => source,
      "trigger" => %{"slug" => "GMAIL_NEW_GMAIL_MESSAGE"}
    }

    assert {:ok, %{"loop_id" => ^id}} = CommaWeb.Proactive.watch(args, f.ctx)
    assert {:ok, rebound} = Loops.get(id)
    assert rebound["session_id"] == f.ctx.session_id
    assert Loops.acked?(id, "mail-visible")
    assert length(messages.()) == 1

    {:ok, _} = SalixAgent.Loops.pause(f.ctx.agent_id, id)

    {:ok, _} =
      Loops.update(
        id,
        &{:ok, Map.put(&1, "pending_events", %{"next" => Map.put(event, "event_id", "next")})}
      )

    Comma.MemberSourceConsents.forget_connection(f.workspace.id, "ca_owner")

    {:ok, :ok} =
      Comma.MemberSourceConsents.record(f.user, %{}, f.workspace.id, "gmail", "ca_owner")

    assert {:error, :proactive_pending_events_require_original_source} =
             CommaWeb.Proactive.watch(args, f.ctx)

    assert {:ok, retained} = Loops.get(id)
    assert retained["pending_events"]["next"]["payload"] == event["payload"]

    # Represent the old event as settled before the owner changes the recipe.
    {:ok, _} =
      Loops.update(id, fn row ->
        {:ok,
         Map.merge(row, %{
           "pending_events" => %{},
           "checkpoint" => %{"observation" => %{"body" => "old-source-content"}}
         })}
      end)

    polling = args |> Map.delete("trigger") |> Map.put("poll_interval_ms", 300_000)
    assert {:ok, %{"loop_id" => ^id}} = CommaWeb.Proactive.watch(polling, f.ctx)
    assert {:ok, changed} = Loops.get(id)
    assert is_nil(changed["composio_trigger"])
    assert_receive {:mail_decision, _, request}, 5000
    refute inspect(request["state"]["previous"]) =~ "old-source-content"
  end

  @tag :spinfoam
  test "invalid provider trigger response leaves the product Loop paused and unbound", f do
    alias SalixAgent.{Fleet, InternalSessionStore}
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)
    {:ok, _} = InternalSessionStore.prepare_commit(f.ctx.agent_id, f.ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(f.ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(f.ctx.agent_id)

    Provider.mode(:invalid_trigger)

    assert {:error, _} =
             CommaWeb.Proactive.watch(
               %{
                 "key" => "invalid-trigger",
                 "source_ref" => "t1",
                 "intent" => "Watch this contract",
                 "source" => %{
                   "tool" => "composio.execute",
                   "arguments" => %{
                     "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
                     "connected_account_id" => "ca_owner",
                     "arguments" => %{"message_id" => "m1"}
                   }
                 },
                 "trigger" => %{"slug" => "GMAIL_NEW_GMAIL_MESSAGE"}
               },
               f.ctx
             )

    assert {:ok, row} =
             Loops.get_by_agent_path(f.ctx.agent_id, "/loops/proactive/invalid-trigger.elf")

    assert row["status"] == "paused"
    assert is_nil(row["composio_trigger"])
  end

  defp ready_proactive_router!(f) do
    alias SalixAgent.{Fleet, InternalSessionStore}
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: f.workspace.billing_owner_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: f.workspace.id
      })

    {:ok, _} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: f.workspace.billing_owner_id,
        credits: 100,
        valid_from: DateTime.add(DateTime.utc_now(), -60, :second),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: f.workspace.id,
        idempotency_key: "default-proactive:" <> f.workspace.id
      })

    {:ok, _} = InternalSessionStore.prepare_commit(f.ctx.agent_id, f.ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(f.ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(f.ctx.agent_id)
  end

  defp await(fun, attempts \\ 300)

  defp await(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await(fun, attempts - 1)
        )
  end

  defp await(_fun, 0), do: flunk("mail runtime did not converge")

  test "foreign accounts and non-owner origins fail before mail reads", f do
    Provider.mode(:foreign)

    assert {:error, :consented_gmail_account_required} =
             ProactiveMail.read(%{"message_id" => "m1"}, f.ctx)

    assert Provider.calls() == [:account]

    assert {:error, :comma_owner_authority_required} =
             ProactiveMail.read(%{"message_id" => "m1"}, %{f.ctx | trusted_origin: %{}})
  end

  test "body survives the pinned read and mid-read revocation refuses the result", f do
    assert {:ok, result} = ProactiveMail.read(%{"message_id" => "m1"}, f.ctx)
    assert hd(result["messages"])["body"] =~ "approve the contract"
    assert {:proxy, f.ctx.group_id, "ca_owner"} in Provider.calls()
    Provider.mode(:revoke)
    assert {:error, :mail_consent_changed} = ProactiveMail.read(%{"message_id" => "m1"}, f.ctx)
    assert hd(Provider.calls()) == :proxy_deleted
  end

  test "revocation and stale Router Session refuse a generic notification before admission", f do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)

    binding =
      Comma.MemberSourceConsents.binding(f.workspace.id, f.user["id"], "gmail")
      |> Map.merge(%{
        "user_id" => f.user["id"],
        "workspace_id" => f.workspace.id,
        "toolkit" => "gmail"
      })

    bound = Map.put(f.row, "config", %{"comma_proactive" => binding})
    {:ok, _} = Loops.update(bound["id"], fn _ -> {:ok, bound} end)
    assert :ok = CommaWeb.ProactiveWatch.authorize(bound, "agent.notify", %{})

    assert {:error, :proactive_source_revoked} =
             CommaWeb.ProactiveWatch.authorize(
               Map.put(bound, "session_id", "retired"),
               "agent.notify",
               %{}
             )

    Comma.MemberSourceConsents.forget_connection(f.workspace.id, "ca_owner")

    assert {:error, error} =
             SalixAgent.Loops.Capabilities.deliver_notification(bound, "private body", "e1")

    assert error =~ "proactive_source_revoked"

    assert {:error, :not_found} =
             SalixAgent.InternalSessionStore.read(f.ctx.agent_id, f.ctx.session_id)
  end
end
