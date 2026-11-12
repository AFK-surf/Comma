defmodule CommaWeb.ProactiveCheckTest do
  use ExUnit.Case, async: true

  alias Comma.Data.MemberSourceItem
  alias CommaWeb.ProactiveCheck

  @now ~U[2026-11-10 02:40:15Z]

  test "mail age starts at provider receipt even when collection just found it" do
    for toolkit <- ~w(gmail outlook) do
      candidate =
        candidate(toolkit, %{"messageTimestamp" => "2026-11-10T10:26:02+08:00"})

      assert candidate["minutesAgo"] == 14
    end
  end

  test "mail with an unknown receipt time is not presented as newly received" do
    for facts <- [%{}, %{"messageTimestamp" => "invalid"}] do
      refute Map.has_key?(candidate("outlook", facts), "minutesAgo")
    end
  end

  test "a fresh mail keeps its age and other sources keep collection age" do
    assert candidate("gmail", %{"messageTimestamp" => "2026-11-10T02:39:15Z"})["minutesAgo"] == 1
    assert candidate("slack", %{})["minutesAgo"] == 0
  end

  defp candidate(toolkit, facts) do
    item = %MemberSourceItem{
      id: "mail",
      toolkit: toolkit,
      facts: facts,
      first_seen_at: @now
    }

    %{"candidates" => [candidate]} =
      ProactiveCheck.attention_input([ProactiveCheck.view(item)], [], [], @now)

    candidate
  end
end
