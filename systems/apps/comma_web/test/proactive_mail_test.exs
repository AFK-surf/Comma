defmodule CommaWeb.ProactiveMailTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias CommaWeb.{ProactiveMail, ProactiveWatch}
  alias SalixStore.{Ids, Loops}

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

    @accounts %{
      "ca_owner" => "gmail",
      "ca_outlook" => "outlook",
      "ca_calendar" => "googlecalendar",
      "ca_drive" => "googledrive"
    }

    def get_connected_account(_settings, id, _opts) when is_map_key(@accounts, id) do
      called(:account)
      s = state()

      {:ok,
       %{
         "id" => id,
         "user_id" => if(s.mode == :foreign, do: "foreign", else: s.group),
         "status" => "ACTIVE",
         "toolkit" => %{"slug" => @accounts[id]}
       }}
    end

    def upsert_trigger(_settings, group, account, slug, config) do
      called({:trigger, group, account, slug, config})
      {:ok, %{"trigger_id" => if(state().mode == :invalid_trigger, do: nil, else: "ti_mail")}}
    end

    def create_proxy_session(_settings, group, account, toolkit, _opts)
        when toolkit in ["gmail", "outlook"] do
      called({:proxy, group, account})
      {:ok, "proxy"}
    end

    def delete_proxy_session(_settings, "proxy"), do: called(:proxy_deleted)

    def proxy_execute(_settings, "proxy", %{"method" => "GET", "endpoint" => url}, _opts) do
      called(url)
      s = state()

      if String.starts_with?(url, "https://graph.microsoft.com/v1.0/me") do
        if s.mode == :revoke_outlook and String.contains?(url, "/messages?") do
          Comma.MemberSourceConsents.forget_connection(s.workspace, "ca_outlook")
        end

        message = %{
          "id" => "AAMk1=",
          "conversationId" => "outlook-thread",
          "webLink" => "https://outlook.office.com/mail/id/AAMk1",
          "subject" => "Review the contract",
          "from" => %{"emailAddress" => %{"address" => "sender@example.test"}},
          "body" => %{"contentType" => "text", "content" => "Please approve the contract."},
          "sentDateTime" => "2026-10-02T12:00:00Z"
        }

        data =
          cond do
            String.contains?(url, "/messages/AAMk1%3D") -> message
            String.contains?(url, "/messages?") -> %{"value" => [message]}
            true -> %{"id" => "me", "mail" => "owner@example.test"}
          end

        {:ok, %{"status" => 200, "data" => data}}
      else
        gmail_proxy_execute(s, url)
      end
    end

    defp gmail_proxy_execute(s, url) do
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
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, Provider)
    SystemsRuntime.put_env(:salix_web, :composio_settings_mod, Provider)
    SystemsRuntime.put_env(:salix_agent, :proactive_mail_adapter, ProactiveMail)
    SystemsRuntime.put_env(:salix_agent, :loop_authorization_adapter, CommaWeb.ProactiveWatch)
    SystemsRuntime.put_env(:salix_agent, :proactive_adapter, CommaWeb.Proactive)
    SystemsRuntime.put_env(:salix_agent, :composio_store_mod, Provider)
    SystemsRuntime.put_env(:salix_agent, :composio_client_mod, Provider)
    SystemsRuntime.put_env(:salix_agent, :schedules_mod, SalixCluster.Schedules)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(old, fn {app, key, value} ->
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
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
        "email" => "mail-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace =
      Comma.Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_mail_#{SystemsRuntime.Proc.unique_integer([:positive])}",
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
        "created_at" => SystemsClock.system_time(:millisecond)
      })

    start_supervised!(
      {Provider, %{group: group, workspace: workspace.id, mode: :normal, calls: []}}
    )

    %{ctx: ctx, user: user, workspace: workspace, membership: membership, row: row}
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

    # No row is left, so the summary keeps only its title and the break after it.
    assert greeting == hd(String.split(hd(profile.snapshot["summary"])["text"], "\n\n")) <> "\n\n"
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

  defp ready_proactive_router!(f) do
    alias SalixAgent.{Fleet, InternalSessionStore}
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
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
        valid_from: DateTime.add(SystemsClock.utc_now(), -60, :second),
        expires_at: DateTime.add(SystemsClock.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: f.workspace.id,
        idempotency_key: "default-proactive:" <> f.workspace.id
      })

    {:ok, _} = InternalSessionStore.prepare_commit(f.ctx.agent_id, f.ctx.session_id, [])
    {:ok, _} = Fleet.ensure_started(f.ctx.agent_id, create: false)
    :ok = Fleet.await_ownership_installed(f.ctx.agent_id)
  end

  defp received?(match) do
    {:messages, messages} = SystemsRuntime.Proc.info(SystemsRuntime.Proc.self(), :messages)
    Enum.any?(messages, match)
  end

  # The Loop runs in its spinfoam child: wait for what it records.
  defp await(fun, attempts \\ 1500)
  defp await(_fun, 0), do: flunk("the watch Loop did not converge")

  defp await(fun, attempts) do
    if fun.(), do: :ok, else: SystemsRuntime.Proc.sleep(20) && await(fun, attempts - 1)
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
      "ts" => to_string(SystemsClock.system_time(:second)),
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
            "created_at" => SystemsClock.system_time(:millisecond)
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

    assert_in_delta DateTime.diff(next.scheduled_at, SystemsClock.utc_now()), 900, 60

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

  defmodule SlackMCP do
    def provider_state(_agent_id), do: {:ok, %{}}
    def list_bindings(_agent_id), do: {:ok, []}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => "mcp.slack.slack_read_thread",
           "summary" => "Read a Slack thread.",
           "manual" => "Read a Slack thread.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def call_tool(_agent_id, "slack", "slack_read_thread", args, _ctx) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :proactive_slack_mcp_pid),
        {:slack_mcp, args}
      )

      {:ok,
       %{
         "status" => "completed",
         "content" =>
           Jason.encode!(%{"messages" => [%{"text" => "Ana replied", "user" => "UANA"}]})
       }}
    end
  end

  test "a Slack watch reads through the managed OAuth grant and the Slack MCP, never Composio",
       f do
    previous = SystemsRuntime.get_env(:salix_agent, :mcp_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, SlackMCP)
    SystemsRuntime.put_env(:comma_web, :proactive_slack_mcp_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.delete_env(:comma_web, :proactive_slack_mcp_pid)

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_agent, :mcp_provider_mod),
        else: SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, previous)
    end)

    {:ok, workspace, user} = CommaWeb.Proactive.scope(f.ctx)

    read = %{
      "tool" => "mcp.slack.slack_read_thread",
      "arguments" => %{"channel_id" => "C1", "thread_ts" => "1786900000.000200", "limit" => 20}
    }

    # Without the Comma Slack plugin's managed grant there is no source.
    assert {:error, :consented_source_required} =
             ProactiveWatch.source_binding(read, workspace, user)

    # A Composio Slack account is never a watch source, consent or not.
    {:ok, :ok} =
      Comma.MemberSourceConsents.record(f.user, %{}, workspace["id"], "slack", "ca_slack")

    composio = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "SLACK_FETCH_MESSAGE_THREAD_FROM_A_CONVERSATION",
        "connected_account_id" => "ca_slack",
        "arguments" => %{"channel" => "C1", "ts" => "1786900000.000200"}
      }
    }

    assert {:error, :consented_source_required} =
             ProactiveWatch.source_binding(composio, workspace, user)

    grant = fn connection ->
      :ok =
        SalixStore.OAuth.put(connection, %{
          "connection_id" => connection,
          "tenant" => f.ctx.tenant_id,
          "provider" => "slack",
          "status" => "active",
          "access_token" => "xoxp-owner",
          "comma_member" => %{"user_id" => user, "workspace_id" => workspace["id"]},
          "metadata" => %{"metadata" => %{"authed_user_id" => "UOWNER", "team_id" => "TTEAM"}}
        })

      {:ok, oauth, _previous} =
        Salix.Control.OAuthBindings.put(
          f.ctx.tenant_id,
          f.ctx.group_id,
          "slack",
          "slack",
          connection
        )

      oauth
    end

    connection = "conn-slack-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    oauth = grant.(connection)

    assert {:ok, binding} = ProactiveWatch.source_binding(read, workspace, user)
    assert binding["kind"] == "managed_oauth"
    assert binding["toolkit"] == "slack"
    assert binding["binding_id"] == oauth["binding_id"]
    assert binding["connection_id"] == connection
    assert :ok = ProactiveWatch.current_consent(binding)
    assert ProactiveWatch.provider(read) == "Slack"

    # The read runs the pinned MCP tool with the exact arguments.
    assert {:ok, data} = ProactiveWatch.read(read, f.ctx)
    assert [%{"text" => "Ana replied"}] = data["messages"]
    assert_received {:slack_mcp, %{"channel_id" => "C1", "thread_ts" => "1786900000.000200"}}

    # A reconnect backs the Group's Slack grant with another connection: the
    # watch enrolled on the old grant is revoked, the current grant still reads.
    _ = grant.(connection <> "-reconnected")
    assert {:error, :proactive_source_revoked} = ProactiveWatch.current_consent(binding)
    assert {:ok, current} = ProactiveWatch.source_binding(read, workspace, user)
    assert current["connection_id"] == connection <> "-reconnected"
  end

  defmodule ManagedMCP do
    def provider_state(_agent_id), do: {:ok, %{}}
    def list_bindings(_agent_id), do: {:ok, []}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       for name <- ~w(mcp.github.pull_request_read mcp.linear.get_issue mcp.notion.fetch) do
         %{
           "name" => name,
           "summary" => "Read one item.",
           "manual" => "Read one item.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       end}
    end

    def call_tool(_agent_id, provider, tool, args, _ctx) do
      send(
        SystemsRuntime.fetch_env!(:comma_web, :proactive_managed_mcp_pid),
        {:managed_mcp, provider, tool, args}
      )

      content =
        SystemsRuntime.get_env(:comma_web, :proactive_managed_mcp_content) ||
          Jason.encode!(%{"state" => "open"})

      {:ok, %{"status" => "completed", "content" => content}}
    end
  end

  defp managed_grant!(f, provider, metadata) do
    {:ok, workspace, user} = CommaWeb.Proactive.scope(f.ctx)
    connection = "conn-#{provider}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SalixStore.OAuth.put(connection, %{
        "connection_id" => connection,
        "tenant" => f.ctx.tenant_id,
        "provider" => provider,
        "status" => "active",
        "access_token" => "token-owner",
        "comma_member" => %{"user_id" => user, "workspace_id" => workspace["id"]},
        "metadata" => %{"metadata" => metadata}
      })

    {:ok, oauth, _previous} =
      Salix.Control.OAuthBindings.put(
        f.ctx.tenant_id,
        f.ctx.group_id,
        provider,
        provider,
        connection
      )

    {connection, oauth}
  end

  defp managed_mcp!(content \\ nil) do
    previous = SystemsRuntime.get_env(:salix_agent, :mcp_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, ManagedMCP)
    SystemsRuntime.put_env(:comma_web, :proactive_managed_mcp_pid, SystemsRuntime.Proc.self())
    if content, do: SystemsRuntime.put_env(:comma_web, :proactive_managed_mcp_content, content)

    on_exit(fn ->
      SystemsRuntime.delete_env(:comma_web, :proactive_managed_mcp_pid)
      SystemsRuntime.delete_env(:comma_web, :proactive_managed_mcp_content)

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_agent, :mcp_provider_mod),
        else: SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, previous)
    end)
  end

  test "GitHub, Linear and Notion watches read through the managed OAuth grant and the plugin MCP",
       f do
    managed_mcp!()
    {:ok, workspace, user} = CommaWeb.Proactive.scope(f.ctx)

    cases = [
      {"github", "GitHub", "pull_request_read",
       %{"method" => "get", "owner" => "AFK-surf", "repo" => "Comma", "pullNumber" => 11},
       %{"user_id" => 42, "login" => "owner"}},
      {"linear", "Linear", "get_issue", %{"id" => "CUE-1"},
       %{"actor" => "user", "viewer_id" => "lin-user", "workspace_id" => "lin-ws"}},
      {"notion", "Notion", "fetch", %{"id" => "page-1"},
       %{"owner" => %{"type" => "user", "user" => %{"id" => "n-user"}}, "workspace_id" => "n-ws"}}
    ]

    for {provider, label, tool, arguments, metadata} <- cases do
      read = %{"tool" => "mcp.#{provider}.#{tool}", "arguments" => arguments}

      # Without the plugin's managed grant there is no source.
      assert {:error, :consented_source_required} =
               ProactiveWatch.source_binding(read, workspace, user)

      {connection, oauth} = managed_grant!(f, provider, metadata)

      assert {:ok, binding} = ProactiveWatch.source_binding(read, workspace, user)
      assert binding["kind"] == "managed_oauth"
      assert binding["toolkit"] == provider
      assert binding["binding_id"] == oauth["binding_id"]
      assert binding["connection_id"] == connection
      assert :ok = ProactiveWatch.current_consent(binding)
      assert ProactiveWatch.provider(read) == label

      # The read runs the pinned MCP tool with the exact arguments.
      assert {:ok, %{"state" => "open"}} = ProactiveWatch.read(read, f.ctx)
      assert_received {:managed_mcp, ^provider, ^tool, ^arguments}
    end

    # An MCP outside the managed plugins is not a watch source.
    assert {:error, :proactive_source_required} =
             ProactiveWatch.source_binding(
               %{"tool" => "mcp.x.search_posts", "arguments" => %{"query" => "p1"}},
               workspace,
               user
             )

    assert {:error, :proactive_source_required} =
             ProactiveWatch.source_binding(
               %{"tool" => "mcp.github.", "arguments" => %{}},
               workspace,
               user
             )
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
      SystemsRuntime.Proc.send(test, {:mail_decision, SystemsRuntime.Proc.self(), request})

      if mode == :hold do
        SystemsRuntime.Proc.receive do
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
         plug: {MailDecision, {SystemsRuntime.Proc.self(), mode}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    SystemsRuntime.put_env(:salix_agent, :decide,
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
    at = SystemsClock.system_time(:millisecond) + 3600_000

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

  test "mail one-shot uses fresh evidence and the shared test clock with IFC off", f do
    decision!()
    run_at = SystemsClock.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

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
    assert reminder =~ "A reminder: "
    assert {:error, :not_found} = SalixCluster.Schedules.get(id)
    assert {:ok, %{fired: []}} = SalixCluster.Schedules.run_once(now: scheduled["run_at"] + 1)
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

  test "a due append failure preserves its schedule and resumes the exact saved result", f do
    decision!()
    present!(f)

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "message_id" => "m1",
          "run_at" => SystemsClock.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
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

  test "a resolved reply continues the same active Task once and never reopens a completed Task",
       f do
    decision!(:resolved)
    present!(f)
    id = linked_task!(f)

    {:ok, scheduled} =
      ProactiveMail.schedule(
        %{
          "conversation_id" => id,
          "run_at" => SystemsClock.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
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

  test "draft click creates one canonical Task on the Group's Task agent and retries recover it",
       f do
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
    # The Workspace's stored default Worker is not read.
    assert task["task_worker_agent_id"] == SalixAgent.TaskAgent.id(f.ctx.group_id)

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(f.ctx.group_id, id)

    assert Enum.any?(messages, fn m -> inspect(m["content"]) =~ "approve the contract" end)
  end

  @tag :spinfoam
  test "a GitHub pull request watch polls the pinned MCP read in the Loop with bounded evidence",
       f do
    alias SalixAgent.Loops.Host

    pull_request = %{
      "number" => 11,
      "title" => "Ensure telegram provider member",
      "state" => "open",
      "updated_at" => "2026-10-08T08:00:00Z",
      "html_url" => "https://github.com/AFK-surf/Comma/pull/11",
      "statuses_url" => "https://api.github.com/repos/AFK-surf/Comma/statuses/abc",
      "body" => String.duplicate("Large description. ", 2_000),
      "head" => %{"sha" => "abc", "repo" => %{"full_name" => "AFK-surf/Comma"}}
    }

    managed_mcp!(Jason.encode!(pull_request))
    {_connection, _oauth} = managed_grant!(f, "github", %{"user_id" => 42, "login" => "owner"})
    ready_proactive_router!(f)
    decision!(:quiet)

    arguments = %{"method" => "get", "owner" => "AFK-surf", "repo" => "Comma", "pullNumber" => 11}

    args = %{
      "key" => "github-pr-11",
      "source_ref" => "https://github.com/AFK-surf/Comma/pull/11",
      "intent" => "Tell me about new reviews, CI changes or a merge",
      "source" => %{"tool" => "mcp.github.pull_request_read", "arguments" => arguments},
      "poll_interval_ms" => 300_000
    }

    # A plugin MCP read has no provider trigger: it is refused before a Loop exists.
    assert {:error, :proactive_trigger_unavailable} =
             CommaWeb.Proactive.watch(
               Map.put(args, "trigger", %{"slug" => "GITHUB_PULL_REQUEST_EVENT"}),
               f.ctx
             )

    assert {:error, :not_found} =
             Loops.get_by_agent_path(f.ctx.agent_id, "/loops/proactive/github-pr-11.elf")

    assert {:ok, %{"loop_id" => id, "status" => "active"}} = CommaWeb.Proactive.watch(args, f.ctx)
    await(fn -> is_binary(Host.object_for_loop(id)) end)

    # The Router can confirm which matter the watch follows.
    assert {:ok, %{"monitors" => monitors}} = CommaWeb.Proactive.state(%{}, f.ctx)

    assert %{
             "key" => "github-pr-11",
             "provider" => "GitHub",
             "source_ref" => "https://github.com/AFK-surf/Comma/pull/11",
             "status" => "active"
           } = Enum.find(monitors, &(&1["loop_id"] == id))

    # The first poll reads the exact pinned MCP call inside the Loop and hands
    # Decide a bounded projection of the full pull request.
    await(fn ->
      received?(&match?({:managed_mcp, "github", "pull_request_read", ^arguments}, &1))
    end)

    assert_received {:managed_mcp, "github", "pull_request_read", ^arguments}
    await(fn -> received?(&match?({:mail_decision, _, _}, &1)) end)
    assert_received {:mail_decision, _, request}
    source = request["state"]["source"]
    assert source["title"] == "Ensure telegram provider member"
    assert source["html_url"] == pull_request["html_url"]
    refute Map.has_key?(source, "statuses_url")
    assert byte_size(Jason.encode!(source)) <= 3_000

    settled = fn ->
      {:ok, row} = Loops.get(id)
      checkpoint = row["checkpoint"] || %{}
      is_nil(checkpoint["pending_poll"]) and is_map(checkpoint["observation"]) and checkpoint
    end

    await(settled)
    {:ok, row} = Loops.get(id)
    first_poll = row["checkpoint"]["poll_sequence"]

    # A restarted Loop polls again at once. An unchanged pull request settles
    # without another Decide call.
    {:ok, _} = SalixAgent.Loops.pause(f.ctx.agent_id, id)
    {:ok, _} = SalixAgent.Loops.resume(f.ctx.agent_id, id)

    await(fn ->
      received?(&match?({:managed_mcp, "github", "pull_request_read", ^arguments}, &1))
    end)

    assert_received {:managed_mcp, "github", "pull_request_read", ^arguments}
    await(fn -> (checkpoint = settled.()) && checkpoint["poll_sequence"] != first_poll end)
    refute_received {:mail_decision, _, _}
  end

  @tag :spinfoam
  test "invalid provider trigger response removes the new product Loop", f do
    alias SalixAgent.{Fleet, InternalSessionStore}
    {:ok, _home} = SalixIM.RouterConversationInput.ensure(f.ctx.group_id)
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

    # A new watch that cannot start leaves no paused Loop behind.
    assert {:error, :not_found} =
             Loops.get_by_agent_path(f.ctx.agent_id, "/loops/proactive/invalid-trigger.elf")

    # A replaced watch that cannot start returns to its earlier recipe and status.
    Provider.mode(nil)

    polling = %{
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
      "poll_interval_ms" => 300_000
    }

    assert {:ok, %{"loop_id" => id, "status" => "active"}} =
             CommaWeb.Proactive.watch(polling, f.ctx)

    Provider.mode(:invalid_trigger)

    assert {:error, _} =
             CommaWeb.Proactive.watch(
               polling
               |> Map.delete("poll_interval_ms")
               |> Map.put("intent", "Watch this contract by event")
               |> Map.put("trigger", %{"slug" => "GMAIL_NEW_GMAIL_MESSAGE"}),
               f.ctx
             )

    assert {:ok, restored} = Loops.get(id)
    assert restored["status"] == "active"
    assert restored["name"] == "Watch this contract"
    assert restored["config"]["poll_interval_ms"] == 300_000
    assert is_nil(restored["composio_trigger"])
  end

  test "foreign accounts and non-owner origins fail before mail reads", f do
    Provider.mode(:foreign)

    assert {:error, :consented_gmail_account_required} =
             ProactiveMail.read(%{"message_id" => "m1"}, f.ctx)

    assert Provider.calls() == [:account]

    assert {:error, :comma_owner_authority_required} =
             ProactiveMail.read(%{"message_id" => "m1"}, %{f.ctx | trusted_origin: %{}})
  end

  test "Outlook account stays pinned across read, Task follow-up, and consent revocation", f do
    {:ok, :ok} =
      Comma.MemberSourceConsents.record(f.user, %{}, f.workspace.id, "outlook", "ca_outlook")

    args = %{"message_id" => "AAMk1=", "connection_id" => "ca_outlook"}
    assert {:ok, mail} = ProactiveMail.read(args, f.ctx)
    assert mail["thread_id"] == "outlook-thread"
    assert hd(mail["messages"])["body"] =~ "approve the contract"
    assert {:proxy, f.ctx.group_id, "ca_outlook"} in Provider.calls()

    assert {:error, :consented_mail_account_required} =
             ProactiveMail.read(%{"message_id" => "AAMk1=", "connection_id" => "ca_other"}, f.ctx)

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
          "title" => "Outlook draft",
          "content" => "Draft only",
          "client_request_id" => "outlook-draft"
        }
      )

    id = task["conversation_id"]

    assert {:ok,
            %{"source" => %{"connection_id" => "ca_outlook", "thread_id" => "outlook-thread"}}} =
             ProactiveMail.link_task(Map.put(args, "conversation_id", id), f.ctx)

    # Replaying the same Outlook link retains the original Task identity.
    assert {:ok, %{"conversation_id" => ^id}} =
             ProactiveMail.link_task(Map.put(args, "conversation_id", id), f.ctx)

    assert {:ok, %{"conversation_id" => ^id}} =
             ProactiveMail.followup(%{"conversation_id" => id}, f.ctx)

    Provider.mode(:revoke_outlook)

    assert {:error, :mail_consent_changed} =
             ProactiveMail.followup(%{"conversation_id" => id}, f.ctx)

    assert {:error, :consented_mail_account_required} = ProactiveMail.read(args, f.ctx)
  end

  test "Calendar and Drive watches pin a filtered list read with a few results", f do
    {:ok, workspace, user} = CommaWeb.Proactive.scope(f.ctx)

    for {toolkit, account, slug, bounded, unbounded} <- [
          {"googlecalendar", "ca_calendar", "GOOGLECALENDAR_EVENTS_LIST",
           %{"calendarId" => "primary", "iCalUID" => "evt-1@google.com", "maxResults" => 5},
           %{"calendarId" => "primary", "maxResults" => 250}},
          {"googledrive", "ca_drive", "GOOGLEDRIVE_LIST_FILES",
           %{"q" => "name = 'Q4 plan' and trashed = false", "pageSize" => 3},
           %{"pageSize" => 100}}
        ] do
      {:ok, :ok} =
        Comma.MemberSourceConsents.record(f.user, %{}, workspace["id"], toolkit, account)

      read = fn arguments ->
        %{
          "tool" => "composio.execute",
          "arguments" => %{
            "tool_slug" => slug,
            "connected_account_id" => account,
            "arguments" => arguments
          }
        }
      end

      assert {:ok, %{"toolkit" => ^toolkit}} =
               ProactiveWatch.source_binding(read.(bounded), workspace, user)

      assert {:error, :consented_source_required} =
               ProactiveWatch.source_binding(read.(unbounded), workspace, user)
    end
  end

  test "Outlook watch reads are pinned and rejected after disconnect", f do
    {:ok, :ok} =
      Comma.MemberSourceConsents.record(f.user, %{}, f.workspace.id, "outlook", "ca_outlook")

    binding =
      Comma.MemberSourceConsents.binding(f.workspace.id, f.user["id"], "outlook")
      |> Map.merge(%{
        "user_id" => f.user["id"],
        "workspace_id" => f.workspace.id,
        "toolkit" => "outlook"
      })

    spec = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "OUTLOOK_OUTLOOK_GET_MESSAGE",
        "connected_account_id" => "ca_outlook",
        "arguments" => %{"message_id" => "AAMk1="}
      }
    }

    bound = Map.put(f.row, "config", %{"comma_proactive" => binding, "source" => spec})
    {:ok, _} = Loops.update(bound["id"], fn _ -> {:ok, bound} end)
    assert :ok = ProactiveWatch.authorize(bound, "composio.execute", spec["arguments"])

    assert {:error, _} =
             ProactiveWatch.authorize(
               bound,
               "composio.execute",
               put_in(spec, ["arguments", "connected_account_id"], "ca_owner")["arguments"]
             )

    Comma.MemberSourceConsents.forget_connection(f.workspace.id, "ca_outlook")

    assert {:error, :proactive_source_revoked} =
             ProactiveWatch.authorize(bound, "composio.execute", spec["arguments"])
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

  test "a watch wake becomes the owner's matter on the one Router handoff path", f do
    binding =
      Comma.MemberSourceConsents.binding(f.workspace.id, f.user["id"], "gmail")
      |> Map.merge(%{
        "user_id" => f.user["id"],
        "workspace_id" => f.workspace.id,
        "toolkit" => "gmail"
      })

    source = %{
      "tool" => "composio.execute",
      "arguments" => %{
        "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
        "connected_account_id" => "ca_owner",
        "arguments" => %{"user_id" => "me", "thread_id" => "t-watch"}
      }
    }

    bound =
      Map.put(f.row, "config", %{
        "comma_proactive" => binding,
        "source" => source,
        "source_ref" => "t-watch",
        "intent" => "Tell me when Ana replies"
      })

    {:ok, _} = Loops.update(bound["id"], fn _ -> {:ok, bound} end)
    before = length(router_inputs(f))

    assert {:ok, %{"status" => "queued"}} =
             SalixAgent.Loops.Capabilities.deliver_notification(bound, "Ana replied", "e2")

    # A redelivered wake with the same dedup key adds nothing.
    assert {:ok, _} =
             SalixAgent.Loops.Capabilities.deliver_notification(bound, "Ana replied", "e2")

    assert [%{"agent_input" => input}] = Enum.drop(router_inputs(f), before)
    assert input["content"] =~ "Ana replied"
    assert input["trusted_origin"]["provider"] == "loop"

    key = SalixIM.MailInteraction.key("ca_owner", "t-watch")
    {:ok, status} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    value = Enum.find(status["sources"], &(&1["key"] == key))
    assert %{"automatic" => false, "subject" => "Tell me when Ana replies"} = value

    # The owner asked for the watch: notifying about it spends no budget.
    assert {:ok, %{"decision" => %{"decision" => "notify"}}} =
             CommaWeb.HomeMail.action(f.user, %{}, f.ctx.group_id, %{
               "key" => key,
               "action" => "notify",
               "generation" => value["generation"],
               "request_id" => "watch-notify"
             })

    {:ok, after_notify} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert after_notify["notification_budget"]["remaining"] == 5

    # Long evidence is kept bounded in Home and says it was cut.
    long = String.duplicate("evidence ", 900)

    assert {:ok, %{"status" => "queued"}} =
             SalixAgent.Loops.Capabilities.deliver_notification(bound, long, "e3")

    assert %{"agent_input" => %{"content" => last}} = List.last(router_inputs(f))
    assert last =~ "[evidence truncated]"
    refute last =~ long

    # JSON evidence keeps its locator and instructions first; only the large
    # evidence fields are cut.
    evidence =
      Jason.encode!(%{
        "event" => String.duplicate("payload ", 700),
        "instructions" => "Use the proactive skill.",
        "source_ref" => "t-watch"
      })

    assert {:ok, _} = SalixAgent.Loops.Capabilities.deliver_notification(bound, evidence, "e6")
    assert %{"agent_input" => %{"content" => cut}} = List.last(router_inputs(f))
    assert cut =~ "Use the proactive skill."
    assert cut =~ "[evidence truncated]"

    # A notice about the watch itself (paused, exited, failed) is not a matter
    # wake: it reaches the Router's Session directly, not Home.
    inputs = length(router_inputs(f))

    SalixAgent.Loops.Capabilities.deliver_notification(
      bound,
      "Background loop paused: notification budget exhausted.",
      "lifecycle:budget",
      lifecycle: true
    )

    assert length(router_inputs(f)) == inputs

    # Out-of-order redelivery (A, B, then A again) is a duplicate: it neither
    # changes the matter nor wakes the Router.
    assert {:ok, _} = SalixAgent.Loops.Capabilities.deliver_notification(bound, "B", "e4")
    inputs = length(router_inputs(f))
    {:ok, before_retry} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)

    assert {:ok, %{"status" => "duplicate"}} =
             SalixAgent.Loops.Capabilities.deliver_notification(bound, "Ana replied", "e2")

    assert length(router_inputs(f)) == inputs
    {:ok, after_retry} = CommaWeb.HomeMail.status(f.user, %{}, f.ctx.group_id)
    assert after_retry["sources"] == before_retry["sources"]
  end
end
