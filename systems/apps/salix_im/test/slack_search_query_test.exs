defmodule SalixIM.Provider.Slack.SearchQueryTest do
  use ExUnit.Case, async: true

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

  test "parses OR groups and exclusions against the whole query" do
    assert {:ok, parsed} = SearchQuery.parse(~s(deploy OR rollback -secret -"api token"))
    assert parsed.clauses == [["deploy"], ["rollback"]]
    assert parsed.exclude_terms == ["secret", "api token"]
  end

  test "rejects empty query and has:file alone" do
    assert {:error, "query required"} = SearchQuery.parse("   ")

    assert {:error, "query needs a keyword, from:, in:, or after:/before:"} =
             SearchQuery.parse("has:file")

    assert {:error, "query needs a keyword, from:, in:, or after:/before:"} =
             SearchQuery.parse("-secret")
  end

  test "rejects unsupported syntax rather than ignoring it" do
    assert {:error, "unsupported query syntax" <> _} = SearchQuery.parse("deploy OR")
    assert {:error, "unsupported query syntax" <> _} = SearchQuery.parse("OR deploy")
    assert {:error, "unsupported modifier"} = SearchQuery.parse("-from:U12345678 deploy")
    assert {:error, "unsupported modifier"} = SearchQuery.parse("has:link deploy")
    assert {:error, "unsupported modifier"} = SearchQuery.parse("on:2026-01-01 deploy")
    assert {:error, "from: requires a user/bot/app id"} = SearchQuery.parse("from:botname")
    assert {:error, "in: requires a channel id" <> _} = SearchQuery.parse("in:general deploy")

    assert {:error, "in: requires a channel id" <> _} =
             SearchQuery.parse("in:<@U12345678> deploy")

    assert {:error, "unsupported modifier"} = SearchQuery.parse("foo:bar deploy")

    assert {:error, "inverted time window"} =
             SearchQuery.parse("after:2026-02-01 before:2026-01-01")
  end

  test "accepts in:#C and from: without brackets" do
    assert {:ok, parsed} = SearchQuery.parse("from:U12345678 in:#C12345678 hello")
    assert parsed.actor_id == "U12345678"
    assert parsed.channel_id == "C12345678"
    assert parsed.clauses == [["hello"]]
  end
end
