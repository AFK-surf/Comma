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
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.Schedules, as: Tool
  alias SalixAgent.TestSupport.SessionData
  alias SalixCluster.Schedules
  alias SalixStore.Ids

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def clear_owner, do: :persistent_term.erase({__MODULE__, :owner})

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
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"message_id" => "om_scheduled"}}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    start_supervised!(SalixStore.S3.Fake)

    # Schedules live in the node-global control Postgres now, which no
    # S3.Fake.reset can clear — every file expecting a clean slate truncates.
    SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    start_supervised!(SalixAgent.LLM.Mock)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    prev_mod = Application.get_env(:salix_agent, :schedules_mod)
    Application.put_env(:salix_agent, :schedules_mod, SalixCluster.Schedules)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      FakeIMProvider.clear_owner()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      Application.put_env(:salix_agent, :schedules_mod, prev_mod)
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

  test "defs/0 exposes split canonical schedule tools with create write safety" do
    assert [
             {"schedule.create", create_desc, create_fun, create_auto_wait_seconds, create_opts},
             {"schedule.list", list_desc, list_fun, list_auto_wait_seconds},
             {"schedule.delete", delete_desc, delete_fun, delete_auto_wait_seconds}
           ] = Tool.defs()

    assert create_desc =~ "Create"
    assert create_opts == [safety: "write"]
    assert list_desc =~ "List"
    assert delete_desc =~ "Delete"
    assert is_function(create_fun, 2)
    assert is_function(list_fun, 2)
    assert is_function(delete_fun, 2)
    assert create_auto_wait_seconds == 20
    assert list_auto_wait_seconds == 20
    assert delete_auto_wait_seconds == 20
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

    test "an imported Task carrying this agent's id is not deletable through schedule.delete",
         %{ctx: ctx} do
      # The reviewer's exact repro, driven through the canonical tool and the
      # production :schedules_mod seam: a cutover/pre-validation row bound to
      # ANOTHER group but carrying THIS agent's id. Ownership lives in the
      # DELETE predicate, so the tool cannot reach it.
      :ok =
        SalixStore.Schedules.import_record(
          %{
            "id" => "foreign_task",
            "receiver" => "task",
            "agent_id" => ctx.agent_id,
            "payload" => %{
              "agent_group_id" => "group_project_b",
              "conversation_id" => "conv_b"
            },
            "interval_minutes" => 5,
            "created_at" => 1_000,
            "last_run" => nil
          },
          1_000
        )

      assert_raise RuntimeError, "schedule not found", fn ->
        Tool.delete_schedule(%{"schedule_id" => "foreign_task"}, ctx)
      end

      # Still there, and still owned by its true group.
      assert {:ok, %{"id" => "foreign_task"}} = Schedules.get("foreign_task")

      assert {:ok, [%{"id" => "foreign_task"}]} =
               SalixStore.Schedules.list_for_owners([], "group_project_b")

      # It is also invisible to this agent's listing.
      assert Jason.decode!(Tool.list_schedules(%{}, ctx)) == []
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

    test "interval_minutes accepts a numeric string (string-args pattern)", %{ctx: ctx} do
      out =
        Tool.create_schedule(%{"interval_minutes" => "7", "prompt" => "p"}, ctx)

      sched = Jason.decode!(out)
      assert sched["interval_minutes"] == 7
      assert sched["session_id"] == ctx.session_id
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

    test "rejects giving both interval_minutes and cron", %{ctx: ctx} do
      assert_raise RuntimeError,
                   "provide exactly one of 'interval_minutes', 'cron', or 'run_at'",
                   fn ->
                     Tool.create_schedule(
                       %{
                         "prompt" => "p",
                         "interval_minutes" => 5,
                         "cron" => "0 9 * * *"
                       },
                       ctx
                     )
                   end
    end

    test "cron wins over a zero interval_minutes filler from the model", %{ctx: ctx} do
      out =
        Tool.create_schedule(
          %{
            "prompt" => "daily",
            "cron" => "0 9 * * *",
            "interval_minutes" => 0
          },
          ctx
        )

      sched = Jason.decode!(out)
      assert sched["cron"] == "0 9 * * *"
      refute Map.has_key?(sched, "interval_minutes")
      assert {:ok, _} = Schedules.get(sched["id"])
    end

    test "cron wins over an empty-string interval_minutes filler from the model", %{ctx: ctx} do
      out =
        Tool.create_schedule(
          %{
            "prompt" => "daily",
            "cron" => "0 9 * * *",
            "interval_minutes" => ""
          },
          ctx
        )

      sched = Jason.decode!(out)
      assert sched["cron"] == "0 9 * * *"
      refute Map.has_key?(sched, "interval_minutes")
    end

    test "rejects an unparseable cron expression", %{ctx: ctx} do
      assert_raise RuntimeError, "invalid schedule parameters", fn ->
        Tool.create_schedule(%{"prompt" => "p", "cron" => "not a cron"}, ctx)
      end
    end

    test "rejects an unknown timezone", %{ctx: ctx} do
      assert_raise RuntimeError, "invalid schedule parameters", fn ->
        Tool.create_schedule(
          %{
            "prompt" => "p",
            "cron" => "0 9 * * *",
            "timezone" => "Mars/Phobos"
          },
          ctx
        )
      end
    end

    test "a tool-created cron schedule fires into the calling agent's session ledger", %{
      ctx: ctx
    } do
      out =
        Tool.create_schedule(
          %{
            "cron" => "0 9 * * *",
            "prompt" => "daily"
          },
          ctx
        )

      sched = Jason.decode!(out)
      id = sched["id"]
      t1 = Schedules.next_fire_ms(sched)

      assert {:ok, %{fired: [^id]}} = Schedules.run_once(now: t1)

      # rpc delivery: the session ledger's dedupe entry is the durable
      # exactly-once record, committed before run_once returns.
      {:ok, state} = SessionData.read(ctx.agent_id, ctx.session_id)
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{t1}")

      # The woken round absorbs the payload into the transcript as the user
      # message the agent actually sees, content preserved.
      assert eventually(fn -> user_message_count(ctx, "daily") == 1 end)
      assert :ok = SalixAgent.TestSupport.await_session_quiet(ctx.agent_id, ctx.session_id)
    end
  end

  describe "firing" do
    test "a one-shot meeting reminder preserves the exact Router-owned Feishu delivery command",
         %{
           ctx: ctx
         } do
      prompt =
        ~s(Call im_api.feishu.send_text with connect_id="fs-reminders", receive_id="oc_team", text="Meeting starts in ten minutes", mentions=[{"user_id":"ou_owner","name":"Owner"}], mention_all=false.)

      out =
        Tool.create_schedule(
          %{
            "run_at" => "2027-01-02T09:50:00+08:00",
            "prompt" => prompt
          },
          ctx
        )

      sched = Jason.decode!(out)
      id = sched["id"]

      run_at =
        DateTime.from_iso8601("2027-01-02T09:50:00+08:00")
        |> elem(1)
        |> DateTime.to_unix(:millisecond)

      assert sched["run_at"] == run_at
      assert {:ok, %{fired: [^id], already_fired: []}} = Schedules.run_once(now: run_at)
      assert {:error, :not_found} = Schedules.get(id)

      # Committed onto the schedule's target session with its stable id; the
      # absorbed user message carries the delivery command byte-for-byte.
      {:ok, state} = SessionData.read(ctx.agent_id, ctx.session_id)
      assert MapSet.member?(state.input_dedupe, "schedule:#{id}:#{run_at}")
      assert eventually(fn -> user_message_count(ctx, prompt) == 1 end)
      assert [message] = absorbed_user_messages(ctx, prompt)
      assert message.content =~ "mentions="

      # The consumed window cannot deliver a second copy.
      assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: run_at + 1)
      assert user_message_count(ctx, prompt) == 1
      assert :ok = SalixAgent.TestSupport.await_session_quiet(ctx.agent_id, ctx.session_id)
    end

    test "a due one-shot schedule wakes the Router and executes Feishu delivery exactly once" do
      agent_id = SalixAgent.TestSupport.new_agent_id()

      router =
        SalixAgent.TestSupport.create_control_agent!(agent_id, %{
          "name" => "Reminder Router",
          "role" => "router"
        })

      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router)
      {:ok, _pid} = SalixAgent.Fleet.ensure_started(agent_id, create: false)

      Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)
      FakeIMProvider.set_owner(self())

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

      assert_receive {:im_provider_call, ^agent_id, "feishu", "feishu.send_text",
                      %{
                        "connect_id" => "fs-reminders",
                        "params" => %{
                          "receive_id" => "oc_team",
                          "text" => "Meeting starts in ten minutes",
                          "mentions" => [%{"user_id" => "ou_owner", "name" => "Owner"}],
                          "mention_all" => false
                        }
                      }},
                     2_000

      assert {:error, :not_found} = Schedules.get(schedule_id)
      assert {:ok, %{fired: [], already_fired: []}} = Schedules.run_once(now: run_at + 1)
      refute_receive {:im_provider_call, ^agent_id, "feishu", "feishu.send_text", _}, 300
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

    test "deleting an unknown id raises schedule not found", %{ctx: ctx} do
      assert_raise RuntimeError, "schedule not found", fn ->
        Tool.delete_schedule(%{"schedule_id" => "sched-nope"}, ctx)
      end
    end

    test "create validates prompt and interval_minutes", %{ctx: ctx} do
      assert_raise RuntimeError, "'prompt' is required", fn ->
        Tool.create_schedule(%{"interval_minutes" => 5}, ctx)
      end

      # neither interval_minutes nor cron given
      assert_raise RuntimeError,
                   "provide exactly one of 'interval_minutes', 'cron', or 'run_at'",
                   fn ->
                     Tool.create_schedule(%{"prompt" => "p"}, ctx)
                   end

      # interval_minutes present but not a positive integer
      assert_raise RuntimeError, "'interval_minutes' must be a positive integer", fn ->
        Tool.create_schedule(%{"prompt" => "p", "interval_minutes" => 0}, ctx)
      end
    end

    test "delete requires schedule_id", %{ctx: ctx} do
      assert_raise RuntimeError, "'schedule_id' is required", fn ->
        Tool.delete_schedule(%{}, ctx)
      end
    end
  end

  describe "seam" do
    test "nil schedules_mod raises unavailable for every action", %{ctx: ctx} do
      Application.put_env(:salix_agent, :schedules_mod, nil)

      for {fun, args} <- [
            {&Tool.list_schedules/2, %{}},
            {&Tool.create_schedule/2, %{"prompt" => "p", "interval_minutes" => 5}},
            {&Tool.delete_schedule/2, %{"schedule_id" => "sched-x"}}
          ] do
        assert_raise RuntimeError, "schedule manager unavailable on this node", fn ->
          fun.(args, ctx)
        end
      end
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

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

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
