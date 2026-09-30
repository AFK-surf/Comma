defmodule BridgeForTeams.Artifacts.DocumentTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Artifacts.Document

  doctest BridgeForTeams.Artifacts.Document

  test "parses frontmatter, markdown and blocks into ordered segments" do
    input = """
    ---
    title: Competitor scan
    kind: brief
    ---
    Intro prose.

    ```bft:block
    {"type": "kpis", "items": [{"label": "ARR", "value": "$1.2M"}]}
    ```

    Middle prose.

    ```bft:block
    {"type": "list", "items": ["one", "two"]}
    ```

    Closing prose.
    """

    assert %{meta: meta, segments: segments} = Document.parse(input)
    assert meta == %{"title" => "Competitor scan", "kind" => "brief"}

    assert segments == [
             {:markdown, "Intro prose."},
             {:block, %{"type" => "kpis", "items" => [%{"label" => "ARR", "value" => "$1.2M"}]}},
             {:markdown, "Middle prose."},
             {:block, %{"type" => "list", "style" => "plain", "items" => ["one", "two"]}},
             {:markdown, "Closing prose."}
           ]
  end

  test "a file without frontmatter is all body" do
    input =
      "Just some **markdown**.\n\n```bft:block\n{\"type\": \"list\", \"items\": [\"x\"]}\n```\n"

    assert %{meta: %{}, segments: segments} = Document.parse(input)

    assert segments == [
             {:markdown, "Just some **markdown**."},
             {:block, %{"type" => "list", "style" => "plain", "items" => ["x"]}}
           ]
  end

  test "empty input" do
    assert Document.parse("") == %{meta: %{}, segments: []}
  end

  test "a frontmatter-only file has no segments" do
    assert Document.parse("---\ntitle: X\n---\n") == %{meta: %{"title" => "X"}, segments: []}
  end

  test "whitespace-only markdown between and around fences is dropped" do
    input =
      "```bft:block\n{\"type\": \"list\", \"items\": [\"a\"]}\n```\n\n\n```bft:block\n{\"type\": \"list\", \"items\": [\"b\"]}\n```\n"

    assert %{segments: [{:block, %{"items" => ["a"]}}, {:block, %{"items" => ["b"]}}]} =
             Document.parse(input)
  end

  test "a fence with invalid JSON becomes an invalid_block carrying the raw text" do
    input = "before\n\n```bft:block\n{\"type\": \"kpis\", oops\n```\n\nafter\n"

    assert %{
             segments: [
               {:markdown, "before"},
               {:invalid_block, "{\"type\": \"kpis\", oops"},
               {:markdown, "after"}
             ]
           } = Document.parse(input)
  end

  test "valid JSON that fails block normalization becomes an invalid_block" do
    for json <- [
          ~s({"type": "chart", "series": [[1, 2]]}),
          ~s({"type": "kpis", "items": []}),
          ~s(["not", "an", "object"]),
          ~s("just a string")
        ] do
      input = "```bft:block\n#{json}\n```\n"
      assert %{segments: [{:invalid_block, ^json}]} = Document.parse(input)
    end
  end

  test "a near-miss block with usable string items degrades to a plain list segment" do
    input = ~s(```bft:block\n{"type": "chart", "items": [1, "two"]}\n```\n)

    assert %{
             segments: [
               {:block, %{"type" => "list", "style" => "plain", "items" => ["1", "two"]}}
             ]
           } = Document.parse(input)
  end

  test "an unclosed fence is plain markdown" do
    input = "```bft:block\n{\"type\": \"list\", \"items\": [\"x\"]}\n"
    assert %{segments: [{:markdown, markdown}]} = Document.parse(input)
    assert markdown =~ "bft:block"
  end

  test "other fenced code blocks are left in the markdown" do
    input = "```elixir\nIO.puts(:hi)\n```\n"
    assert %{segments: [{:markdown, markdown}]} = Document.parse(input)
    assert markdown =~ "```elixir"
  end

  test "fences beyond the 32nd become invalid_block even when valid" do
    fence = "```bft:block\n{\"type\": \"list\", \"items\": [\"x\"]}\n```\n\n"
    input = String.duplicate(fence, 35)

    assert %{segments: segments} = Document.parse(input)
    assert length(segments) == 35

    {honored, excess} = Enum.split(segments, 32)
    assert Enum.all?(honored, &match?({:block, %{"type" => "list"}}, &1))
    assert Enum.all?(excess, &match?({:invalid_block, _raw}, &1))
  end

  test "block order and interleaving are preserved across mixed validity" do
    input = """
    prose one

    ```bft:block
    not json
    ```

    ```bft:block
    {"type": "entities", "items": [{"name": "Acme"}]}
    ```

    prose two
    """

    assert %{
             segments: [
               {:markdown, "prose one"},
               {:invalid_block, "not json"},
               {:block, %{"type" => "entities"}},
               {:markdown, "prose two"}
             ]
           } = Document.parse(input)
  end
end
