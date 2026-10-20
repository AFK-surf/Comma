defmodule Salix.Bindings.MeetingOwnerAttributionTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: true

  alias Salix.Bindings.MeetingOwnerAttribution, as: Attr

  describe "distinct_owners/1" do
  end

  describe "bounded prompt context" do

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
  end

  describe "parse_matches/2" do
    setup do: %{ids: MapSet.new(["U1", "U2", "U3"])}

    # Rows with nil prompt owners exercise parse_matches/2; others pass the
    # bounded prompt owners to parse_matches/3.
    for {label, owners, expected, content} <- [
          {"maps confident, valid, non-null matches", nil,
           %{"Zanwei Guo" => "U1", "sky dark" => "U2"},
           ~s({"matches":[{"owner":"Zanwei Guo","slack_id":"U1","confidence":"high"},) <>
             ~s({"owner":"sky dark","slack_id":"U2","confidence":"medium"}]})},
          {"drops ids that are not in the roster (no hallucinated mentions)", nil, %{},
           ~s({"matches":[{"owner":"X","slack_id":"U999","confidence":"high"}]})},
          {"rejects an oversized provider response before decoding it", ["Alice"], %{},
           String.duplicate(" ", 70_000) <>
             ~s({"matches":[{"owner":"Alice","slack_id":"U1","confidence":"high"}]})},
          {"drops owners omitted from the bounded prompt", ["Alice"], %{},
           ~s({"matches":[{"owner":"Bob","slack_id":"U1","confidence":"high"}]})},
          {"drops conflicting confident ids for one owner", ["Alice"], %{},
           ~s({"matches":[) <>
             ~s({"owner":"Alice","slack_id":"U1","confidence":"high"},) <>
             ~s({"owner":"Alice","slack_id":"U2","confidence":"medium"}]})},
          {"accepts duplicate confident agreement for one owner", ["Alice"], %{"Alice" => "U1"},
           ~s({"matches":[) <>
             ~s({"owner":"Alice","slack_id":"U1","confidence":"high"},) <>
             ~s({"owner":"Alice","slack_id":"U1","confidence":"medium"}]})},
          {"drops null slack_id and low confidence", nil, %{},
           ~s({"matches":[{"owner":"A","slack_id":null,"confidence":"high"},) <>
             ~s({"owner":"B","slack_id":"U1","confidence":"low"}]})},
          {"parses code-fenced JSON", nil, %{"A" => "U3"},
           "```json\n{\"matches\":[{\"owner\":\"A\",\"slack_id\":\"U3\",\"confidence\":\"high\"}]}\n```"},
          {"non-JSON content yields empty map", nil, %{}, "sorry, no JSON here"}
        ] do
      @owners owners
      @expected expected
      @content content
      test label, %{ids: ids} do
        assert parse_matches(@content, ids, @owners) == @expected
      end
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

  defp parse_matches(content, ids, nil), do: Attr.parse_matches(content, ids)

  defp parse_matches(content, ids, owners),
    do: Attr.parse_matches(content, ids, MapSet.new(owners))
end
