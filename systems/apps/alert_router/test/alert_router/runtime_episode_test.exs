defmodule AlertRouter.RuntimeEpisodeTest do
  use ExUnit.Case, async: true
  alias AlertRouter.RuntimeEpisode

  test "failure, exhaustion and recovery update one episode; later failure opens another" do
    {:ok, failed, p1} = RuntimeEpisode.consume(%{}, fact(1, "runtime_failed"))
    {:ok, exhausted, p0} = RuntimeEpisode.consume(failed, fact(2, "recovery_exhausted"))
    {:ok, repeated, nil} = RuntimeEpisode.consume(exhausted, fact(3, "runtime_failed"))
    {:ok, recovered, green} = RuntimeEpisode.consume(repeated, fact(4, "runtime_recovered"))

    {:ok, _next, new} =
      RuntimeEpisode.consume(%{}, Map.put(fact(5, "runtime_failed"), "episode_id", id(5)))

    assert {:ok, ^recovered, nil} =
             RuntimeEpisode.consume(recovered, fact(2, "recovery_exhausted"))

    assert p1.priority == "P1"
    assert p0.priority == "P0"
    assert p1.incident_key == p0.incident_key
    assert green.incident_key == p1.incident_key
    assert green.recovery_status == "verified"
    assert new.incident_key != green.incident_key
    assert new.priority == "P1"
  end

  test "persisted incident priority and recovery survive restart and old failure replay" do
    {:ok, a, _} = RuntimeEpisode.consume(%{}, fact(1, "runtime_failed"))
    {:ok, b, _} = RuntimeEpisode.consume(a, fact(2, "runtime_recovered"))
    restored = b |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^restored, nil} = RuntimeEpisode.consume(restored, fact(2, "runtime_recovered"))
    assert {:ok, ^restored, nil} = RuntimeEpisode.consume(restored, fact(1, "runtime_failed"))
    assert restored["recovered"]
  end

  test "another execution cannot recover this execution" do
    {:ok, state, _} = RuntimeEpisode.consume(%{}, fact(1, "runtime_failed"))

    other =
      Map.put(fact(2, "runtime_recovered"), "identity", [
        "staging",
        "tenant",
        "agent",
        "session",
        "dispatch",
        "other"
      ])

    assert {:error, :execution_identity_mismatch} = RuntimeEpisode.consume(state, other)
  end

  test "self-contained recovery may arrive first; unscoped recovery and completion are rejected" do
    assert {:ok, _, %{recovery_status: "verified"}} =
             RuntimeEpisode.consume(%{}, fact(2, "runtime_recovered"))

    assert {:error, :invalid_runtime_fact} =
             RuntimeEpisode.consume(%{}, Map.delete(fact(2, "runtime_recovered"), "episode_id"))

    assert {:error, :invalid_kind} = RuntimeEpisode.consume(%{}, fact(2, "agent_settled"))
    assert {:error, :invalid_kind} = RuntimeEpisode.consume(%{}, fact(2, "closed"))
  end

  defp fact(n, kind),
    do: %{
      "identity" => ["staging", "tenant", "agent", "session", "dispatch", "execution"],
      "record_id" => id(n),
      "episode_id" => id(1),
      "started_at" => "2026-09-07T00:00:00Z",
      "priority" => if(kind == "recovery_exhausted", do: "P0", else: "P1"),
      "kind" => kind,
      "observed_at" => "2026-09-07T00:00:00Z"
    }

  defp id(n), do: "01ARZ3NDEKTSV4RRFFQ69G5F" <> String.pad_leading(Integer.to_string(n), 2, "0")
end
