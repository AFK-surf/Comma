defmodule CommaWeb.RecommendationLarkMemberSourceTest do
  use ExUnit.Case, async: true

  alias CommaWeb.RecommendationLarkMemberSource

  test "formats search time_range as whole-second RFC3339 with explicit timezone offset" do
    now = ~U[2026-11-27 04:30:15.654321Z]
    {:ok, seen} = Agent.start_link(fn -> [] end)

    request = fn
      :get, "/authen/v1/user_info", _opts ->
        {:ok, %{"open_id" => "ou_me"}}

      :post, "/im/v1/messages/search", opts ->
        body = Keyword.fetch!(opts, :json)
        Agent.update(seen, &[body | &1])
        {:ok, %{"items" => []}}

      :get, "/calendar/v4/calendars/primary/events/instance_view", _opts ->
        {:ok, %{"items" => []}}
    end

    assert {:ok, %{"messages" => %{"matches" => []}}} =
             RecommendationLarkMemberSource.read(
               "feishu",
               request,
               now,
               %{"provider_user_id" => "ou_me"}
             )

    bodies = Agent.get(seen, & &1)
    assert length(bodies) == 2

    for body <- bodies do
      time_range = get_in(body, ["filter", "time_range"])
      assert time_range["start_time"] == "2026-11-20T04:30:15+00:00"
      assert time_range["end_time"] == "2026-11-27T04:30:15+00:00"

      for value <- [time_range["start_time"], time_range["end_time"]] do
        assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/, value)
      end
    end
  end
end
