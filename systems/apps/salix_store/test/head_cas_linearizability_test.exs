defmodule SalixStore.HeadCasLinearizabilityTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{Agent, Ids}
  @sm SalixStore.TestSM

  test "concurrent claims and commits preserve every acknowledged root update" do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    id = Ids.new_agent_id(group)

    config = %{
      "agent_id" => id,
      "tenant_id" => tenant,
      "group_id" => group,
      "role" => "worker",
      "name" => "Contention",
      "status" => "idle",
      "runtime_config" => %{"kind" => "internal"},
      "heartbeat_schedule_id" => Ids.new_schedule_id()
    }

    {:ok, _} = Agent.create(id, "creator", @sm, config: config)

    outcomes =
      1..12
      |> SystemsClock.async_stream(
        fn n ->
          case Agent.claim(id, "owner-#{n}", @sm, steal: true) do
            {:ok, owned} -> commit_until_fenced(owned, 6, [])
            {:error, :claim_exhausted} -> []
          end
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.flat_map(fn {:ok, commits} -> commits end)

    assert outcomes != []
    seqs = Enum.map(outcomes, fn {_node, _epoch, seq} -> seq end)
    assert Enum.sort(seqs) == Enum.to_list(1..length(outcomes))

    for {_epoch, commits} <- Enum.group_by(outcomes, &elem(&1, 1)) do
      assert commits |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1
    end

    assert {:ok, fresh} = Agent.claim(id, "auditor", @sm, steal: true)
    assert fresh.state == %{counter: length(outcomes), ops: length(outcomes)}
    assert fresh.head.journal_tail.seq == length(outcomes)
    assert fresh.epoch > outcomes |> Enum.map(&elem(&1, 1)) |> Enum.max()
  end

  defp commit_until_fenced(_owned, 0, acc), do: acc

  defp commit_until_fenced(owned, remaining, acc) do
    case Agent.commit(owned, [%{op: "inc", by: 1}]) do
      {:ok, next} ->
        commit_until_fenced(next, remaining - 1, [
          {next.node_id, next.epoch, next.head.journal_tail.seq} | acc
        ])

      {:error, :fenced} ->
        acc
    end
  end
end
