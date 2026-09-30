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

  # {name, input, expected {meta, body}}
  @cases [
    {"input without a leading delimiter has no frontmatter",
     "# Just markdown\n\n---\nnot: frontmatter\n---\n",
     {%{}, "# Just markdown\n\n---\nnot: frontmatter\n---\n"}},
    {"an unclosed block is not frontmatter — the whole input is the body",
     "---\ntitle: Never closed\nkind: daily\n", {%{}, "---\ntitle: Never closed\nkind: daily\n"}},
    {"malformed lines are skipped, valid ones kept",
     "---\ntitle: Kept\nno colon on this line\n: empty key\n   \nkind: daily\n---\nbody",
     {%{"title" => "Kept", "kind" => "daily"}, "body"}},
    {"keys are downcased and trimmed", "---\n  Title : Spaced\nKIND: daily\n---\n",
     {%{"title" => "Spaced", "kind" => "daily"}, ""}},
    {"values keep only their first colon split",
     "---\ngenerated_at: 2026-07-06T08:00:00Z\nsite: https://example.com/x\n---\n",
     {%{"generated_at" => "2026-07-06T08:00:00Z", "site" => "https://example.com/x"}, ""}},
    {"surrounding quotes are stripped, single or double",
     ~s(---\ntitle: "Quoted: with colon"\nsummary: 'single'\n---\n),
     {%{"title" => "Quoted: with colon", "summary" => "single"}, ""}},
    {"lone or mismatched quotes are kept verbatim",
     ~s(---\na: "\nb: "mismatched'\nc: it's fine\n---\n),
     {%{"a" => ~s("), "b" => ~s("mismatched'), "c" => "it's fine"}, ""}},
    {"duplicate keys keep the last value", "---\ntitle: First\ntitle: Second\n---\n",
     {%{"title" => "Second"}, ""}},
    {"CRLF input parses and the body keeps its line endings",
     "---\r\ntitle: CRLF\r\nkind: weekly\r\n---\r\nline one\r\nline two\r\n",
     {%{"title" => "CRLF", "kind" => "weekly"}, "line one\r\nline two\r\n"}},
    {"empty file", "", {%{}, ""}},
    {"file that is only an opening delimiter", "---", {%{}, "---"}},
    {"file that is only an opening delimiter and newline", "---\n", {%{}, "---\n"}},
    {"empty block yields empty frontmatter", "---\n---\nbody\n", {%{}, "body\n"}},
    {"closing delimiter without trailing newline leaves an empty body", "---\ntitle: X\n---",
     {%{"title" => "X"}, ""}},
    {"unknown keys are preserved for the caller to ignore",
     "---\ntitle: X\nfuture_key: whatever\n---\n",
     {%{"title" => "X", "future_key" => "whatever"}, ""}}
  ]

  for {name, input, expected} <- @cases do
    test name do
      assert Frontmatter.parse(unquote(input)) == unquote(Macro.escape(expected))
    end
  end
end
