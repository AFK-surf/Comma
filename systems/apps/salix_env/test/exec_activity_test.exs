defmodule SalixEnv.ExecActivityTest do
  use ExUnit.Case, async: false

  alias SalixEnv.{Control, ExecActivity}

  test "records and returns the latest entry, ignoring blanks and stale puts" do
    assert ExecActivity.get("cr-missing") == nil
    assert ExecActivity.record("cr-act-1", "") == nil
    assert ExecActivity.record("", "install deps") == nil
    assert ExecActivity.record("cr-act-1", nil) == nil

    assert %{"description" => "install deps", "at" => at} =
             ExecActivity.record("cr-act-1", "install deps")

    assert ExecActivity.get("cr-act-1") == %{"description" => "install deps", "at" => at}

    # Peer casts can arrive out of order; an older entry never wins.
    :ok = ExecActivity.put("cr-act-1", %{"description" => "stale", "at" => at - 5})
    assert ExecActivity.get("cr-act-1")["description"] == "install deps"

    assert %{"description" => "run tests"} = ExecActivity.record("cr-act-1", "run tests")
    assert ExecActivity.get("cr-act-1")["description"] == "run tests"
  end

  test "environment_json merges last_exec only when an entry exists" do
    entry = ExecActivity.record("cr-act-proj", "run tests")

    env = Control.environment_json(%{"connector_run_id" => "cr-act-proj", "meta" => %{}})
    assert env["last_exec"] == entry

    bare = Control.environment_json(%{"connector_run_id" => "cr-act-none", "meta" => %{}})
    refute Map.has_key?(bare, "last_exec")
  end
end
