defmodule Salix.Bindings.MeetingOwnerAttributionTest do
  use ExUnit.Case, async: true

  alias Salix.Bindings.MeetingOwnerAttribution, as: Attr

  describe "distinct_owners/1" do
    test "keeps non-empty owners, unique, in order" do
      items = [
        %{"description" => "a", "owner" => "Zanwei Guo"},
        %{"description" => "b", "owner" => "Zanwei Guo"},
        %{"description" => "c", "owner" => ""},
        %{"description" => "d"},
        %{"description" => "e", "owner" => "sky dark"}
      ]

      assert Attr.distinct_owners(items) == ["Zanwei Guo", "sky dark"]
    end
  end

  describe "bounded prompt context" do
    test "owner discovery scans only the documented action-item prefix" do
      items =
        List.duplicate(%{"description" => "noise", "owner" => ""}, 999) ++
          [
            %{"description" => "inside", "owner" => "Inside Owner"},
            %{"description" => "outside", "owner" => "Outside Owner"}
          ]

      assert Attr.owners_for_attribution(items) == ["Inside Owner"]
    end

    test "caps transcript source bytes before splitting while preserving valid UTF-8 tail" do
      transcript =
        "HEAD 😀\n" <>
          String.duplicate("middle 中😀\n", 120_000) <>
          "Alice: final owner evidence\nTAIL 😀 final assignment"

      capped = Attr.cap_transcript_source(transcript)

      assert byte_size(capped) <= 1_048_576
      assert String.valid?(capped)
      assert String.starts_with?(capped, "HEAD 😀")
      assert capped =~ "[... transcript bytes omitted ...]"
      assert String.ends_with?(capped, "TAIL 😀 final assignment")

      excerpt = Attr.bounded_transcript(transcript, ["Alice"], 4_000)
      assert excerpt =~ "Alice: final owner evidence"
      assert excerpt =~ "TAIL 😀 final assignment"
    end

    test "keeps a huge multilingual prompt within the model budget and preserves owner/tail evidence" do
      owners = ["Alice", "张三", "😀 owner"]

      roster =
        for idx <- 1..1_500 do
          %{
            id: "U#{idx}",
            real_name: String.duplicate("Very Long ASCII Name ", 30) <> Integer.to_string(idx),
            display: String.duplicate("超长名字😀", 80)
          }
        end

      transcript =
        ((["HEAD: project kickoff"] ++
            for(idx <- 1..400, do: "[#{idx}] 普通讨论 #{String.duplicate("内容😀", 10)}")) ++
           [
             "Alice: I will own the release checklist.",
             "neighboring evidence before the close",
             "TAIL: 张三 will publish the final report tomorrow."
           ])
        |> Enum.join("\n")

      assert {:ok, prompt} =
               Attr.build_prompt_context(owners, roster, transcript, %{
                 "context_tokens" => 8_000
               })

      assert prompt.estimated_input_tokens <= prompt.input_token_budget
      assert prompt.input_token_budget == 6_500
      assert length(prompt.roster) < length(roster)
      assert prompt.transcript =~ "Alice: I will own"
      assert prompt.transcript =~ "TAIL: 张三"
      assert prompt.user_prompt =~ hd(prompt.roster).id
      assert prompt.user_prompt =~ Jason.encode!("😀 owner")
    end

    test "valid ids are limited to roster candidates actually included in the prompt" do
      roster =
        for idx <- 1..20 do
          %{
            id: "U#{idx}",
            real_name: String.duplicate("candidate-name-#{idx}", 20),
            display: ""
          }
        end

      assert {:ok, prompt} =
               Attr.build_prompt_context(
                 ["Alice"],
                 roster,
                 "Alice owns this.\nTAIL",
                 %{"context_tokens" => 4_000}
               )

      included_ids = MapSet.new(Enum.map(prompt.roster, & &1.id))
      omitted = Enum.find(roster, &(not MapSet.member?(included_ids, &1.id)))
      included = hd(prompt.roster)

      content =
        Jason.encode!(%{
          "matches" => [
            %{"owner" => "Alice", "slack_id" => omitted.id, "confidence" => "high"}
          ]
        })

      assert Attr.parse_matches(content, included_ids) == %{}

      content =
        Jason.encode!(%{
          "matches" => [
            %{"owner" => "Alice", "slack_id" => included.id, "confidence" => "high"}
          ]
        })

      assert Attr.parse_matches(content, included_ids) == %{"Alice" => included.id}
    end

    test "token estimate and owner caps are conservative for ASCII, CJK, and emoji" do
      for text <- [
            String.duplicate("a", 100),
            String.duplicate("会", 100),
            String.duplicate("😀", 100),
            String.duplicate("👨‍👩‍👧‍👦", 100)
          ] do
        assert Attr.estimated_tokens(text) >= byte_size(text)
      end

      owners =
        [%{"unexpected" => "map"}] ++
          Enum.map(1..110, &"owner-#{&1}") ++ [String.duplicate("x", 257)]

      bounded = Attr.bounded_owners(owners)

      assert length(bounded) == 100
      refute Enum.any?(bounded, &String.contains?(&1, "unexpected"))
      refute String.duplicate("x", 257) in bounded
    end

    test "invalid roster rows and overlong fields cannot escape the prompt bound" do
      roster = [
        nil,
        "not-a-map",
        %{id: "bad\nU2", real_name: "prompt injection"},
        %{id: "U1", real_name: String.duplicate("名", 1_000)}
      ]

      assert {:ok, prompt} =
               Attr.build_prompt_context(["名"], roster, "名 owns it.\nTAIL", %{
                 "context_tokens" => 4_096
               })

      assert Enum.map(prompt.roster, & &1.id) == ["U1"]
      assert String.length(hd(prompt.roster).real_name) == 256
      assert prompt.estimated_input_tokens <= prompt.input_token_budget
    end

    test "killable attribution work is stopped at the wall-clock deadline" do
      parent = self()
      marker = make_ref()

      assert {:error, :timeout} =
               Attr.run_bounded(
                 fn ->
                   send(parent, {marker, self()})

                   receive do
                     :release -> :ok
                   end
                 end,
                 100
               )

      assert_receive {^marker, worker}
      refute Process.alive?(worker)
      assert :ok = Attr.run_bounded(fn -> :ok end, 100)

      assert {:error, {RuntimeError, "roster failed"}} =
               Attr.run_bounded(fn -> raise "roster failed" end, 100)
    end

    test "agent and LLM configuration resolution share the absolute deadline" do
      parent = self()

      for blocked_stage <- [:agent, :llm] do
        marker = make_ref()

        resolve_agent = fn _state ->
          if blocked_stage == :agent do
            send(parent, {marker, self()})

            receive do
              :release -> "agent-1"
            end
          else
            "agent-1"
          end
        end

        resolve_llm = fn _agent ->
          if blocked_stage == :llm do
            send(parent, {marker, self()})

            receive do
              :release -> {:ok, %{"model" => "test"}}
            end
          else
            {:ok, %{"model" => "test"}}
          end
        end

        deadline = System.monotonic_time(:millisecond) + 100

        assert {:error, :timeout} =
                 Attr.resolve_llm_before_deadline(%{}, deadline,
                   resolve_agent: resolve_agent,
                   resolve_llm: resolve_llm
                 )

        assert_receive {^marker, worker}
        refute Process.alive?(worker)
      end
    end

    test "agent and LLM configuration resolution returns both values on the fast path" do
      llm = %{"model" => "test", "context_tokens" => 8_000}
      deadline = System.monotonic_time(:millisecond) + 500

      assert {:ok, {"agent-1", ^llm}} =
               Attr.resolve_llm_before_deadline(%{}, deadline,
                 resolve_agent: fn _state -> "agent-1" end,
                 resolve_llm: fn "agent-1" -> {:ok, llm} end
               )
    end
  end

  describe "parse_matches/2" do
    setup do: %{ids: MapSet.new(["U1", "U2", "U3"])}

    test "maps confident, valid, non-null matches", %{ids: ids} do
      content =
        ~s({"matches":[{"owner":"Zanwei Guo","slack_id":"U1","confidence":"high"},) <>
          ~s({"owner":"sky dark","slack_id":"U2","confidence":"medium"}]})

      assert Attr.parse_matches(content, ids) == %{"Zanwei Guo" => "U1", "sky dark" => "U2"}
    end

    test "drops ids that are not in the roster (no hallucinated mentions)", %{ids: ids} do
      content = ~s({"matches":[{"owner":"X","slack_id":"U999","confidence":"high"}]})
      assert Attr.parse_matches(content, ids) == %{}
    end

    test "rejects an oversized provider response before decoding it", %{ids: ids} do
      content =
        String.duplicate(" ", 70_000) <>
          ~s({"matches":[{"owner":"Alice","slack_id":"U1","confidence":"high"}]})

      assert Attr.parse_matches(content, ids, MapSet.new(["Alice"])) == %{}
    end

    test "drops owners omitted from the bounded prompt", %{ids: ids} do
      content = ~s({"matches":[{"owner":"Bob","slack_id":"U1","confidence":"high"}]})

      assert Attr.parse_matches(content, ids, MapSet.new(["Alice"])) == %{}
    end

    test "drops conflicting confident ids for one owner but accepts duplicate agreement", %{
      ids: ids
    } do
      conflict =
        ~s({"matches":[) <>
          ~s({"owner":"Alice","slack_id":"U1","confidence":"high"},) <>
          ~s({"owner":"Alice","slack_id":"U2","confidence":"medium"}]})

      assert Attr.parse_matches(conflict, ids, MapSet.new(["Alice"])) == %{}

      agreement =
        ~s({"matches":[) <>
          ~s({"owner":"Alice","slack_id":"U1","confidence":"high"},) <>
          ~s({"owner":"Alice","slack_id":"U1","confidence":"medium"}]})

      assert Attr.parse_matches(agreement, ids, MapSet.new(["Alice"])) == %{
               "Alice" => "U1"
             }
    end

    test "drops null slack_id and low confidence", %{ids: ids} do
      content =
        ~s({"matches":[{"owner":"A","slack_id":null,"confidence":"high"},) <>
          ~s({"owner":"B","slack_id":"U1","confidence":"low"}]})

      assert Attr.parse_matches(content, ids) == %{}
    end

    test "parses code-fenced JSON", %{ids: ids} do
      content =
        "```json\n{\"matches\":[{\"owner\":\"A\",\"slack_id\":\"U3\",\"confidence\":\"high\"}]}\n```"

      assert Attr.parse_matches(content, ids) == %{"A" => "U3"}
    end

    test "non-JSON content yields empty map", %{ids: ids} do
      assert Attr.parse_matches("sorry, no JSON here", ids) == %{}
    end
  end

  describe "apply_owner_ids/2" do
    test "attaches owner_slack_id to matched items, leaves the rest plain text" do
      items = [
        %{"description" => "a", "owner" => "Zanwei Guo"},
        %{"description" => "b", "owner" => "luoan chen"}
      ]

      result = Attr.apply_owner_ids(items, %{"Zanwei Guo" => "U1"})

      assert result == [
               %{"description" => "a", "owner" => "Zanwei Guo", "owner_slack_id" => "U1"},
               %{"description" => "b", "owner" => "luoan chen"}
             ]
    end

    test "strips a pre-set owner_slack_id so only this run's resolution survives" do
      items = [
        %{"description" => "a", "owner" => "Zanwei Guo", "owner_slack_id" => "USMUGGLED"},
        %{"description" => "b", "owner" => "sky dark", "owner_slack_id" => "UVICTIM"}
      ]

      result = Attr.apply_owner_ids(items, %{"Zanwei Guo" => "U1"})

      assert result == [
               %{"description" => "a", "owner" => "Zanwei Guo", "owner_slack_id" => "U1"},
               %{"description" => "b", "owner" => "sky dark"}
             ]
    end
  end
end
