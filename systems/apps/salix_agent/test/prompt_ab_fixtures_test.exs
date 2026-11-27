defmodule SalixAgent.PromptAbFixturesTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.SystemPromptDump

  @fixtures_path Path.expand("fixtures/prompt_ab/cases.json", __DIR__)

  test "prompt A/B fixture corpus is structurally valid and renders production prompts" do
    cases = @fixtures_path |> File.read!() |> Jason.decode!()
    assert length(cases) >= 10

    names = Enum.map(cases, & &1["name"])
    assert length(names) == length(Enum.uniq(names))

    for kase <- cases do
      assert is_binary(kase["name"]) and kase["name"] != ""
      assert is_list(kase["user_messages"]) and kase["user_messages"] != []
      assert is_map(kase["tool_stubs"])
      assert is_map(kase["checks"])

      v = kase["variant"] || %{}

      desc =
        SystemPromptDump.describe(
          role: v["role"] || "router",
          cloud_vm_retired: v["cloud_vm_retired"],
          guest: v["guest"] == true,
          triage: v["triage"] == true,
          concise: v["concise"] == true,
          with_screens: Map.get(v, "with_screens", true),
          builtin_skills: false
        )

      assert desc["chars"] > 100

      for pat <-
            (kase["checks"]["required_output_patterns"] || []) ++
              (kase["checks"]["forbidden_output_patterns"] || []) do
        assert {:ok, _re} = Regex.compile(pat), "Invalid regex #{inspect(pat)} in #{kase["name"]}"
      end

      for rule <- kase["checks"]["required_tool_arg_patterns"] || [] do
        assert is_binary(rule["tool"])
        assert {:ok, _re} = Regex.compile(rule["pattern"])
      end
    end
  end
end
