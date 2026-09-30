defmodule SalixAgent.MiniskillSelectorTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    Decide,
    DecideFixture,
    InternalSession,
    MiniskillSelector,
    SkillProjection,
    SkillStore
  }

  alias SalixStore.S3

  setup do
    DecideFixture.start_provider()
    DecideFixture.put_env(:llm_metering_mod, DecideFixture.Meter)
    DecideFixture.put_env(:event_archive_mod, DecideFixture.Archive)
    DecideFixture.put_env(:decide_test_pid, self())
    DecideFixture.put_env(:decide_test_deny, false)
    DecideFixture.put_env(:ifc_facts_mod, nil)
    old = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, old) end)
    agent = SalixAgent.TestSupport.new_agent_id()
    group = SalixStore.Ids.group_id_from_agent!(agent)

    ctx = %{
      agent_id: agent,
      group_id: group,
      tenant_id: SalixStore.Ids.tenant_id_from_group!(group),
      session_id: SalixStore.Ids.new_session_id(),
      billing_context: %{}
    }

    %{ctx: ctx}
  end

  defp skill(ctx, id, body \\ "Inspect the failing build.") do
    content =
      "---\nname: #{id}\ndescription: Diagnose a failing build\nactivation: per-message\n---\n#{body}"

    {:ok, event} =
      SkillStore.prepare_group_create(ctx, %{"skill_id" => id, "name" => id, "content" => content})

    event["skill"]
  end

  defp input(id \\ 1, text \\ "Fix the build") do
    %{
      "id" => id,
      "content" => text,
      "source_message_id" => "source-#{id}",
      "trusted_origin" => %{"provider" => "internal", "source_actor_type" => "user"}
    }
  end

  defp deliver(session, input) do
    event =
      input
      |> Map.delete("id")
      |> Map.merge(%{
        "type" => "delivery",
        "message_id" => input["id"],
        "from_queue" => true,
        "role" => "user",
        "created_at" => 1
      })

    InternalSession.apply_events(session, [event])
  end

  defp request(session),
    do:
      InternalSession.query(
        session,
        :provider_dispatch,
        {nil, false, %{}, %{"tools" => []}, false, :neutral, nil, [], "stream"}
      )

  test "decision context contains six prior user/assistant messages without later queued input",
       %{ctx: ctx} do
    history =
      for id <- 1..8 do
        %{
          id: id,
          role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
          content: "message #{id}",
          tool_calls: [%{args: "not decision context"}]
        }
      end

    session =
      InternalSession.open(%SalixAgent.InternalSession.State{
        agent_id: ctx.agent_id,
        session_id: ctx.session_id,
        last_ack_message_id: 8,
        messages: history ++ [%{id: 9, role: "tool", content: "excluded tool output"}],
        next_message_id: 10
      })
      |> deliver(input(10, "Do that"))
      |> deliver(input(11, "Then explain it"))

    inputs = InternalSession.query(session, :miniskill_inputs)
    assert length(inputs) == 2

    selection =
      MiniskillSelector.select(
        inputs,
        %{skills: [skill(ctx, "contextual")]},
        ctx,
        System.monotonic_time(:millisecond) + 1_000
      )

    assert length(selection["inputs"]) == 2
    assert_receive {:decision_request, _, _, first}
    assert first["state"]["message"]["text"] == "Do that"

    assert Enum.map(first["state"]["recent_messages"], & &1["text"]) ==
             Enum.map(3..8, &"message #{&1}")

    assert Enum.map(first["state"]["recent_messages"], & &1["role"]) ==
             ["user", "assistant", "user", "assistant", "user", "assistant"]

    refute Jason.encode!(first) =~ "not decision context"
    refute Jason.encode!(first) =~ "excluded tool output"
    refute Jason.encode!(first) =~ "Then explain it"
    assert_receive {:decision_request, _, _, second}
    assert List.last(second["state"]["recent_messages"])["text"] == "Do that"
    assert second["state"]["message"]["text"] == "Then explain it"
  end

  test "every oversized message retains its beginning and end within the per-message budget", %{
    ctx: ctx
  } do
    long = "beginning " <> String.duplicate("界", 2_000) <> " ending"
    recent = for n <- 1..6, do: %{"role" => "assistant", "content" => "#{n} " <> long}
    message = input(10, long) |> Map.put("recent_messages", recent)
    assert {:ok, args, _} = MiniskillSelector.request(message, [skill(ctx, "bounded")])
    assert length(args["state"]["recent_messages"]) == 6

    for entry <- [args["state"]["message"] | args["state"]["recent_messages"]] do
      assert byte_size(entry["text"]) <= 2048
      assert String.valid?(entry["text"])
      assert entry["text_omitted"]
      assert entry["text"] =~ "beginning"
      assert entry["text"] =~ "[message excerpt omitted]"
      assert String.ends_with?(entry["text"], " ending")
    end

    assert byte_size(Jason.encode!(args)) <= 64 * 1024
  end

  test "ranks the full catalog, injects five bodies, and reuses the selection until the next input",
       %{ctx: ctx} do
    skills = for n <- 1..9, do: skill(ctx, "build-#{n}", "Instruction #{n}")
    projection = %{skills: Enum.reverse(skills), revision: "1"}
    assert SkillProjection.render_prompt_section(skills) == ""

    selection =
      MiniskillSelector.select(
        [input()],
        projection,
        ctx,
        System.monotonic_time(:millisecond) + 1000
      )

    assert Enum.map(hd(selection["inputs"])["skills"], & &1["skill_id"]) ==
             Enum.map(1..5, &"build-#{&1}")

    assert_receive {:decision_request, _, _, sent}
    assert length(sent["state"]["miniskills"]) == 9
    assert map_size(sent["questions"]) == 9
    assert {:error, :invalid_request} == Decide.validate(Map.delete(sent, "model"))
    assert_receive {:decision_meter_before, meter}
    assert meter.entrypoint == "miniskill"
    assert meter.session_id == ctx.session_id
    assert_receive {:decision_archive, _}

    session = InternalSession.new(ctx.agent_id, ctx.session_id) |> deliver(input())
    assert [_] = InternalSession.query(session, :miniskill_inputs)

    session =
      InternalSession.apply_events(session, [
        %{"type" => "miniskills_selected", "selection" => selection}
      ])

    assert [] = InternalSession.query(session, :miniskill_inputs)
    wire = SalixAgent.IFC.Context.build(session)

    assert Enum.any?(
             wire["items"],
             &(&1["ref"] == "src:k-build-1" and &1["label"] == ["agent_private"])
           )

    for n <- 1..5,
        do:
          assert(
            Enum.any?(
              request(session),
              &(is_binary(&1[:content]) and String.ends_with?(&1[:content], "Instruction #{n}"))
            )
          )

    refute Enum.any?(
             InternalSession.get(session, :messages),
             &(is_binary(&1[:content]) and String.contains?(&1[:content], "Instruction 1"))
           )

    assert {:ok, restored} = session |> InternalSession.persist() |> InternalSession.load()
    assert [] = InternalSession.query(restored, :miniskill_inputs)
    assert request(restored) == request(session)

    refute Enum.any?(
             InternalSession.query(restored, :compaction_live_messages),
             &(is_binary(&1[:content]) and String.contains?(&1[:content], "Instruction 1"))
           )

    session = deliver(restored, input(2, "Tell me a joke"))
    assert [%{"id" => 2}] = InternalSession.query(session, :miniskill_inputs)

    next =
      MiniskillSelector.select(
        [input(2)],
        %{projection | skills: []},
        ctx,
        System.monotonic_time(:millisecond) + 1000
      )

    session =
      InternalSession.apply_events(session, [
        %{"type" => "miniskills_selected", "selection" => next}
      ])

    refute Enum.any?(
             request(session),
             &(is_binary(&1[:content]) and String.contains?(&1[:content], "Instruction 1"))
           )

    assert Enum.any?(request(session), &(&1[:content] == "Tell me a joke"))
  end

  test "invalid activation and oversized bodies fail at writes, while regular skills retain their catalog",
       %{ctx: ctx} do
    assert {:error, "miniskill instructions exceed 2 KiB"} =
             SkillStore.prepare_group_create(
               ctx,
               %{
                 "skill_id" => "large",
                 "name" => "large",
                 "content" =>
                   "---\nname: large\ndescription: large\nactivation: per-message\n---\n" <>
                     String.duplicate("x", 2049)
               }
             )

    assert {:error, "activation must be regular or per-message"} =
             SkillStore.prepare_group_create(
               ctx,
               %{
                 "skill_id" => "invalid",
                 "name" => "invalid",
                 "content" => "---\nactivation: invalid\n---\nbody"
               }
             )

    mini = skill(ctx, "small")

    assert {:error, _} =
             SkillStore.prepare_file_write(
               ctx,
               Map.put(mini, "scope", %{"layer" => "group", "id" => ctx.group_id}),
               "SKILL.md",
               "---\nactivation: per-message\n---\n" <> String.duplicate("x", 2049)
             )

    assert SkillProjection.render_prompt_section([%{mini | "activation" => "regular"}]) =~ "small"
  end

  test "shipped miniskills keep multibyte descriptions intact and fit one worst-case request" do
    root = Path.expand("../../../../resources/salix-system-files/skills", __DIR__)
    previous = Application.get_env(:salix_agent, :builtin_skills_path)
    Application.put_env(:salix_agent, :builtin_skills_path, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :builtin_skills_path, previous),
        else: Application.delete_env(:salix_agent, :builtin_skills_path)
    end)

    assert {:ok, snapshot} = SalixAgent.BuiltinSkills.snapshot()

    skills =
      for {id, skill} <- snapshot.skills, skill["activation"] == "per-message" do
        content = File.read!(Path.join([root, id, "SKILL.md"]))
        [_, description] = Regex.run(~r/^description: "(.*)"$/mu, content)
        assert skill["description"] == description
        skill
      end

    assert skills != []

    recent =
      List.duplicate(%{"role" => "user", "content" => String.duplicate("y", 8192)}, 6)

    worst_case =
      input(1, String.duplicate("x", 8192)) |> Map.put("recent_messages", recent)

    assert {:ok, _args, indexed} = MiniskillSelector.request(worst_case, skills)
    assert map_size(indexed) == length(skills)
  end

  test "expired budget and an oversized catalog make no provider request", %{ctx: ctx} do
    mini = skill(ctx, "small")

    result =
      MiniskillSelector.select(
        [input()],
        %{skills: [mini]},
        ctx,
        System.monotonic_time(:millisecond) - 1
      )

    assert hd(result["inputs"])["outcome"] == "timeout"

    assert {:error, :catalog_over_budget} =
             MiniskillSelector.request(input(), [
               %{mini | "description" => String.duplicate("x", 50_000)}
             ])

    refute_receive {:decision_request, _, _, _}
  end

  test "slow provider expires without blocking delivery or accepting a late selection", %{
    ctx: ctx
  } do
    mini = skill(ctx, "slow-build")
    session = InternalSession.new(ctx.agent_id, ctx.session_id) |> deliver(input(1, "slow"))

    config = %{
      tenant_id: ctx.tenant_id,
      group_id: ctx.group_id,
      skill_projection_revision: "1",
      miniskill_projection: %{skills: [mini], revision: "1"}
    }

    start = System.monotonic_time(:millisecond)
    pending = MiniskillSelector.start(session, config, ctx.agent_id, ctx.session_id)
    assert_receive {:decision_request, _, _, _}, 1000
    event = MiniskillSelector.finish(pending, config)
    assert System.monotonic_time(:millisecond) - start < 1500
    assert [%{"skills" => []}] = event["selection"]["inputs"]
    session = InternalSession.apply_events(session, [event])
    assert [] = InternalSession.query(session, :miniskill_inputs)
    assert Enum.any?(request(session), &(&1[:content] == "slow"))
  end

  test "no match and malformed output produce empty selections", %{ctx: ctx} do
    mini = skill(ctx, "build")

    for text <- ["no-match", "missing"] do
      result =
        MiniskillSelector.select(
          [input(1, text)],
          %{skills: [mini]},
          ctx,
          System.monotonic_time(:millisecond) + 1000
        )

      assert [%{"skills" => []}] = result["inputs"]
    end
  end

  defmodule RestrictedFacts do
    def mode(_, _), do: "enforce"

    def resolve(_),
      do:
        {:ok,
         %{
           "mode" => "enforce",
           "destination" => %{"label" => [], "writers" => "any"},
           "scopes" => %{},
           "membership" => %{},
           "placements" => %{},
           "receipts" => [],
           "policy" => %{},
           "display_names" => %{},
           "now" => 1
         }}
  end

  test "decision provider receives private evidence even when IFC is enforced", %{ctx: ctx} do
    DecideFixture.put_env(:ifc_facts_mod, RestrictedFacts)

    wire = %{
      "requester" => "comma_user|u",
      "source_scope" => ["group|" <> ctx.group_id],
      "request" => "src:q-1",
      "consumed_refs" => [],
      "input_refs" => %{"source-1" => "src:q-1"},
      "items" => [
        %{
          "ref" => "src:q-1",
          "label" => ["agent_private"],
          "integrity" => "command",
          "principal" => "comma_user|u"
        }
      ]
    }

    selected =
      MiniskillSelector.select(
        [input()],
        %{skills: [skill(ctx, "restricted")]},
        Map.put(ctx, :ifc, wire),
        System.monotonic_time(:millisecond) + 1000
      )

    assert [%{"outcome" => "selected", "skills" => [_]}] = selected["inputs"]
    assert_receive {:decision_request, _, _, request}
    assert request["state"]["message"]["text"] == "Fix the build"
  end

  test "untrusted runtime and assistant inputs do not trigger selection", %{ctx: ctx} do
    session =
      InternalSession.new(ctx.agent_id, ctx.session_id)
      |> deliver(%{
        input()
        | "trusted_origin" => %{"provider" => "internal", "source_actor_type" => "agent"}
      })

    assert [] = InternalSession.query(session, :miniskill_inputs)
  end
end
