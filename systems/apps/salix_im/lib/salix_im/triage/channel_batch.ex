defmodule SalixIM.Triage.ChannelBatch do
  @moduledoc """
  Channel evaluation scope, distinct from each message's physical reply thread.

  Only newly admitted ambient ClickHouse receipts opt into this scope. Existing
  receipts retain their original bucket and source identity during recovery.
  """

  def channel?(%{"scope_kind" => "channel"}), do: true
  def channel?(_scope), do: false

  def operation(authority),
    do:
      if(channel?(authority), do: "clickhouse.channel_current", else: "clickhouse.thread_current")

  def window(events) do
    timestamps = Enum.map(events, &micros(&1["message_ts"]))

    %{
      "oldest_ts_us" => Enum.min(timestamps),
      "latest_ts_us" => Enum.max(timestamps),
      "thread_roots" =>
        events |> Enum.map(& &1["bucket"]["thread_ts"]) |> Enum.uniq() |> Enum.sort()
    }
  end

  def selector(authority, identity, events) do
    base = %{
      "operation" => operation(authority),
      "tenant_id" => identity["tenant_id"],
      "workspace_id" => identity["workspace_id"],
      "channel_id" => authority["channel_id"],
      "thread_ts" => authority["thread_ts"],
      "limit" => 200,
      "max_bytes" => 1_048_576
    }

    if channel?(authority), do: Map.put(base, "source_window", window(events)), else: base
  end

  def physical_authority(authority, %{"root_thread_ts" => root}),
    do: authority |> Map.put("thread_ts", root) |> Map.delete("scope_kind")

  def physical_authority(authority, _message), do: authority

  def target(authority, events) do
    if channel?(authority) do
      event = Enum.max_by(events, &micros(&1["message_ts"]))
      authority |> Map.put("thread_ts", event["bucket"]["thread_ts"]) |> Map.delete("scope_kind")
    else
      authority
    end
  end

  def retain_root(normalized, %{"root_thread_ts" => root}),
    do: Map.put(normalized, "root_thread_ts", root)

  def retain_root(normalized, _message), do: normalized

  def project_thread(projected, %{"root_thread_ts" => root}, messages) do
    roots = messages |> Enum.map(& &1["root_thread_ts"]) |> Enum.uniq() |> Enum.sort()
    ordinal = Enum.find_index(roots, &(&1 == root)) + 1

    Map.put(
      projected,
      "thread_ref",
      "thread://run/t" <> String.pad_leading(to_string(ordinal), 3, "0")
    )
  end

  def project_thread(projected, _message, _messages), do: projected

  def micros(timestamp) do
    [seconds, fraction] = String.split(timestamp, ".", parts: 2)

    String.to_integer(seconds) * 1_000_000 +
      String.to_integer(String.pad_trailing(fraction, 6, "0"))
  end
end
