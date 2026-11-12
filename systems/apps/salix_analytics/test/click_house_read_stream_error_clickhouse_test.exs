defmodule SalixAnalytics.ClickHouseReadStreamErrorClickHouseTest do
  @moduledoc """
  What a live server sends when a query fails after its response started.

  The queries write more than the server's response buffer before they fail, so
  the failure arrives after the 200. `click_house_read_decode_test.exs` holds
  the same contract on fixed bodies.
  """
  use SystemsClock.Case, async: false

  alias SalixAnalytics.ClickHouseRead

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"
  @formats [json_each_row: "JSONEachRow", compact_with_names: "JSONCompactEachRowWithNames"]

  setup_all do
    prev = SystemsRuntime.get_env(:salix_analytics, :clickhouse)

    SystemsRuntime.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "default.events"
    )

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_analytics, :clickhouse, prev),
        else: SystemsRuntime.delete_env(:salix_analytics, :clickhouse)
    end)
  end

  defp failing_at(row, code, format) do
    fn _database ->
      """
      SELECT number, repeat('x', 2000) AS padding,
             throwIf(number = #{row}, 'stream failure', toInt16(#{code})) AS failed
      FROM numbers(5000)
      SETTINGS max_block_size = 100, allow_custom_error_code_in_throwif = 1
      FORMAT #{format}
      """
    end
  end

  # 25.3 ends the 200 with an exception line; 26.9 closes the connection. Either
  # way the read must fail, and never hand back the rows that came before it.
  test "a budget failure mid-stream is the over-budget error" do
    for {format, name} <- @formats do
      assert {:error, reason} =
               ClickHouseRead.run(failing_at(2_000, 241, name), [], format: format)

      assert match?({:read_over_budget, %{code: 241}}, reason) or closed?(reason)
    end
  end

  test "any other failure mid-stream is an http error" do
    for {format, name} <- @formats do
      assert {:error, reason} =
               ClickHouseRead.run(failing_at(2_000, 395, name), [], format: format)

      assert match?({:http, "Code: 395." <> _}, reason) or closed?(reason)
    end
  end

  defp closed?(reason), do: match?(%Req.TransportError{reason: :closed}, reason)

  test "a query that does not fail returns all its rows" do
    for {format, name} <- @formats do
      assert {:ok, rows} = ClickHouseRead.run(failing_at(9_999, 395, name), [], format: format)
      assert length(rows) == 5_000
    end
  end

  test "a selected column named exception stays a row" do
    sql = fn _database -> "SELECT 'stored' AS exception FORMAT JSONEachRow" end
    assert {:ok, [%{"exception" => "stored"}]} = ClickHouseRead.run(sql, [])
  end
end
