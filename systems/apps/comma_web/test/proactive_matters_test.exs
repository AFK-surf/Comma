defmodule CommaWeb.ProactiveMattersTest do
  use ExUnit.Case, async: true

  alias CommaWeb.ProactiveMatters

  defp item(id, url, excerpt, ts),
    do: %{"id" => id, "url" => url, "excerpt" => excerpt, "facts" => %{"ts" => ts}}

  test "arrivals that name the same thread, run or account are one matter, led by the newest" do
    thread = "https://acme.slack.com/archives/C1/p100?thread_ts=1.0&cid=C1"

    items = [
      item("alert", thread, "Run: <https://github.com/acme/board/actions/runs/7>", "1.0"),
      item("reply", thread, "Please renew the token for ops+patrol@example.com", "2.0"),
      item(
        "next-hour",
        "https://acme.slack.com/archives/C1/p300",
        "Owner of ops+patrol@example.com, please renew",
        "3.0"
      ),
      item("other", "https://acme.slack.com/archives/C2/p400", "Lunch?", "4.0")
    ]

    assert [patrol, other] = ProactiveMatters.group(items)
    assert patrol["id"] == "next-hour"
    assert Enum.map(patrol["members"], & &1["id"]) == ["alert", "reply", "next-hour"]
    assert length(patrol["related"]) == 2
    assert other["members"] == [Map.delete(other, "members")]
  end

  test "a key that many arrivals share joins nothing" do
    items =
      for n <- 1..8,
          do:
            item("n#{n}", "https://mail.example/#{n}", "From notifications@github.com", "#{n}.0")

    assert length(ProactiveMatters.group(items)) == 8
  end
end
