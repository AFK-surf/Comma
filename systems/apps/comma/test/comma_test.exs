defmodule CommaTest do
  use ExUnit.Case, async: true

  test "BridgeForTeams subsystem starts billing apps before BFT apps" do
    assert [
             :billing_core,
             :billing_commerce,
             :bridge_for_teams_core,
             :bridge_for_teams_web
           ] = Comma.apps(:bridge_for_teams)

    refute :billing_stripe in Comma.apps(:bridge_for_teams)
  end
end
