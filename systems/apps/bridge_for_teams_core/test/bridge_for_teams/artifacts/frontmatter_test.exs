defmodule BridgeForTeams.Artifacts.FrontmatterTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Artifacts.Frontmatter

  doctest BridgeForTeams.Artifacts.Frontmatter

  test "parses a well-formed block and returns the body unchanged" do
    input = """
    ---
    title: Daily Briefing
    kind: daily
    period: 2026-07-06
    generated_at: 2026-07-06T08:00:00Z
    ---
    # Daily Briefing

    Body **markdown**.
    """

    assert {meta, body} = Frontmatter.parse(input)

    assert meta == %{
             "title" => "Daily Briefing",
             "kind" => "daily",
             "period" => "2026-07-06",
             "generated_at" => "2026-07-06T08:00:00Z"
           }

    assert body == "# Daily Briefing\n\nBody **markdown**.\n"
  end

  test "input without a leading delimiter has no frontmatter" do
    input = "# Just markdown\n\n---\nnot: frontmatter\n---\n"
    assert Frontmatter.parse(input) == {%{}, input}
  end

  test "an unclosed block is not frontmatter — the whole input is the body" do
    input = "---\ntitle: Never closed\nkind: daily\n"
    assert Frontmatter.parse(input) == {%{}, input}
  end

  test "malformed lines are skipped, valid ones kept" do
    input = "---\ntitle: Kept\nno colon on this line\n: empty key\n   \nkind: daily\n---\nbody"
    assert Frontmatter.parse(input) == {%{"title" => "Kept", "kind" => "daily"}, "body"}
  end

  test "keys are downcased and trimmed" do
    input = "---\n  Title : Spaced\nKIND: daily\n---\n"
    assert {%{"title" => "Spaced", "kind" => "daily"}, ""} = Frontmatter.parse(input)
  end

  test "values keep only their first colon split" do
    input = "---\ngenerated_at: 2026-07-06T08:00:00Z\nsite: https://example.com/x\n---\n"

    assert {%{"generated_at" => "2026-07-06T08:00:00Z", "site" => "https://example.com/x"}, ""} =
             Frontmatter.parse(input)
  end

  test "surrounding quotes are stripped, single or double" do
    input = ~s(---\ntitle: "Quoted: with colon"\nsummary: 'single'\n---\n)

    assert {%{"title" => "Quoted: with colon", "summary" => "single"}, ""} =
             Frontmatter.parse(input)
  end

  test "lone or mismatched quotes are kept verbatim" do
    input = ~s(---\na: "\nb: "mismatched'\nc: it's fine\n---\n)

    assert {%{"a" => ~s("), "b" => ~s("mismatched'), "c" => "it's fine"}, ""} =
             Frontmatter.parse(input)
  end

  test "duplicate keys keep the last value" do
    input = "---\ntitle: First\ntitle: Second\n---\n"
    assert {%{"title" => "Second"}, ""} = Frontmatter.parse(input)
  end

  test "CRLF input parses and the body keeps its line endings" do
    input = "---\r\ntitle: CRLF\r\nkind: weekly\r\n---\r\nline one\r\nline two\r\n"

    assert {%{"title" => "CRLF", "kind" => "weekly"}, "line one\r\nline two\r\n"} =
             Frontmatter.parse(input)
  end

  test "empty file" do
    assert Frontmatter.parse("") == {%{}, ""}
  end

  test "file that is only an opening delimiter" do
    assert Frontmatter.parse("---") == {%{}, "---"}
    assert Frontmatter.parse("---\n") == {%{}, "---\n"}
  end

  test "empty block yields empty frontmatter" do
    assert Frontmatter.parse("---\n---\nbody\n") == {%{}, "body\n"}
  end

  test "closing delimiter without trailing newline leaves an empty body" do
    assert Frontmatter.parse("---\ntitle: X\n---") == {%{"title" => "X"}, ""}
  end

  test "unknown keys are preserved for the caller to ignore" do
    input = "---\ntitle: X\nfuture_key: whatever\n---\n"
    assert {%{"title" => "X", "future_key" => "whatever"}, ""} = Frontmatter.parse(input)
  end
end
