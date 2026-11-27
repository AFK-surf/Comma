defmodule SalixWeb.GroupConversationSearchTest do
  @moduledoc """
  Cross-Group conversation search and read (`Salix.Control.Groups`,
  `SalixAgent.ToolDisclosure`, `SalixAgent.Tools.GroupSearch`, and
  `SalixIM.GroupConversationSearch`):

    * `search_group_ids` validation on `Salix.Control.Groups` (same-tenant,
      self-exclusion, 64-group bound);
    * `ToolDisclosure` hides `group.*` when `search_group_ids` is empty and
      discloses `group.search_conversations` with authorized Group names when
      configured;
    * `group.search_conversations` searches authorized peer Groups' `agent_task`
      conversations and Slack/Feishu/Lark mirrors in one call, while excluding
      `user_chat`, 1:1 direct messages (`D*`, `p2p`, IFC `direct` scopes, Tasks
      originated from DMs), `sealed` scopes and `tags`-classified scopes;
    * `group.read_conversation` re-checks current authorization on read and
      stamps returned results with the caller Group's `{:group, caller_group_id}`
      IFC label;
    * a station Task's Worker (`SalixAgent.StationToolCalls.tools/1`) sees the
      same authorized target Groups, and a round's `call` dispatch
      (`SalixAgent.SessionToolDispatch`) returns the caller Group's label;
    * Groups sharing a Slack workspace or Feishu app share one mirror query and
      one hit per message; Feishu/Lark take the `-exclude` syntax; QQ 1:1
      chats (`c2c`, `private`) are neither searched nor read;
    * a Task created through `im_api.internal.task.create` from a Comma
      `user_chat` (and a Task created from that Task), a Feishu `p2p` chat or
      a Slack `D*`/`G*` chat is neither searched nor read, while one from a
      public channel is;
    * a whole-chat Feishu read of a hit is the window around that hit;
    * a target Group with IFC on is authorized only for a caller with IFC on;
    * a round snapshot's `group.*` disclosure follows `search_group_ids`;
    * every authorized Group keeps its newest Task matches in one search;
    * only a supervisor of the caller Group may have the agent search or read.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_search_jobs]

  alias SalixAgent.{SessionToolDispatch, StationToolCalls, ToolCallProvenance, ToolDisclosure}
  alias SalixAgent.Tools.GroupSearch
  alias SalixIFC.Codec
  alias SalixIM.{ConversationSearchProjection, ConversationServer, GroupConversationSearch}
  alias SalixStore.{CasRecord, ConversationSearch, IFC, Ids, Keys}

  @supervisor "provider_user|imc_exec|U_SUP"

  @doc "Tells the test process of a mirror search a fake reader answered."
  def report_search(provider, scope, opts) do
    case SystemsRuntime.get_env(:salix_web, :group_search_test_pid) do
      pid when is_pid(pid) ->
        SystemsRuntime.Proc.send(pid, {:mirror_search, provider, scope, opts})

      _none ->
        :ok
    end
  end

  defmodule FakeSlackReader do
    @moduledoc false
    def search(%{"workspace_id" => "T_ENG"} = scope, opts) do
      SalixWeb.GroupConversationSearchTest.report_search(:slack, scope, opts)
      patterns = Keyword.get(opts, :patterns, [])

      rows = [
        %{
          "channel" => "C_PUB",
          "ts" => "1700000010.000100",
          "user" => "U1",
          "text" => "deploying paymentservice v2"
        },
        %{
          "channel" => "D_DM",
          "ts" => "1700000011.000100",
          "user" => "U2",
          "text" => "private salary paymentservice"
        },
        %{
          "channel" => "C_SEALED",
          "ts" => "1700000012.000100",
          "user" => "U3",
          "text" => "sealed acquisition paymentservice"
        },
        %{
          "channel" => "C_TAGGED",
          "ts" => "1700000013.000100",
          "user" => "U4",
          "text" => "tagged board paymentservice"
        }
      ]

      matched =
        Enum.filter(rows, fn row ->
          Enum.all?(List.flatten(patterns), fn pat ->
            needle = pat |> String.trim("%") |> String.downcase()
            String.contains?(String.downcase(row["text"]), needle)
          end)
        end)

      {:ok, %{messages: matched, has_more?: false, next_cursor: nil}}
    end

    def search(_scope, _opts), do: {:ok, %{messages: [], has_more?: false, next_cursor: nil}}

    def replies(%{"channel_id" => "C_PUB"}, _thread_ts, _opts) do
      {:ok,
       %{
         messages: [
           %{
             "ts" => "1700000010.000100",
             "user" => "U1",
             "text" => "deploying paymentservice v2"
           },
           %{"ts" => "1700000020.000100", "user" => "U2", "text" => "rollout green"}
         ]
       }}
    end

    def history(%{"channel_id" => "C_PUB"}, _opts) do
      {:ok,
       %{
         messages: [
           %{"ts" => "1700000010.000100", "user" => "U1", "text" => "deploying paymentservice v2"}
         ]
       }}
    end
  end

  defmodule FakeMirrorNoop do
    @moduledoc false
    def record_batch(_rows), do: :ok
  end

  defmodule FakeFeishuLarkReader do
    @moduledoc """
    The Feishu and Lark mirror index: AND of `patterns`, rows matching any of
    `exclude_patterns` dropped, optional `chat_id`.
    """
    def search(%{"app_id" => app_id} = scope, opts)
        when app_id in ["cli_feishu_prod", "cli_lark_prod"] do
      SalixWeb.GroupConversationSearchTest.report_search(:feishu_or_lark, scope, opts)
      chat_filter = Keyword.get(opts, :chat_id)
      patterns = Keyword.get(opts, :patterns, [])
      excludes = Keyword.get(opts, :exclude_patterns, [])

      rows = [
        %{
          "message_id" => "om_pub_1",
          "chat_id" => "oc_pub_room",
          "chat_type" => "group",
          "thread_id" => "",
          "actor_id" => "ou_1",
          "actor_label" => "Lin",
          "text" => "paymentservice latency dropped 40%",
          "create_time_us" => 1_700_000_050_000_000
        },
        %{
          "message_id" => "om_dm_1",
          "chat_id" => "oc_dm_room",
          "chat_type" => "p2p",
          "thread_id" => "",
          "actor_id" => "ou_2",
          "actor_label" => "Private",
          "text" => "paymentservice p2p secret",
          "create_time_us" => 1_700_000_060_000_000
        },
        %{
          "message_id" => "om_sealed_1",
          "chat_id" => "oc_sealed_room",
          "chat_type" => "group",
          "thread_id" => "",
          "actor_id" => "ou_3",
          "actor_label" => "Exec",
          "text" => "paymentservice sealed roadmap",
          "create_time_us" => 1_700_000_070_000_000
        },
        %{
          "message_id" => "om_legacy_1",
          "chat_id" => "oc_pub_room",
          "chat_type" => "group",
          "thread_id" => "",
          "actor_id" => "ou_4",
          "actor_label" => "Ops",
          "text" => "paymentservice legacy cluster retired",
          "create_time_us" => 1_700_000_080_000_000
        }
      ]

      filtered =
        rows
        |> Enum.filter(fn row -> is_nil(chat_filter) or row["chat_id"] == chat_filter end)
        |> Enum.filter(fn row ->
          patterns == [] or
            Enum.all?(patterns, fn pat ->
              needle = pat |> String.trim("%") |> String.downcase()
              String.contains?(String.downcase(row["text"]), needle)
            end)
        end)
        |> Enum.reject(fn row ->
          Enum.any?(excludes, fn pat ->
            String.contains?(
              String.downcase(row["text"]),
              pat |> String.trim("%") |> String.downcase()
            )
          end)
        end)

      {:ok, %{messages: filtered, has_more?: false, next_cursor: nil}}
    end

    # One busy group chat of 30 messages, 1000 s apart; only the 15th says
    # "needle". Honors `chat_id`, `patterns`, `before_us`, `sort_dir`, `limit`.
    def search(%{"app_id" => "cli_feishu_window"} = scope, opts) do
      SalixWeb.GroupConversationSearchTest.report_search(:feishu_or_lark, scope, opts)
      patterns = Keyword.get(opts, :patterns, [])
      before_us = Keyword.get(opts, :before_us)

      rows =
        for i <- 1..30 do
          %{
            "message_id" => "om_window_#{i}",
            "chat_id" => "oc_window",
            "chat_type" => "group",
            "thread_id" => "",
            "actor_id" => "ou_w",
            "actor_label" => "Wen",
            "text" => if(i == 15, do: "window message #{i} needle", else: "window message #{i}"),
            "create_time_us" => window_time_us(i)
          }
        end

      rows =
        rows
        |> Enum.filter(&(Keyword.get(opts, :chat_id) in [nil, &1["chat_id"]]))
        |> Enum.filter(&(is_nil(before_us) or &1["create_time_us"] < before_us))
        |> Enum.filter(fn row ->
          Enum.all?(patterns, &String.contains?(row["text"], String.trim(&1, "%")))
        end)
        |> Enum.sort_by(& &1["create_time_us"], Keyword.get(opts, :sort_dir, :desc))
        |> Enum.take(Keyword.get(opts, :limit, 30))

      {:ok, %{messages: rows, has_more?: false, next_cursor: nil}}
    end

    def search(_scope, _opts), do: {:ok, %{messages: [], has_more?: false, next_cursor: nil}}

    def window_time_us(i), do: 1_700_100_000_000_000 + i * 1_000_000_000
  end

  defmodule FakeAgentDelivery do
    @moduledoc "Takes a new Task's delivery without running a round."
    def notify_conversation(_agent_id, _source), do: :ok
    def prepare_conversation_input(_agent_id), do: :ok
    def deliver(_agent_id, _payload, _opts), do: {:ok, %{}}
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  defmodule FakeQQReader do
    @moduledoc "The QQ mirror index: one group chat and two 1:1 chats (`c2c`, `private`)."
    @rows [
      %{
        "message_id" => "qq_grp_1",
        "chat_id" => "qq_group_room",
        "chat_type" => "group",
        "actor_id" => "qq_u1",
        "actor_label" => "Wei",
        "text" => "paymentservice canary on qq group",
        "create_time_us" => 1_700_000_090_000_000
      },
      %{
        "message_id" => "qq_c2c_1",
        "chat_id" => "qq_c2c_room",
        "chat_type" => "c2c",
        "actor_id" => "qq_u2",
        "actor_label" => "Private",
        "text" => "paymentservice c2c secret",
        "create_time_us" => 1_700_000_091_000_000
      },
      %{
        "message_id" => "qq_private_1",
        "chat_id" => "qq_private_room",
        "chat_type" => "private",
        "actor_id" => "qq_u3",
        "actor_label" => "Private",
        "text" => "paymentservice private secret",
        "create_time_us" => 1_700_000_092_000_000
      }
    ]

    def search(%{"app_id" => "qq_app_prod"} = scope, opts) do
      SalixWeb.GroupConversationSearchTest.report_search(:qq, scope, opts)
      chat_filter = Keyword.get(opts, :chat_id)
      patterns = Keyword.get(opts, :patterns, [])

      rows =
        @rows
        |> Enum.filter(&(is_nil(chat_filter) or &1["chat_id"] == chat_filter))
        |> Enum.filter(fn row ->
          Enum.all?(patterns, fn pat ->
            String.contains?(
              String.downcase(row["text"]),
              pat |> String.trim("%") |> String.downcase()
            )
          end)
        end)

      {:ok, %{messages: rows, has_more?: false, next_cursor: nil}}
    end

    def search(_scope, _opts), do: {:ok, %{messages: [], has_more?: false, next_cursor: nil}}
  end

  @env_keys [
    {:salix_store, :s3_backend},
    {:salix_agent, :group_context_mod},
    {:salix_agent, :group_runtime_mod},
    {:salix_agent, :group_conversation_search_mod},
    {:salix_im, :slack_message_mirror_mod},
    {:salix_im, :slack_triage_clickhouse_reader_mod},
    {:salix_im, :feishu_message_mirror_mod},
    {:salix_im, :feishu_mirror_reader_mod},
    {:salix_im, :lark_message_record_mod},
    {:salix_im, :lark_message_record_reader_mod},
    {:salix_im, :qq_message_record_mod},
    {:salix_im, :qq_message_record_reader_mod},
    {:salix_im, :agent_delivery_mod},
    {:salix_web, :group_search_test_pid}
  ]

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Map.new(@env_keys, fn {app, key} -> {{app, key}, SystemsRuntime.get_env(app, key)} end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :group_context_mod, Salix.Bindings.AgentGroupContext)
    SystemsRuntime.put_env(:salix_agent, :group_runtime_mod, Salix.Bindings.AgentGroupRuntime)
    SystemsRuntime.put_env(:salix_agent, :group_conversation_search_mod, GroupConversationSearch)
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, FakeSlackReader)
    SystemsRuntime.put_env(:salix_im, :feishu_message_mirror_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :feishu_mirror_reader_mod, FakeFeishuLarkReader)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_reader_mod, FakeFeishuLarkReader)
    SystemsRuntime.put_env(:salix_im, :qq_message_record_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :qq_message_record_reader_mod, FakeQQReader)
    SystemsRuntime.put_env(:salix_web, :group_search_test_pid, SystemsRuntime.Proc.self())

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(prev, fn
        {{app, key}, nil} -> SystemsRuntime.delete_env(app, key)
        {{app, key}, val} -> SystemsRuntime.put_env(app, key, val)
      end)
    end)

    SalixAgent.TestSupport.configure_platform_models!()

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Acme Org"})
    tenant_id = tenant["tenant_id"]

    {:ok, exec_group} = Salix.Control.Groups.create(%{"name" => "Management"}, tenant_id)
    {:ok, eng_group} = Salix.Control.Groups.create(%{"name" => "Engineering"}, tenant_id)
    {:ok, prod_group} = Salix.Control.Groups.create(%{"name" => "Product"}, tenant_id)
    {:ok, hr_group} = Salix.Control.Groups.create(%{"name" => "HR"}, tenant_id)

    {:ok, _} =
      Salix.Control.Groups.update(
        exec_group["group_id"],
        %{"ifc" => %{"supervisors" => [@supervisor]}},
        tenant_id
      )

    {:ok, exec_router} =
      SalixAgent.Control.create(
        %{"group_id" => exec_group["group_id"], "name" => "Exec Router", "role" => "router"},
        tenant_id
      )

    %{
      tenant_id: tenant_id,
      exec_group: exec_group,
      eng_group: eng_group,
      prod_group: prod_group,
      hr_group: hr_group,
      exec_router: exec_router
    }
  end

  test "validates search_group_ids on group control and gates ToolDisclosure with group names", %{
    tenant_id: tenant_id,
    exec_group: exec_group,
    eng_group: eng_group,
    prod_group: prod_group
  } do
    {:ok, other_tenant} = Salix.Control.Tenants.create(%{"name" => "Other Org"})

    {:ok, foreign_group} =
      Salix.Control.Groups.create(%{"name" => "Foreign"}, other_tenant["tenant_id"])

    # Cross-tenant group_id is rejected at control plane write.
    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(exec_group["group_id"], %{
               "search_group_ids" => [foreign_group["group_id"]]
             })

    # Without search_group_ids, group.* tools are omitted from ToolDisclosure.
    ctx = %{
      tenant_id: tenant_id,
      group_id: exec_group["group_id"],
      agent_id: "agt_test"
    }

    unconfigured = ToolDisclosure.materialize_static("router", :internal, ctx)
    refute Enum.any?(unconfigured["tools"], &String.starts_with?(&1["name"], "group."))

    # Updating search_group_ids drops self, deduplicates, and discloses target group names.
    assert {:ok, updated} =
             Salix.Control.Groups.update(exec_group["group_id"], %{
               "search_group_ids" => [
                 exec_group["group_id"],
                 eng_group["group_id"],
                 prod_group["group_id"],
                 eng_group["group_id"]
               ]
             })

    assert updated["search_group_ids"] ==
             Enum.sort([eng_group["group_id"], prod_group["group_id"]])

    configured = ToolDisclosure.materialize_static("router", :internal, ctx)
    search_entry = Enum.find(configured["tools"], &(&1["name"] == "group.search_conversations"))
    read_entry = Enum.find(configured["tools"], &(&1["name"] == "group.read_conversation"))

    assert search_entry["callable"] == true
    assert read_entry["callable"] == true
    assert search_entry["summary"] =~ "Engineering (#{eng_group["group_id"]})"
    assert search_entry["summary"] =~ "Product (#{prod_group["group_id"]})"

    # The Router prompt names every target Group, not a cut first sentence.
    prompt = ToolDisclosure.prompt_section(configured)
    assert prompt =~ "Engineering (#{eng_group["group_id"]})"
    assert prompt =~ "Product (#{prod_group["group_id"]})"
  end

  test "searches authorized peer Groups across Task conversations and Slack/Feishu/Lark mirrors, enforcing DM and IFC exclusions and stamping caller group IFC labels",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         prod_group: prod_group,
         hr_group: hr_group,
         exec_router: exec_router
       } do
    eng_id = eng_group["group_id"]
    prod_id = prod_group["group_id"]
    hr_id = hr_group["group_id"]
    exec_id = exec_group["group_id"]

    # Authorize Management -> [Engineering, Product] (NOT HR).
    {:ok, _} =
      Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id, prod_id]})

    # 1. Engineering: admissible agent_task conversation, plus excluded user_chat and DM-origin agent_task.
    {:ok, ok_task} =
      ConversationServer.create_group_conversation(eng_id, %{
        "title" => "Paymentservice migration plan",
        "kind" => "agent_task",
        "participants" => [user_participant()]
      })

    {:ok, _} =
      ConversationServer.append_group_conversation_message(
        eng_id,
        ok_task["conversation_id"],
        %{
          "content" => "Cut over paymentservice traffic at 02:00 UTC",
          "client_request_id" => "m1"
        }
      )

    {:ok, _dm_chat} =
      ConversationServer.create_group_conversation(eng_id, %{
        "title" => "Paymentservice private user chat",
        "kind" => "user_chat",
        "participants" => [user_participant()]
      })

    {:ok, _dm_task} =
      ConversationServer.create_group_conversation(eng_id, %{
        "title" => "Paymentservice DM-originated task",
        "kind" => "agent_task",
        "source_refs" => %{"chat_type" => "p2p", "chat_id" => "oc_dm_room"},
        "participants" => [user_participant()]
      })

    # HR: unauthorized group has a matching task that must NOT appear.
    {:ok, _hr_task} =
      ConversationServer.create_group_conversation(hr_id, %{
        "title" => "Paymentservice compensation review",
        "kind" => "agent_task",
        "participants" => [user_participant()]
      })

    drain_search_projection!()

    # 2. Engineering Slack connect with public, DM, sealed and tagged channels.
    slack_conn_id = "imc_slack_eng"

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(eng_id, slack_conn_id), %{
               "connect_id" => slack_conn_id,
               "tenant_id" => tenant_id,
               "group_id" => eng_id,
               "provider" => "slack",
               "workspace_id" => "T_ENG"
             })

    {:ok, _} =
      IFC.put_scope_label(tenant_id, eng_id, slack_conn_id, "C_SEALED", %{sealed: true})

    {:ok, _} =
      IFC.put_scope_label(tenant_id, eng_id, slack_conn_id, "C_TAGGED", %{tags: ["board-only"]})

    # 3. Product Feishu + Lark connects with public, p2p and sealed rooms.
    feishu_conn_id = "imc_feishu_prod"
    lark_conn_id = "imc_lark_prod"

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(prod_id, feishu_conn_id), %{
               "connect_id" => feishu_conn_id,
               "tenant_id" => tenant_id,
               "group_id" => prod_id,
               "provider" => "feishu",
               "app_id" => "cli_feishu_prod"
             })

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(prod_id, lark_conn_id), %{
               "connect_id" => lark_conn_id,
               "tenant_id" => tenant_id,
               "group_id" => prod_id,
               "provider" => "lark",
               "app_id" => "cli_lark_prod"
             })

    {:ok, _} =
      IFC.put_scope_label(tenant_id, prod_id, feishu_conn_id, "oc_sealed_room", %{sealed: true})

    {:ok, _} =
      IFC.put_scope_label(tenant_id, prod_id, lark_conn_id, "oc_sealed_room", %{sealed: true})

    # Execute through the Agent tool boundary (`SalixAgent.Tools.GroupSearch`).
    ctx = tool_ctx(exec_router, tenant_id, exec_id)

    {:tool_ifc, search_json, [], search_ifc} =
      GroupSearch.search_conversations(%{"query" => "paymentservice"}, ctx)

    # Outbound IFC label carries caller group's own `{:group, exec_id}` audience!
    assert {:ok, expected_atom} = Codec.encode_atom({:group, exec_id})
    assert search_ifc == %{"label" => [expected_atom]}

    decoded = Jason.decode!(search_json)
    hits = decoded["hits"]

    sources = Enum.map(hits, &{&1["group_id"], &1["source"]}) |> MapSet.new()
    assert MapSet.member?(sources, {eng_id, "task_conversation"})
    assert MapSet.member?(sources, {eng_id, "slack"})
    assert MapSet.member?(sources, {prod_id, "feishu"})
    assert MapSet.member?(sources, {prod_id, "lark"})

    # Excluded items never leak into hits.
    joined = Jason.encode!(hits)
    refute joined =~ "private user chat"
    refute joined =~ "DM-originated"
    refute joined =~ "compensation review"
    refute joined =~ "private salary"
    refute joined =~ "sealed acquisition"
    refute joined =~ "tagged board"
    refute joined =~ "p2p secret"
    refute joined =~ "sealed roadmap"

    # Requesting an unauthorized group_id explicitly is refused.
    assert_raise RuntimeError, ~r/not authorized/, fn ->
      GroupSearch.search_conversations(
        %{"query" => "paymentservice", "group_ids" => [hr_id]},
        ctx
      )
    end

    # Reading an admissible task hit and a Slack thread hit succeeds and stamps caller group IFC.
    task_hit = Enum.find(hits, &(&1["source"] == "task_conversation"))
    slack_hit = Enum.find(hits, &(&1["source"] == "slack"))

    {:tool_ifc, task_read_json, [], read_ifc} =
      GroupSearch.read_conversation(%{"hit_id" => task_hit["hit_id"]}, ctx)

    assert read_ifc == %{"label" => [expected_atom]}
    task_read = Jason.decode!(task_read_json)
    assert task_read["group_id"] == eng_id
    assert task_read["group_name"] == "Engineering"
    assert Enum.any?(task_read["messages"], &(&1["text"] =~ "02:00 UTC"))

    {:tool_ifc, slack_read_json, [], ^read_ifc} =
      GroupSearch.read_conversation(%{"hit_id" => slack_hit["hit_id"]}, ctx)

    slack_read = Jason.decode!(slack_read_json)
    assert length(slack_read["messages"]) == 2

    # Once Engineering is revoked from `search_group_ids`, reading the old `hit_id` is immediately denied.
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [prod_id]})

    assert_raise RuntimeError, ~r/not authorized/, fn ->
      GroupSearch.read_conversation(%{"hit_id" => task_hit["hit_id"]}, ctx)
    end
  end

  test "a station Task's Worker sees the authorized target groups in group.search_conversations",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         prod_group: prod_group
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    prod_id = prod_group["group_id"]

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => exec_id, "name" => "Exec Worker", "role" => "worker"},
        tenant_id
      )

    ref = %{
      tenant_id: tenant_id,
      group_id: exec_id,
      agent_id: worker["agent_id"],
      conversation_id: "cnv_station_task",
      device_id: "dev-sbx-cnv_station_task",
      session: "ember:c-1",
      requester: "usr_1",
      label: nil
    }

    refute Enum.any?(StationToolCalls.tools(ref), &String.starts_with?(&1["name"], "group."))

    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id, prod_id]})

    search = Enum.find(StationToolCalls.tools(ref), &(&1["name"] == "group.search_conversations"))
    assert search["description"] =~ "Engineering (#{eng_id})"
    assert search["description"] =~ "Product (#{prod_id})"
  end

  test "a round's dispatch of group.search_conversations through `call` returns the caller Group's label",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    {:ok, config} =
      SalixAgent.RoundConfig.build_runtime_session_config(exec_router["agent_id"], "router", %{})

    ctx =
      config
      |> Map.take([:tool_disclosure, :plugin_projection])
      |> Map.merge(%{
        agent_id: exec_router["agent_id"],
        tenant_id: tenant_id,
        group_id: exec_id,
        session_id: "s_group_search",
        round_id: "r_group_search",
        role: "router",
        runtime_kind: :internal,
        visible_reply_guard: :clean,
        visible_reply_phase: :clean,
        llm_tool_envelope: true,
        ifc: %{}
      })
      |> Map.merge(turn([{"msg_sup", origin("imc_exec", "U_SUP")}]))

    [result] =
      SessionToolDispatch.execute(
        [
          %{
            "id" => "call_1",
            "name" => "call",
            "args" => %{
              "tool" => "group.search_conversations",
              "params" => %{"query" => "paymentservice"}
            }
          }
        ],
        ctx
      )

    assert result.error == false
    assert {:ok, group_atom} = Codec.encode_atom({:group, exec_id})
    assert result.ifc["label"] == [group_atom]

    assert Enum.any?(
             Jason.decode!(result.content)["hits"],
             &(&1["source"] == "slack" and &1["group_id"] == eng_id)
           )
  end

  test "a round's dispatch refuses group.search_conversations unless every input of the turn is a supervisor's",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    {:ok, config} =
      SalixAgent.RoundConfig.build_runtime_session_config(exec_router["agent_id"], "router", %{})

    supervisor = origin("imc_exec", "U_SUP")
    member = origin("imc_exec", "U_MEMBER")

    dispatch = fn inputs ->
      ctx =
        config
        |> Map.take([:tool_disclosure, :plugin_projection])
        |> Map.merge(%{
          agent_id: exec_router["agent_id"],
          tenant_id: tenant_id,
          group_id: exec_id,
          session_id: "s_group_search_mixed",
          round_id: "r_group_search_mixed",
          role: "router",
          runtime_kind: :internal,
          visible_reply_guard: :clean,
          visible_reply_phase: :clean,
          llm_tool_envelope: true,
          ifc: %{}
        })
        |> Map.merge(turn(inputs))

      [result] =
        SessionToolDispatch.execute(
          [
            %{
              "id" => "call_1",
              "name" => "call",
              "args" => %{
                "tool" => "group.search_conversations",
                "params" => %{"query" => "paymentservice"}
              }
            }
          ],
          ctx
        )

      result
    end

    # A member's request, or an input with no sealed origin, batched before
    # the supervisor's message refuses the call.
    for inputs <- [
          [{"msg_member", member}, {"msg_sup", supervisor}],
          [{"msg_unsealed", nil}, {"msg_sup", supervisor}]
        ] do
      refused = dispatch.(inputs)
      assert refused.error == true
      assert refused.content =~ "only for this group's supervisors"
    end

    # Two messages of the same supervisor, or one, are allowed.
    assert dispatch.([{"msg_sup_1", supervisor}, {"msg_sup_2", supervisor}]).error == false

    alone = dispatch.([{"msg_sup", supervisor}])
    assert alone.error == false
    assert Jason.decode!(alone.content)["hits"] != []
  end

  test "Groups sharing a Slack workspace and a Feishu app send each mirror query once and get each message once",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         prod_group: prod_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    prod_id = prod_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id, prod_id]})

    # Both Groups connect the same Slack workspace and the same Feishu app.
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")
    put_slack_connect!(tenant_id, prod_id, "imc_slack_prod")
    put_app_connect!(tenant_id, eng_id, "imc_feishu_eng", "feishu", "cli_feishu_prod")
    put_app_connect!(tenant_id, prod_id, "imc_feishu_prod", "feishu", "cli_feishu_prod")

    {:tool_ifc, json, [], _ifc} =
      GroupSearch.search_conversations(
        %{"query" => "paymentservice"},
        tool_ctx(exec_router, tenant_id, exec_id)
      )

    assert_received {:mirror_search, :slack, %{"workspace_id" => "T_ENG"}, _}
    refute_received {:mirror_search, :slack, _, _}
    assert_received {:mirror_search, :feishu_or_lark, %{"app_id" => "cli_feishu_prod"}, _}
    refute_received {:mirror_search, :feishu_or_lark, _, _}

    hits = Jason.decode!(json)["hits"]
    first_group = Enum.min([eng_id, prod_id])

    assert [%{"group_id" => ^first_group}] =
             Enum.filter(hits, &(&1["source"] == "slack" and &1["channel_id"] == "C_PUB"))

    assert [%{"group_id" => ^first_group}] =
             Enum.filter(hits, &(&1["source"] == "feishu" and &1["snippet"] =~ "latency dropped"))
  end

  test "Feishu and Lark take -exclude terms; QQ 1:1 chats are neither searched nor read",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         prod_group: prod_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    prod_id = prod_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [prod_id]})

    put_app_connect!(tenant_id, prod_id, "imc_feishu_prod", "feishu", "cli_feishu_prod")
    put_app_connect!(tenant_id, prod_id, "imc_lark_prod", "lark", "cli_lark_prod")
    put_app_connect!(tenant_id, prod_id, "imc_qq_prod", "qq", "qq_app_prod")
    ctx = tool_ctx(exec_router, tenant_id, exec_id)

    {:tool_ifc, json, [], _ifc} =
      GroupSearch.search_conversations(%{"query" => "paymentservice -legacy"}, ctx)

    for app_id <- ["cli_feishu_prod", "cli_lark_prod"] do
      assert_received {:mirror_search, :feishu_or_lark, %{"app_id" => ^app_id}, opts}
      assert opts[:patterns] == ["%paymentservice%"]
      assert opts[:exclude_patterns] == ["%legacy%"]
    end

    assert_received {:mirror_search, :qq, %{"app_id" => "qq_app_prod"}, _opts}

    hits = Jason.decode!(json)["hits"]
    assert MapSet.new(hits, & &1["source"]) == MapSet.new(["feishu", "lark", "qq"]), inspect(hits)

    joined = Jason.encode!(hits)
    refute joined =~ "legacy cluster"
    refute joined =~ "c2c secret"
    refute joined =~ "private secret"

    qq_hit = Enum.find(hits, &(&1["source"] == "qq"))
    assert qq_hit["chat_id"] == "qq_group_room"

    {:tool_ifc, read_json, [], _ifc} =
      GroupSearch.read_conversation(%{"hit_id" => qq_hit["hit_id"]}, ctx)

    assert [%{"text" => "paymentservice canary on qq group"}] =
             Jason.decode!(read_json)["messages"]

    for chat_id <- ["qq_c2c_room", "qq_private_room"] do
      hit_id =
        GroupConversationSearch.encode_hit_id(%{
          "k" => "qq",
          "g" => prod_id,
          "cn" => "imc_qq_prod",
          "ch" => chat_id
        })

      assert_raise RuntimeError, ~r/not accessible/, fn ->
        GroupSearch.read_conversation(%{"hit_id" => hit_id}, ctx)
      end
    end
  end

  test "Tasks created through internal.task.create from private chats are neither searched nor read",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         exec_router: exec_router
       } do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    {:ok, eng_router} =
      SalixAgent.Control.create(
        %{"group_id" => eng_id, "name" => "Eng Router", "role" => "router"},
        tenant_id
      )

    {:ok, eng_worker} =
      SalixAgent.Control.create(
        %{"group_id" => eng_id, "name" => "Eng Worker", "role" => "worker"},
        tenant_id
      )

    {:ok, _} =
      Salix.Control.Groups.update(eng_id, %{"router_agent_id" => eng_router["agent_id"]})

    {:ok, session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(eng_router["agent_id"], eng_id)

    create = fn name, origin, context ->
      assert {:ok, %{"conversation_id" => id}} =
               Salix.Bindings.AgentIMProvider.call_api(
                 eng_router["agent_id"],
                 "internal",
                 "internal.task.create",
                 %{
                   "connect_id" => "internal",
                   "tool_call_id" => "group-search-#{name}",
                   "params" => %{
                     "agent_id" => eng_worker["agent_id"],
                     "content" => "Look into the paymentservice report for #{name}",
                     "title" => "Paymentservice report #{name}",
                     "runs_on" => %{"kind" => "default"}
                   },
                   "tool_context" =>
                     Map.merge(
                       %{
                         "runtime_kind" => "internal",
                         "session_id" => session_id,
                         "trusted_origin" => origin
                       },
                       context
                     )
                 }
               )

      id
    end

    # The Message a Task is asked for from: a new one in a chat, or the
    # request a Task already holds.
    internal_origin = fn kind, conversation_id ->
      message_id =
        if kind == "user_chat" do
          {:ok, %{"message_id" => message_id}} =
            ConversationServer.append_group_conversation_message(eng_id, conversation_id, %{
              "content" => "Please look into the paymentservice report",
              "client_request_id" => "ask-#{conversation_id}"
            })

          message_id
        else
          {:ok, [message | _]} =
            SalixIM.Conversations.list_group_conversation_messages(eng_id, conversation_id,
              tail: 1
            )

          message["message_id"]
        end

      participant_id = Ids.new_participant_id()

      {:ok, source} =
        SalixIM.ConversationSourceIdentity.encode(conversation_id, message_id, participant_id)

      {%{
         "provider" => "internal",
         "agent_group_id" => eng_id,
         "conversation_kind" => kind,
         "conversation_id" => conversation_id,
         "message_id" => message_id,
         "participant_id" => participant_id
       }, %{"source_message_id" => source}}
    end

    provider_origin = fn provider, context ->
      %{
        "provider" => provider,
        "agent_group_id" => eng_id,
        "source_actor_type" => "provider_user",
        "source_message_id" => "#{provider}-#{context["channel_id"] || context["chat_id"]}",
        "provider_context" => context
      }
    end

    {:ok, user_chat} =
      ConversationServer.create_group_conversation(eng_id, %{
        "title" => "Lin and the Router",
        "kind" => "user_chat",
        "participants" => [user_participant()]
      })

    {origin, context} = internal_origin.("user_chat", user_chat["conversation_id"])
    comma_task = create.("comma-dm", origin, context)
    {origin, context} = internal_origin.("agent_task", comma_task)
    child_task = create.("comma-dm-child", origin, context)

    feishu_task =
      create.(
        "feishu-p2p",
        provider_origin.("feishu", %{
          "connect_id" => "imc_feishu_eng",
          "chat_id" => "oc_p2p_lin",
          "chat_type" => "p2p"
        }),
        %{}
      )

    slack_dm_task =
      create.(
        "slack-dm",
        provider_origin.("slack", %{"connect_id" => "imc_slack_eng", "channel_id" => "D_LIN"}),
        %{}
      )

    slack_mpim_task =
      create.(
        "slack-mpim",
        provider_origin.("slack", %{"connect_id" => "imc_slack_eng", "channel_id" => "G_TRIO"}),
        %{}
      )

    public_task =
      create.(
        "slack-public",
        provider_origin.("slack", %{
          "connect_id" => "imc_slack_eng",
          "channel_id" => "C_PUB",
          "channel_type" => "channel"
        }),
        %{}
      )

    # The origin is sealed server-side and no generic update can replace it.
    assert {:ok, record} =
             SalixIM.Conversations.get_group_conversation_record(eng_id, slack_dm_task)

    assert record["source_refs"]["origin_chat"] == %{
             "provider" => "slack",
             "connect_id" => "imc_slack_eng",
             "scope_id" => "D_LIN"
           }

    assert {:error, _} =
             ConversationServer.update_group_conversation(eng_id, slack_dm_task, %{
               "source_refs" =>
                 Map.put(record["source_refs"], "origin_chat", %{"provider" => "slack"})
             })

    drain_search_projection!()
    ctx = tool_ctx(exec_router, tenant_id, exec_id)

    {:tool_ifc, json, [], _ifc} =
      GroupSearch.search_conversations(%{"query" => "paymentservice report"}, ctx)

    found =
      json
      |> Jason.decode!()
      |> Map.fetch!("hits")
      |> Enum.filter(&(&1["source"] == "task_conversation"))
      |> Enum.map(& &1["conversation_id"])

    assert found == [public_task]

    {:tool_ifc, read_json, [], _ifc} =
      GroupSearch.read_conversation(%{"hit_id" => task_hit_id(eng_id, public_task)}, ctx)

    assert Jason.decode!(read_json)["conversation_id"] == public_task

    for task <- [comma_task, child_task, feishu_task, slack_dm_task, slack_mpim_task] do
      assert_raise RuntimeError, ~r/not accessible/, fn ->
        GroupSearch.read_conversation(%{"hit_id" => task_hit_id(eng_id, task)}, ctx)
      end
    end
  end

  test "reading a whole-chat Feishu hit returns the window around it, not the chat's first messages",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         prod_group: prod_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    prod_id = prod_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [prod_id]})
    put_app_connect!(tenant_id, prod_id, "imc_feishu_window", "feishu", "cli_feishu_window")
    ctx = tool_ctx(exec_router, tenant_id, exec_id)

    {:tool_ifc, json, [], _ifc} = GroupSearch.search_conversations(%{"query" => "needle"}, ctx)
    assert [hit] = Jason.decode!(json)["hits"]

    {:tool_ifc, read_json, [], _ifc} =
      GroupSearch.read_conversation(%{"hit_id" => hit["hit_id"], "limit" => 3}, ctx)

    assert Enum.map(Jason.decode!(read_json)["messages"], & &1["message_id"]) ==
             ["om_window_13", "om_window_14", "om_window_15"]

    # A hit without its time reads the newest messages, still oldest first.
    legacy =
      GroupConversationSearch.encode_hit_id(%{
        "k" => "feishu",
        "g" => prod_id,
        "cn" => "imc_feishu_window",
        "ch" => "oc_window",
        "th" => ""
      })

    {:tool_ifc, legacy_json, [], _ifc} =
      GroupSearch.read_conversation(%{"hit_id" => legacy, "limit" => 3}, ctx)

    assert Enum.map(Jason.decode!(legacy_json)["messages"], & &1["message_id"]) ==
             ["om_window_28", "om_window_29", "om_window_30"]
  end

  test "a target Group with IFC on is searchable only by a caller Group with IFC on",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    {:ok, _} = Salix.Control.Groups.update(eng_id, %{"ifc" => %{"mode" => "enforce"}})

    {:ok, task} =
      ConversationServer.create_group_conversation(eng_id, %{
        "title" => "Paymentservice capacity review",
        "kind" => "agent_task",
        "participants" => [user_participant()]
      })

    drain_search_projection!()
    ctx = tool_ctx(exec_router, tenant_id, exec_id)
    disclosure_ctx = %{tenant_id: tenant_id, group_id: exec_id, agent_id: exec_router["agent_id"]}
    hit_id = task_hit_id(eng_id, task["conversation_id"])

    assert {:ok, %{groups: []}} = GroupConversationSearch.authorized_groups(exec_id)

    refute Enum.any?(
             ToolDisclosure.materialize_static("router", :internal, disclosure_ctx)["tools"],
             &String.starts_with?(&1["name"], "group.")
           )

    assert_raise RuntimeError, ~r/not available/, fn ->
      GroupSearch.search_conversations(%{"query" => "paymentservice"}, ctx)
    end

    assert_raise RuntimeError, ~r/not available/, fn ->
      GroupSearch.read_conversation(%{"hit_id" => hit_id}, ctx)
    end

    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"ifc" => %{"mode" => "enforce"}})

    {:tool_ifc, json, [], search_ifc} =
      GroupSearch.search_conversations(%{"query" => "paymentservice"}, ctx)

    assert {:ok, caller_atom} = Codec.encode_atom({:group, exec_id})
    assert search_ifc == %{"label" => [caller_atom]}

    assert [%{"conversation_id" => conversation_id}] = Jason.decode!(json)["hits"]
    assert conversation_id == task["conversation_id"]

    {:tool_ifc, _read_json, [], read_ifc} =
      GroupSearch.read_conversation(%{"hit_id" => hit_id}, ctx)

    assert read_ifc == %{"label" => [caller_atom]}
  end

  test "a round snapshot discloses group.* as soon as search_group_ids changes",
       %{exec_group: exec_group, eng_group: eng_group, exec_router: exec_router} do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    agent_id = exec_router["agent_id"]

    assert {:ok, snapshot} = SalixAgent.RoundConfig.build_round_snapshot(agent_id, %{})
    refute Enum.any?(disclosed(snapshot), &String.starts_with?(&1["name"], "group."))

    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})

    assert {:ok, refreshed} =
             SalixAgent.RoundConfig.refresh_round_snapshot(agent_id, snapshot, %{})

    search = Enum.find(disclosed(refreshed), &(&1["name"] == "group.search_conversations"))
    assert search["summary"] =~ "Engineering (#{eng_id})"
  end

  test "each authorized Group keeps its newest Task matches, in the same order every time",
       %{
         tenant_id: tenant_id,
         exec_group: exec_group,
         eng_group: eng_group,
         prod_group: prod_group,
         exec_router: exec_router
       } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    prod_id = prod_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id, prod_id]})

    for n <- 1..30 do
      {:ok, _} =
        ConversationServer.create_group_conversation(eng_id, %{
          "title" => "Crowdtoken backlog item #{n}",
          "kind" => "agent_task",
          "participants" => [user_participant()]
        })
    end

    drain_search_projection!()

    prod_tasks =
      for n <- 1..2 do
        {:ok, task} =
          ConversationServer.create_group_conversation(prod_id, %{
            "title" => "Crowdtoken launch item #{n}",
            "kind" => "agent_task",
            "participants" => [user_participant()]
          })

        task["conversation_id"]
      end

    drain_search_projection!()

    search = fn ->
      {:tool_ifc, json, [], _ifc} =
        GroupSearch.search_conversations(
          %{"query" => "crowdtoken", "limit" => 5},
          tool_ctx(exec_router, tenant_id, exec_id)
        )

      Enum.map(Jason.decode!(json)["hits"], &{&1["group_id"], &1["conversation_id"]})
    end

    first = search.()
    assert length(first) == 5
    assert MapSet.subset?(MapSet.new(prod_tasks, &{prod_id, &1}), MapSet.new(first))
    assert Enum.count(first, &(elem(&1, 0) == eng_id)) == 3

    for _ <- 1..3, do: assert(search.() == first)

    assert {:ok, rows} =
             ConversationSearch.search_groups([eng_id, prod_id], "crowdtoken", limit: 5)

    assert Enum.count(rows, &(&1["group_id"] == prod_id)) == 2
    assert Enum.count(rows, &(&1["group_id"] == eng_id)) == 5

    for _ <- 1..3 do
      assert {:ok, ^rows} =
               ConversationSearch.search_groups([eng_id, prod_id], "crowdtoken", limit: 5)
    end
  end

  test "only a supervisor of the caller Group may have the agent search or read", %{
    tenant_id: tenant_id,
    exec_group: exec_group,
    eng_group: eng_group,
    exec_router: exec_router
  } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    {:tool_ifc, json, [], _ifc} =
      GroupSearch.search_conversations(
        %{"query" => "paymentservice"},
        tool_ctx(exec_router, tenant_id, exec_id)
      )

    hit_id = json |> Jason.decode!() |> Map.fetch!("hits") |> hd() |> Map.fetch!("hit_id")

    member = tool_ctx(exec_router, tenant_id, exec_id, origin("imc_exec", "U_MEMBER"))
    nobody = Map.merge(tool_ctx(exec_router, tenant_id, exec_id), turn([{"msg_unsealed", nil}]))

    for ctx <- [member, nobody] do
      assert_raise RuntimeError, ~r/only for this group's supervisors/, fn ->
        GroupSearch.search_conversations(%{"query" => "paymentservice"}, ctx)
      end

      assert_raise RuntimeError, ~r/only for this group's supervisors/, fn ->
        GroupSearch.read_conversation(%{"hit_id" => hit_id}, ctx)
      end
    end

    # Removing the supervisor takes effect on the next call.
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"ifc" => %{"supervisors" => []}})

    assert_raise RuntimeError, ~r/only for this group's supervisors/, fn ->
      GroupSearch.read_conversation(
        %{"hit_id" => hit_id},
        tool_ctx(exec_router, tenant_id, exec_id)
      )
    end
  end

  test "a schedule a supervisor created searches for them while they remain a supervisor", %{
    tenant_id: tenant_id,
    exec_group: exec_group,
    eng_group: eng_group,
    exec_router: exec_router
  } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    {:ok, config} =
      SalixAgent.RoundConfig.build_runtime_session_config(exec_router["agent_id"], "router", %{})

    # A fire as `SalixCluster.Schedules` delivers it: a user message under
    # `schedule:<id>:<at>`, sealed with `SalixAgent.IFC.schedule_origin/3`.
    fire = fn schedule_id, creator ->
      id = "schedule:#{schedule_id}:1700000000000"

      message = %{
        "role" => "user",
        "source_message_id" => id,
        "trusted_origin" => SalixAgent.IFC.schedule_origin(schedule_id, creator, nil)
      }

      origins = ToolCallProvenance.message_origins(message, [id])

      [result] =
        SessionToolDispatch.execute(
          [
            %{
              "id" => "call_1",
              "name" => "call",
              "args" => %{
                "tool" => "group.search_conversations",
                "params" => %{"query" => "paymentservice"}
              }
            }
          ],
          config
          |> Map.take([:tool_disclosure, :plugin_projection])
          |> Map.merge(%{
            agent_id: exec_router["agent_id"],
            tenant_id: tenant_id,
            group_id: exec_id,
            session_id: "s_group_search_schedule",
            round_id: "r_group_search_schedule",
            role: "router",
            runtime_kind: :internal,
            visible_reply_guard: :clean,
            visible_reply_phase: :clean,
            llm_tool_envelope: true,
            ifc: %{},
            source_message_ids: [id],
            trusted_origin: List.last(origins),
            trusted_origins: origins
          })
        )

      result
    end

    allowed = fire.("sch_sup", @supervisor)
    assert allowed.error == false
    assert Jason.decode!(allowed.content)["hits"] != []

    refused = fire.("sch_member", "provider_user|imc_exec|U_MEMBER")
    assert refused.error == true
    assert refused.content =~ "only for this group's supervisors"

    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"ifc" => %{"supervisors" => []}})
    assert fire.("sch_sup", @supervisor).error == true
  end

  test "a Loop a supervisor created searches for them while they remain a supervisor", %{
    tenant_id: tenant_id,
    exec_group: exec_group,
    eng_group: eng_group,
    exec_router: exec_router
  } do
    exec_id = exec_group["group_id"]
    eng_id = eng_group["group_id"]
    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"search_group_ids" => [eng_id]})
    put_slack_connect!(tenant_id, eng_id, "imc_slack_eng")

    agent_id = exec_router["agent_id"]
    elf = <<0x7F, ?E, ?L, ?F, 1, 2, 3>>
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, "/loops/main.elf", elf)

    {:ok, _} =
      SalixAgent.AgentWorkspace.seed_operation(agent_id, "group-search-loop", %{}, [event])

    # The Loop's real host-call entry, with the creator `Loops.create/2`
    # recorded from the round that made it.
    search = fn creator ->
      {:ok, loop} =
        SalixAgent.Loops.create(
          %{
            agent_id: agent_id,
            session_id: SalixStore.Ids.new_session_id(),
            role: "router",
            ifc_evidence: %{"requester" => creator, "sources_label" => ["public"]}
          },
          %{"path" => "/loops/main.elf"}
        )

      {:ok, record} = SalixStore.Loops.get(loop["loop_id"])

      ref = %{
        loop_id: record["id"],
        incarnation: record["incarnation"],
        agent_id: record["agent_id"],
        session_id: record["session_id"],
        tenant_id: record["tenant_id"],
        group_id: record["group_id"],
        task_conversation_id: record["task_conversation_id"],
        name: record["name"],
        ifc: record["ifc"]
      }

      SalixAgent.Loops.Capabilities.call(ref, "group.search_conversations", %{
        "query" => "paymentservice"
      })
    end

    assert {:ok, allowed} = search.(@supervisor)
    refute allowed["error"]
    assert allowed["content"] =~ "hits"

    # A failed tool reaches the guest as `{:error, "tool failed: ..."}`.
    assert {:error, refused} = search.("provider_user|imc_exec|U_MEMBER")
    assert refused =~ "only for this group's supervisors"

    {:ok, _} = Salix.Control.Groups.update(exec_id, %{"ifc" => %{"supervisors" => []}})
    assert {:error, removed} = search.(@supervisor)
    assert removed =~ "only for this group's supervisors"
  end

  defp disclosed(snapshot), do: snapshot.session_config.tool_disclosure["tools"]

  defp task_hit_id(group_id, conversation_id) do
    GroupConversationSearch.encode_hit_id(%{
      "k" => "conversation",
      "g" => group_id,
      "c" => conversation_id
    })
  end

  defp tool_ctx(router, tenant_id, group_id, origin \\ origin("imc_exec", "U_SUP")) do
    %{
      agent_id: router["agent_id"],
      tenant_id: tenant_id,
      group_id: group_id,
      ifc: %{},
      source_message_ids: ["msg_one"],
      trusted_origin: Map.put(origin, "source_message_id", "msg_one"),
      trusted_origins: [Map.put(origin, "source_message_id", "msg_one")]
    }
  end

  defp origin(connect_id, user_id) do
    %{
      "provider" => "slack",
      "principal_ref" => %{"connect_id" => connect_id, "subject_id" => user_id}
    }
  end

  # A turn's inputs as Session messages, and the origins the runtime collects
  # from them (`SalixAgent.SessionToolExecution`).
  defp turn(inputs) do
    messages =
      Enum.map(inputs, fn
        {id, nil} ->
          %{"role" => "user", "source_message_id" => id}

        {id, origin} ->
          %{
            "role" => "user",
            "source_message_id" => id,
            "trusted_origin" => Map.put(origin, "source_message_id", id)
          }
      end)

    ids = Enum.map(inputs, &elem(&1, 0))

    origins =
      messages |> Enum.flat_map(&ToolCallProvenance.message_origins(&1, ids)) |> Enum.uniq()

    %{source_message_ids: ids, trusted_origins: origins, trusted_origin: List.last(origins)}
  end

  defp put_slack_connect!(tenant_id, group_id, connect_id) do
    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "connect_id" => connect_id,
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "provider" => "slack",
               "workspace_id" => "T_ENG"
             })
  end

  defp put_app_connect!(tenant_id, group_id, connect_id, provider, app_id) do
    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "connect_id" => connect_id,
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "provider" => provider,
               "app_id" => app_id
             })
  end

  defp drain_search_projection! do
    case ConversationSearch.claim_one("group-search-test-projector", 30_000) do
      {:ok, nil} ->
        :ok

      {:ok, claim} ->
        assert :ok = ConversationSearchProjection.process_claim(claim)
        assert :ok = ConversationSearch.complete(claim)
        drain_search_projection!()

      {:error, reason} ->
        flunk("Task-search projection claim failed: #{inspect(reason)}")
    end
  end

  defp user_participant do
    %{
      "actor_type" => "user",
      "user_id" => "u_test",
      "state" => "active",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"}
    }
  end
end
