defmodule SalixVerifiedKernel.SnapshotEncodingTest do
  use ExUnit.Case, async: false
  alias SalixVerifiedKernel.Session

  test "dense immutable snapshots encode identically across concurrent readers" do
    state = dense_snapshot(400)
    before = Session.export(state)
    expected = Session.persist(state)

    results =
      1..8
      |> Task.async_stream(fn _ -> Session.persist(state) end, max_concurrency: 4)
      |> Enum.map(fn {:ok, bytes} -> bytes end)

    assert Enum.all?(results, &(&1 == expected))
    assert {:comma_internal_session, 3, decoded} = :erlang.binary_to_term(expected)
    assert decoded.messages == before.messages
    assert decoded.context_provider_states == %{}
    assert Session.export(state) == before
    assert {:ok, restored} = Session.load(expected)
    assert Session.get(restored, :messages) == before.messages
  end

  test "snapshots keep atom and integer values across every encoding width" do
    long_atom = String.to_atom(String.duplicate("é", 255))

    values = [
      :plain,
      :naïve_ключ,
      long_atom,
      255,
      256,
      -1,
      -2_147_483_648,
      2_147_483_647,
      2_147_483_648,
      1_790_631_374_773,
      -1_790_631_374_773,
      18_446_744_073_709_551_615,
      18_446_744_073_709_551_616,
      -(2 ** 70)
    ]

    state =
      Session.new("agent", "session")
      |> Session.export()
      |> Map.put(:messages, [%{id: 1, seq: 1, role: "user", content: "x", metadata: values}])
      |> Session.open()

    bytes = Session.persist(state)
    assert {:comma_internal_session, 3, decoded} = :erlang.binary_to_term(bytes)
    assert [%{metadata: ^values}] = decoded.messages
    assert {:ok, restored} = Session.load(bytes)
    assert [%{metadata: ^values}] = Session.get(restored, :messages)
  end

  @tag :activation_latency
  test "dense snapshot encoding benchmark includes many small nested terms" do
    state = dense_snapshot(4_000)

    for _ <- 1..5 do
      {us, bytes} = :timer.tc(fn -> Session.persist(state) end)
      assert byte_size(bytes) > 11_000_000
      IO.puts("dense snapshot persist: #{us / 1000} ms, #{byte_size(bytes)} bytes")
    end
  end

  defp dense_snapshot(count) do
    messages =
      for n <- 1..count do
        %{
          id: n,
          seq: n,
          role: "user",
          content: String.duplicate("x", 2_000),
          metadata:
            for j <- 1..10 do
              %{
                "key" => "value#{j}",
                "flag" => true,
                "index" => j,
                "fields" => ["a", "b", "c"]
              }
            end
        }
      end

    Session.new("agent", "session")
    |> Session.export()
    |> Map.put(:messages, messages)
    |> Session.open()
  end
end
