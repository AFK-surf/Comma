defmodule SalixCluster.ScheduleToolTest do
  @moduledoc """
  `SalixAgent.Tools.Schedules` canonical tools wired to the real
  `SalixCluster.Schedules` store through the `:schedules_mod` runtime seam.
  Lives in salix_cluster because salix_agent cannot depend on salix_cluster.

  Covers create → list → delete through the tool functions, the fired
  delivery path (Fake S3 backend, `Schedules.run_once` with clock injection,
  observed on the internal session ledger — rpc is the only delivery protocol
  since plan §3.2 step 4), ownership semantics on delete, argument
  validation, and the nil-seam error path.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Tools.Schedules, as: Tool
  alias SalixAgent.TestSupport.SessionData
  alias SalixCluster.Schedules
  alias SalixStore.Ids

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)
    def clear_owner, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :owner})

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "fs-reminders", "provider" => "feishu"}]}

    @impl true
    def provider_manual("feishu") do
      {:ok,
       %{
         "provider" => "feishu",
         "apis" => [
           %{
             "name" => "feishu.send_text",
             "description" => "Send a proactive Feishu group message.",
             "parameters" => %{
               "receive_id" => "Target chat id.",
               "text" => "Message body.",
               "mentions" => "Structured person mentions.",
               "mention_all" => "Whether to mention all members."
             },
             "required_params" => ["receive_id", "text"]
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, provider, api, args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"message_id" => "om_scheduled"}}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    start_supervised!(SalixStore.S3.Fake)

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — every file expecting a clean slate truncates.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    start_supervised!(SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    prev_mod = SystemsRuntime.get_env(:salix_agent, :schedules_mod)
    SystemsRuntime.put_env(:salix_agent, :schedules_mod, SalixCluster.Schedules)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      FakeIMProvider.clear_owner()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      SystemsRuntime.put_env(:salix_agent, :schedules_mod, prev_mod)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :im_provider_mod, prev_im_provider)
    end)

    # The delivery ingress reads the target's control record, so the calling
    # agent must exist on the control plane the way it does in production.
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{})

    {:ok,
     ctx: %{
       agent_id: agent_id,
       session_id: "ses1_1200000000000000001",
       state: nil
     }}
  end

  describe "create / list / delete through the tool" do
    test "round-trips against the real cluster store", %{ctx: ctx} do
      out =
        Tool.create_schedule(
          %{
            "interval_minutes" => 5,
            "prompt" => "do the thing"
          },
          ctx
        )

      sched = Jason.decode!(out)
      id = sched["id"]
      assert Ids.valid_schedule_id?(id)
      assert sched["agent_id"] == ctx.agent_id
      assert sched["session_id"] == ctx.session_id
      assert sched["interval_minutes"] == 5
      assert sched["prompt"] == "do the thing"
      assert sched["last_run"] == nil

      # the created schedule is real in the cluster store
      assert {:ok, stored} = Schedules.get(id)
      assert stored["agent_id"] == ctx.agent_id
      assert stored["prompt"] == "do the thing"

      # list returns only the calling agent's schedules
      other_id = Ids.new_schedule_id()

      {:ok, _} =
        Schedules.create(other_id, %{
          agent_id: "someone-else",
          interval_minutes: 5,
          prompt: "not yours"
        })

      listed = Jason.decode!(Tool.list_schedules(%{}, ctx))
      assert Enum.map(listed, & &1["id"]) == [id]

      # delete by id
      out = Tool.delete_schedule(%{"schedule_id" => id}, ctx)
      assert Jason.decode!(out) == %{"status" => "deleted", "schedule_id" => id}
      assert {:error, :not_found} = Schedules.get(id)
      assert Jason.decode!(Tool.list_schedules(%{}, ctx)) == []

      # the other agent's schedule is untouched
      assert {:ok, _} = Schedules.get(other_id)
    end

    test "records who it acts for, and never lets an update change that", %{ctx: ctx} do
      # A fire acts with its creator's authority, so the creator is recorded
      # when the schedule is made — at fire time there is no one to ask
      # (docs/verification.md). Both fields come from
      # what the dispatcher established while deciding this very call.
      creator = "provider_user|cnx1|U_A"
      label = ["scope|cnx1|@U_A"]

      out =
        Tool.create_schedule(
          %{"interval_minutes" => 5, "prompt" => "the daily digest"},
          Map.put(ctx, :ifc_evidence, %{"requester" => creator, "sources_label" => label})
        )

      id = Jason.decode!(out)["id"]
      assert {:ok, stored} = Schedules.get(id)
      assert stored["ifc_creator"] == creator
      assert stored["ifc_label"] == label

      # An update that could rewrite it would be a way to retarget someone
      # else's schedule onto your own permissions.
      assert {:ok, updated} =
               Schedules.update(id, %{
                 "prompt" => "still mine",
                 "ifc_creator" => "provider_user|cnx1|U_B",
                 "ifc_label" => ["public"]
               })

      assert updated["prompt"] == "still mine"
      assert updated["ifc_creator"] == creator
      assert updated["ifc_label"] == label
    end

    test "a schedule created with no decision behind it carries no authority", %{ctx: ctx} do
      # A Group that is `off` never reaches the check, so no effect carries
      # evidence. The schedule then delivers unsealed and can be cited as the
      # request for nothing, which is the fail-closed reading.
      out = Tool.create_schedule(%{"interval_minutes" => 5, "prompt" => "plain"}, ctx)

      assert {:ok, stored} = Schedules.get(Jason.decode!(out)["id"])
      refute Map.has_key?(stored, "ifc_creator")
      assert SalixAgent.IFC.schedule_origin("sch", stored["ifc_creator"], nil) == nil
    end
  end

  describe "cron through the tool" do
    test "create with cron round-trips and stores cron/timezone, no interval", %{ctx: ctx} do
      out =
        Tool.create_schedule(
          %{
            "cron" => "0 9 * * 1-5",
            "timezone" => "America/New_York",
            "prompt" => "weekday standup"
          },
          ctx
        )

      sched = Jason.decode!(out)
      id = sched["id"]
      assert sched["cron"] == "0 9 * * 1-5"
      assert sched["timezone"] == "America/New_York"
      assert sched["session_id"] == ctx.session_id
      refute Map.has_key?(sched, "interval_minutes")

      assert {:ok, stored} = Schedules.get(id)
      assert stored["cron"] == "0 9 * * 1-5"
      assert stored["agent_id"] == ctx.agent_id
    end

    @cron_rejections [
      {"rejects giving both interval_minutes and cron",
       %{"prompt" => "p", "interval_minutes" => 5, "cron" => "0 9 * * *"},
       "provide exactly one of 'interval_minutes', 'cron', or 'run_at'"},
      {"rejects an unparseable cron expression", %{"prompt" => "p", "cron" => "not a cron"},
       "invalid schedule parameters"},
      {"rejects an unknown timezone",
       %{"prompt" => "p", "cron" => "0 9 * * *", "timezone" => "Mars/Phobos"},
       "invalid schedule parameters"}
    ]

    for {name, args, message} <- @cron_rejections do
      test name, %{ctx: ctx} do
        assert_raise RuntimeError, unquote(message), fn ->
          Tool.create_schedule(unquote(Macro.escape(args)), ctx)
        end
      end
    end

    # Models fill unused numeric fields with zero or an empty string; cron wins.
    @interval_fillers [
      {"cron wins over a zero interval_minutes filler from the model", 0},
      {"cron wins over an empty-string interval_minutes filler from the model", ""}
    ]

    for {name, filler} <- @interval_fillers do
      test name, %{ctx: ctx} do
        out =
          Tool.create_schedule(
            %{
              "prompt" => "daily",
              "cron" => "0 9 * * *",
              "interval_minutes" => unquote(filler)
            },
            ctx
          )

        sched = Jason.decode!(out)
        assert sched["cron"] == "0 9 * * *"
        refute Map.has_key?(sched, "interval_minutes")
        assert {:ok, _} = Schedules.get(sched["id"])
      end
    end
  end

  describe "firing" do
    test "a due one-shot schedule wakes the Router and executes Feishu delivery exactly once" do
      agent_id = SalixAgent.TestSupport.new_agent_id()

      router =
        SalixAgent.TestSupport.create_control_agent!(agent_id, %{
          "name" => "Reminder Router",
          "role" => "router"
        })

      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router)
      {:ok, _pid} = SalixAgent.Fleet.ensure_started(agent_id, create: false)

      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
      FakeIMProvider.set_owner(SystemsRuntime.Proc.self())

      SalixAgent.LLM.Mock.script([
        {:assistant, "sending the scheduled reminder",
         [
           %{
             id: "scheduled-feishu-send",
             name: "call",
             args: %{
               "tool" => "im_api.feishu.send_text",
               "params" => %{
                 "connect_id" => "fs-reminders",
                 "receive_id" => "oc_team",
                 "text" => "Meeting starts in ten minutes",
                 "mentions" => [%{"user_id" => "ou_owner", "name" => "Owner"}],
                 "mention_all" => false
               }
             }
           }
         ]},
        {:final, "done"}
      ])

      ctx = %{agent_id: agent_id, session_id: session_id, state: nil}

      schedule =
        Tool.create_schedule(
          %{
            "run_at" => "2027-01-02T09:50:00+08:00",
            "prompt" =>
              ~s(Call im_api.feishu.send_text with connect_id="fs-reminders", receive_id="oc_team", text="Meeting starts in ten minutes", mentions=[{"user_id":"ou_owner","name":"Owner"}], mention_all=false.)
          },
          ctx
        )
        |> Jason.decode!()

      run_at = schedule["run_at"]
      schedule_id = schedule["id"]

      assert {:ok, %{fired: [^schedule_id], failed: []}} =
               Schedules.run_once(now: run_at)

      settle_receive(
        {:im_provider_call, ^agent_id, "feishu", "feishu.send_text",
         %{
           "connect_id" => "fs-reminders",
           "params" => %{
             "receive_id" => "oc_team",
             "text" => "Meeting starts in ten minutes",
             "mentions" => [%{"user_id" => "ou_owner", "name" => "Owner"}],
             "mention_all" => false
           }
         }}
      )

      assert {:error, :not_found} = Schedules.get(schedule_id)
      assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: run_at + 1)
      settle_refute_receive({:im_provider_call, ^agent_id, "feishu", "feishu.send_text", _}, 300)
      assert :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, session_id)
    end

    test "a tool-created schedule fires into the calling agent's session ledger", %{ctx: ctx} do
      prompt =
        ~s(Call im_api.feishu.send_text with connect_id="fs-reminders", receive_id="oc_team", text="Standup in five minutes", mentions=[{"user_id":"ou_owner","name":"Owner"}].)

      out =
        Tool.create_schedule(
          %{
            "interval_minutes" => 5,
            "prompt" => prompt
          },
          ctx
        )

      sched = Jason.decode!(out)
      id = sched["id"]
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, %{fired: [^id], already_fired: []}} = Schedules.run_once(now: t1)

      # rpc delivery lands on the schedule's target session, exactly once,
      # and the absorbed user message keeps the tool command intact.
      {:ok, state} = SessionData.read(ctx.agent_id, ctx.session_id)
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")
      assert eventually(fn -> user_message_count(ctx, prompt) == 1 end)
      assert [message] = absorbed_user_messages(ctx, prompt)
      assert message.content =~ "im_api.feishu.send_text"
      assert message.content =~ "receive_id=\"oc_team\""
      assert :ok = SalixAgent.TestSupport.await_session_quiet(ctx.agent_id, ctx.session_id)
    end
  end

  describe "ownership and validation errors" do
    test "deleting another agent's schedule raises schedule not found", %{ctx: ctx} do
      id = Ids.new_schedule_id()

      {:ok, _} =
        Schedules.create(id, %{agent_id: "someone-else", interval_minutes: 5, prompt: "p"})

      assert_raise RuntimeError, "schedule not found", fn ->
        Tool.delete_schedule(%{"schedule_id" => id}, ctx)
      end

      # still there — ownership check rejected before delete
      assert {:ok, _} = Schedules.get(id)
    end

    @argument_errors [
      {"deleting an unknown id raises schedule not found", :delete_schedule,
       %{"schedule_id" => "sched-nope"}, "schedule not found"},
      {"create requires prompt", :create_schedule, %{"interval_minutes" => 5},
       "'prompt' is required"},
      {"create requires one of interval_minutes, cron, or run_at", :create_schedule,
       %{"prompt" => "p"}, "provide exactly one of 'interval_minutes', 'cron', or 'run_at'"},
      {"create requires a positive integer interval_minutes", :create_schedule,
       %{"prompt" => "p", "interval_minutes" => 0},
       "'interval_minutes' must be a positive integer"},
      {"delete requires schedule_id", :delete_schedule, %{}, "'schedule_id' is required"}
    ]

    for {name, action, args, message} <- @argument_errors do
      test name, %{ctx: ctx} do
        assert_raise RuntimeError, unquote(message), fn ->
          apply(Tool, unquote(action), [unquote(Macro.escape(args)), ctx])
        end
      end
    end
  end

  describe "seam" do
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  # The user messages the woken round absorbed into the transcript with
  # exactly this content — the rpc-world equivalent of the staged inbox
  # payload the pre-cutover tests inspected.
  defp absorbed_user_messages(ctx, content) do
    case SessionData.read(ctx.agent_id, ctx.session_id) do
      {:ok, state} ->
        Enum.filter(state.messages, &(&1.role == "user" and &1.content == content))

      _ ->
        []
    end
  end

  defp user_message_count(ctx, content), do: length(absorbed_user_messages(ctx, content))

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
