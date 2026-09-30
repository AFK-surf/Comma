defmodule SalixAnalytics.ClickHouseReadDecodeTest do
  use ExUnit.Case, async: true

  alias SalixAnalytics.ClickHouseRead

  test "JSONEachRow decodes one map per line" do
    body = ~s({"a":1,"b":"x"}\n{"a":2,"b":null}\n)

    assert {:ok, [%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => nil}]} =
             ClickHouseRead.decode_rows(body, :json_each_row)

    assert {:error, {:bad_row, "nope"}} = ClickHouseRead.decode_rows("nope\n", :json_each_row)
  end

  test "JSONCompactEachRowWithNames decodes to the same maps as JSONEachRow" do
    body = ~s(["a","b"]\n[1,"x"]\n[2,null]\n)
    assert {:ok, rows} = ClickHouseRead.decode_rows(body, :compact_with_names)
    assert rows == [%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => nil}]

    assert {:ok, []} = ClickHouseRead.decode_rows("", :compact_with_names)
    assert {:ok, []} = ClickHouseRead.decode_rows(~s(["a","b"]\n), :compact_with_names)
  end

  test "a compact row with the wrong width or a bad header is an error, not a shifted map" do
    assert {:error, {:bad_row, "[1]"}} =
             ClickHouseRead.decode_rows(~s(["a","b"]\n[1]\n), :compact_with_names)

    assert {:error, {:bad_row, ~s({"a":1})}} =
             ClickHouseRead.decode_rows(~s({"a":1}\n[1]\n), :compact_with_names)
  end
end
