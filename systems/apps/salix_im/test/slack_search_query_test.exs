defmodule SalixIM.Provider.Slack.SearchQueryTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Provider.Slack.SearchQuery

  test "parses keywords, phrases, from, in, dates, and has:file" do
    assert {:ok, parsed} =
             SearchQuery.parse(
               ~s(from:<@U12345678> in:C12345678 after:2026-01-01 before:2026-02-01 has:file "api gateway" deploy)
             )

    assert parsed.actor_id == "U12345678"
    assert parsed.channel_id == "C12345678"
    assert parsed.after_date == ~D[2026-01-01]
    assert parsed.before_date == ~D[2026-02-01]
    assert parsed.has_file
    assert parsed.clauses == [["api gateway", "deploy"]]
    assert parsed.exclude_terms == []
  end
end
