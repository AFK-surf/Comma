defmodule SalixAgent.MiniskillSelectorTest do
  use SystemsClock.Case, async: false

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
    DecideFixture.put_env(:decide_test_pid, SystemsRuntime.Proc.self())
    DecideFixture.put_env(:decide_test_deny, false)
    DecideFixture.put_env(:ifc_facts_mod, nil)
    old = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, old) end)
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
        {nil, :neutral, nil, [], "stream"}
      )

  test "ranks the full catalog, suggests five skills, and stores the selection in history",
       %{ctx: ctx} do
    skills =
      for n <- 1..9 do
        ctx
        |> skill("build-#{n}", "Instruction #{n}")
        |> Map.put("description", "Build diagnostic #{n}")
        |> Map.put("files", %{})
      end

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
    event = %{"type" => "miniskills_selected", "selection" => selection}

    session =
      InternalSession.apply_events(
        session,
        [event | MiniskillSelector.runtime_messages(event, ctx.session_id, 2)]
      )

    assert [] = InternalSession.query(session, :miniskill_inputs)

    # The selection is one stored, private, no-wake runtime message after the
    # input it serves, and the request reads it from the transcript.
    assert [_input, stored] = InternalSession.get(session, :messages)
    assert stored[:id] == 2 and stored[:role] == "runtime" and stored[:no_wake] == true
    assert stored[:type] == "miniskill_selection"
    for n <- 1..5, do: assert(stored[:content] =~ "Build diagnostic #{n}")
    refute stored[:content] =~ "Instruction "

    wire = SalixAgent.IFC.Context.build(session)

    assert Enum.any?(
             wire["items"],
             &(&1["ref"] == "src:a-2" and &1["label"] == ["agent_private"])
           )

    assert Enum.count(request(session), &mentions?(&1, "Build diagnostic 1")) == 1

    assert {:ok, restored} = session |> InternalSession.persist() |> InternalSession.load()
    assert [] = InternalSession.query(restored, :miniskill_inputs)
    assert request(restored) == request(session)

    # A later input without a match adds nothing, and the earlier request is
    # an unchanged prefix of the next one.
    before = request(restored)
    session = deliver(restored, input(3, "Tell me a joke"))
    assert [%{"id" => 3}] = InternalSession.query(session, :miniskill_inputs)

    next =
      MiniskillSelector.select(
        [input(3)],
        %{projection | skills: []},
        ctx,
        System.monotonic_time(:millisecond) + 1000
      )

    next_event = %{"type" => "miniskills_selected", "selection" => next}
    assert MiniskillSelector.runtime_messages(next_event, ctx.session_id, 4) == []
    session = InternalSession.apply_events(session, [next_event])
    after_next = request(session)

    assert Enum.take(after_next, length(before)) == before
    assert Enum.any?(after_next, &(&1[:content] == "Tell me a joke"))
  end

  defp mentions?(message, text),
    do: message |> Jason.encode!() |> String.contains?(text)

  test "shipped miniskills keep multibyte descriptions intact and fit one worst-case request" do
    root = Path.expand("../../../../resources/salix-system-files/skills", __DIR__)
    previous = SystemsRuntime.get_env(:salix_agent, :builtin_skills_path)
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, root)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :builtin_skills_path)
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
