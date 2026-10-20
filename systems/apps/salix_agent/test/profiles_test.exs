defmodule SalixAgent.ProfilesTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.Profiles

  @now 1_800_000_000_000
  @hour 3_600_000

  # A record as AccountPool stores it: the Profile, with the server's fields beside it.
  defp account(id, windows, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "disabled" => false,
        "credentials" => "sealed",
        "quota" => %{
          "observed_at" => @now,
          "windows" =>
            for {minutes, left, reset, model} <- windows do
              %{
                "minutes" => minutes,
                "used_percent" => 100 - left,
                "resets_at" => reset,
                "model" => model
              }
            end
        }
      },
      extra
    )
  end

  defp ids(records), do: Enum.map(records, & &1["id"])

  test "the plan whose week is lost soonest goes first, one asked to wait last, as a station's pool orders them" do
    later =
      account("later", [{300, 90, @now + @hour, nil}, {10_080, 60, @now + 5 * 24 * @hour, nil}])

    soon = account("soon", [{300, 90, @now + @hour, nil}, {10_080, 50, @now + 12 * @hour, nil}])
    waiting = account("waiting", [], %{"cooldown_until" => @now + @hour})

    assert ids(Profiles.rank([waiting, later, soon], now: @now)) == ["soon", "later", "waiting"]
  end

  test "a used-up window passes an account over until it refills; a model's own counts for that model" do
    spent = account("spent", [{300, 0, @now + @hour, nil}])
    assert Profiles.rank([spent], now: @now) == []
    assert Profiles.exhausted?(spent)

    assert ids(Profiles.rank([account("spent", [{300, 0, @now - 1, nil}])], now: @now)) == [
             "spent"
           ]

    gemini = account("g", [{300, 0, @now + @hour, "gemini-3-flash"}], %{"source" => "gemini"})
    assert ids(Profiles.rank([gemini], model: "gemini-3-pro", now: @now)) == ["g"]

    assert Profiles.rank([gemini],
             model: "gemini-3-pro",
             provider_model: "gemini-3-flash",
             now: @now
           ) ==
             []
  end
end
