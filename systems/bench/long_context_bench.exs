# Long-context hot-path benchmark for Salix.
# Run from systems/:  mix run --no-start bench/long_context_bench.exs
#
# Builds a realistic ~150k-token session by applying journal events to a
# resident kernel session, then times the hot paths that scale with
# conversation length.

alias SalixAgent.Compaction
alias SalixAgent.InternalSession
alias SalixLlm.Convert
alias SalixStore.Codec

defmodule Bench do
  def time(label, iters, fun) do
    fun.()
    {us, _} = :timer.tc(fn -> for _ <- 1..iters, do: fun.() end)
    per = us / iters
    :erlang.garbage_collect()

    IO.puts(
      :io_lib.format("  ~-46ts ~10.3f ms/op  (~p iters)", [label, per / 1000, iters])
      |> to_string()
    )

    per
  end

  def filler(n), do: :crypto.strong_rand_bytes(div(n, 2)) |> Base.encode16()
end

sid = "s1"
msg_count = System.get_env("MSGS", "1500") |> String.to_integer()
avg_bytes = System.get_env("AVG_BYTES", "400") |> String.to_integer()

IO.puts("Building session: #{msg_count} messages, ~#{avg_bytes}B each ...")

event = fn i, id ->
  {type, extra} =
    case rem(i, 3) do
      0 ->
        {"delivery", %{"role" => "user", "source_message_id" => "src-#{id}"}}

      1 ->
        {"assistant",
         %{
           "tool_calls" => [
             %{
               "id" => "t#{id}",
               "name" => "read_file",
               "args" => %{"path" => "/a/b/c-#{id}.txt"}
             }
           ]
         }}

      2 ->
        {"tool_result", %{"tool_call_id" => "t#{id - 1}"}}
    end

  Map.merge(
    %{
      "type" => type,
      "session_id" => sid,
      "message_id" => id,
      "content" => Bench.filler(avg_bytes),
      "created_at" => id
    },
    extra
  )
end

{session, next_id} =
  Enum.reduce(1..msg_count, {InternalSession.new("agentA", sid), 1}, fn i, {session, id} ->
    {InternalSession.apply_event(session, event.(i, id)), id + 1}
  end)

messages = InternalSession.get(session, :messages)
total_bytes = Enum.reduce(messages, 0, fn m, a -> a + byte_size(to_string(m[:content] || "")) end)

IO.puts(
  "Built #{length(messages)} messages, ~#{div(total_bytes, 1024)} KB content (~#{div(total_bytes, 4000)}k tokens)\n"
)

# ---- correctness: incremental tally must equal a full recompute ----
exported = InternalSession.export(session)

old_style =
  [%{id: 0, role: "summary", content: exported.summary}]
  |> Enum.reject(&is_nil(&1.content))
  |> Kernel.++(Enum.filter(messages, &((&1[:id] || 0) > exported.compacted_through)))
  |> Enum.reduce(0, fn m, acc ->
    tc =
      case m[:tool_calls] do
        l when is_list(l) and l != [] -> byte_size(Jason.encode!(l))
        _ -> 0
      end

    acc + byte_size(to_string(m[:content] || "")) + tc
  end)

cached = InternalSession.context_byte_size(session)

unless cached == old_style do
  raise "byte tally mismatch: incremental=#{cached} recompute=#{old_style}"
end

IO.puts("OK incremental tally == full recompute (#{cached} bytes)")

# ---- correctness: stored snapshots admit back into the kernel ----
# `load` normalizes, so the reloaded state is compared with the normalized one.
normalized = session |> InternalSession.normalize() |> InternalSession.export()

reload = fn stored ->
  {:ok, loaded} = stored |> Codec.snapshot_etf() |> InternalSession.load()
  InternalSession.export(loaded)
end

legacy = exported |> :erlang.term_to_binary([:compressed]) |> :zlib.gzip()

unless reload.(legacy) == normalized do
  raise "legacy gzip snapshot failed to reload"
end

new_body = session |> InternalSession.persist() |> Codec.compress_snapshot_etf()

unless reload.(new_body) == normalized do
  raise "kernel snapshot round-trip failed"
end

IO.puts("OK legacy gzip + kernel snapshots both reload\n")

IO.puts("== Hot paths ==")

Bench.time("Compaction.should_compact?/2 (per cycle)", 200, fn ->
  Compaction.should_compact?(session, context_tokens: 200_000)
end)

Bench.time("masked_messages (transcript for an LLM call)", 50, fn ->
  InternalSession.masked_messages(session)
end)

Bench.time("Convert.to_anthropic/1 (per LLM call)", 200, fn ->
  Convert.to_anthropic(messages)
end)

Bench.time("apply_event tool_result (resident)", 200, fn ->
  InternalSession.apply_event(session, event.(2, next_id))
end)

Bench.time("persist + zstd (per commit)", 50, fn ->
  session |> InternalSession.persist() |> Codec.compress_snapshot_etf()
end)

Bench.time("load from stored snapshot (per cold read)", 20, fn ->
  {:ok, _} = new_body |> Codec.snapshot_etf() |> InternalSession.load()
end)

new_msg = %{id: msg_count + 1, role: "user", content: Bench.filler(avg_bytes)}
Bench.time("messages ++ [msg]", 2000, fn -> messages ++ [new_msg] end)
Bench.time("[msg | messages] (prepend)", 2000, fn -> [new_msg | messages] end)

Bench.time("Enum.reverse |> find (current)", 2000, fn ->
  messages |> Enum.reverse() |> Enum.find(&(&1[:role] == "user"))
end)

Bench.time("Enum.reduce last-match", 2000, fn ->
  Enum.reduce(messages, nil, fn m, acc -> if m[:role] == "user", do: m, else: acc end)
end)

# ---- snapshot encoding analysis (the per-commit bottleneck) ----
IO.puts("\n== snapshot encoding options (time + size) ==")
sz = fn b -> "#{div(byte_size(b), 1024)} KB" end

opts = [
  {"kernel persist (raw ETF)", fn -> InternalSession.persist(session) end},
  {"kernel persist |> zstd  (NOW IN USE)",
   fn -> session |> InternalSession.persist() |> Codec.compress_snapshot_etf() end},
  {"exported term_to_binary() (raw, host encoder)", fn -> :erlang.term_to_binary(exported) end},
  {"exported term_to_binary([{:compressed,1}])",
   fn -> :erlang.term_to_binary(exported, [{:compressed, 1}]) end},
  {"exported term_to_binary([:compressed]) |> gzip  (legacy)",
   fn -> exported |> :erlang.term_to_binary([:compressed]) |> :zlib.gzip() end}
]

for {label, f} <- opts do
  out = f.()
  _ = Bench.time(label, 20, f)
  IO.puts("       -> size #{sz.(out)}")
end

# ---- multi-session persist scenario ----
# Split-state persist re-encodes every session on every commit; this line
# measures the un-cached worst case (cold cache / first commit).
IO.puts("\n== Per-commit persist of ALL sessions (cold cache, multi-session agent) ==")
n_sessions = System.get_env("SESSIONS", "8") |> String.to_integer()
sessions = Map.new(1..n_sessions, fn i -> {"s#{i}", session} end)

Bench.time("persist ALL #{n_sessions} sessions", 10, fn ->
  Enum.map(sessions, fn {_sid, s} ->
    s |> InternalSession.persist() |> Codec.compress_snapshot_etf()
  end)
end)
