defmodule SalixAnalytics.SinkTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.Sink
  alias SalixAnalytics.Sink.{ClickHouse, Memory}

  describe "Sink.dedup_key/1" do
    test "stable on identity (agent, seq, type, message_id) and distinct otherwise" do
      r = %{"_agent" => "a", "_seq" => 2, "type" => "assistant", "message_id" => 7}
      assert Sink.dedup_key(r) == Sink.dedup_key(r)
      refute Sink.dedup_key(r) == Sink.dedup_key(%{r | "message_id" => 8})
      refute Sink.dedup_key(r) == Sink.dedup_key(%{r | "_seq" => 3})
    end
  end

  describe "Memory sink" do
    setup do
      start_supervised!(Memory)
      :ok
    end

    test "dedups re-inserted rows" do
      rows = rows()

      assert {:ok, 2} = Memory.insert(rows)
      assert {:ok, 2} = Memory.insert(rows)
      assert Memory.count() == 2
      assert Memory.rows() == rows
    end
  end

  describe "ClickHouse sink (mock HTTP server)" do
    setup do
      start_supervised!(SalixAnalytics.MockClickHouse)

      bandit =
        start_supervised!(
          {Bandit,
           plug: SalixAnalytics.MockClickHouse, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {__MODULE__, :bandit}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

      prev = Application.get_env(:salix_analytics, :clickhouse)

      Application.put_env(:salix_analytics, :clickhouse,
        base_url: "http://127.0.0.1:#{port}/",
        table: "test.events"
      )

      on_exit(fn -> Application.put_env(:salix_analytics, :clickhouse, prev) end)
      :ok
    end

    test "rows land as JSONEachRow and duplicate dedup keys overwrite" do
      assert {:ok, 2} = ClickHouse.insert(rows())
      assert {:ok, 2} = ClickHouse.insert(rows())

      assert SalixAnalytics.MockClickHouse.count() == 2

      assert Enum.sort_by(SalixAnalytics.MockClickHouse.rows(), & &1["message_id"]) == [
               %{
                 "agent" => "a",
                 "dedup" => "a|1|delivery|1",
                 "message_id" => 1,
                 "payload" => Jason.encode!(Enum.at(rows(), 0)),
                 "seq" => 1,
                 "type" => "delivery"
               },
               %{
                 "agent" => "a",
                 "dedup" => "a|1|assistant|2",
                 "message_id" => 2,
                 "payload" => Jason.encode!(Enum.at(rows(), 1)),
                 "seq" => 1,
                 "type" => "assistant"
               }
             ]
    end
  end

  defp rows do
    [
      %{"_agent" => "a", "_seq" => 1, "type" => "delivery", "message_id" => 1},
      %{"_agent" => "a", "_seq" => 1, "type" => "assistant", "message_id" => 2}
    ]
  end
end
