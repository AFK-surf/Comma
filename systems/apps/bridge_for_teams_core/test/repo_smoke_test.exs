defmodule BridgeForTeams.RepoSmokeTest do
  use BridgeForTeams.DataCase, async: true

  test "the repo is started and answers a trivial query" do
    assert Repo.query!("SELECT 1").rows == [[1]]
  end
end
