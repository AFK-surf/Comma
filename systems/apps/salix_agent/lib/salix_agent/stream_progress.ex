defmodule SalixAgent.StreamProgress do
  @moduledoc """
  What a streamed model attempt had received so far, readable after the
  process that made the request is gone.

  A model call runs in a dependency job that the session actor kills at its
  deadline with `Process.exit(pid, :kill)`. Everything the job knew about the
  stream — how many bytes had arrived, when the first one came, whether any
  text, tool-argument or reasoning delta ever reached the round — died with
  it, so a request killed at the ten-minute deadline could not be told apart
  from one whose provider held the connection open and sent nothing but
  keep-alives. The counters live in an `:atomics` array instead: the round
  creates it before starting the job, the job writes to it while the stream
  flows, and the actor reads it after the kill.

  Two kinds of progress are kept apart on purpose:

    * **body** — every response chunk `SalixLlm.Http` receives, keep-alive
      comments included. This is what the stream watchdog counts as activity.
    * **content** — a delta the round could use: text, a tool-argument
      fragment, or reasoning. A body that never becomes content is a provider
      heartbeating over an empty stream.

  The writers find the array in their process dictionary (`install/1` in the
  job process), so `SalixLlm.Http` needs no new plumbing through provider
  options, and every call is a no-op when nothing is installed. Times are
  monotonic milliseconds; `snapshot/1` renders them relative to the attempt.

  The retry loop calls `settle/1` when an attempt returns, whatever its
  result. An attempt that settled already has its own fact, so an owner that
  kills the job afterwards — while it waits before the next attempt, or after
  the request completed — must not report it again (`in_flight: false`).
  """

  @slots 12

  @attempt 1
  @attempt_started_mono 2
  @attempt_started_wall 3
  @first_body 4
  @last_body 5
  @bytes 6
  @chunks 7
  @first_content 8
  @last_content 9
  @content 10
  @http_status 11
  @settled 12

  @key __MODULE__

  @type t :: :atomics.atomics_ref()

  @typedoc """
  The rendered progress of the attempt in flight when the snapshot was taken.

  Millisecond fields are measured from the attempt's start. `received_bytes`,
  `received_chunks` and `http_status` are `nil` when no response body was
  ever observed (a provider that never answered, or a call that did not go
  through `SalixLlm.Http`).
  """
  @type snapshot :: %{
          attempt: pos_integer(),
          in_flight: boolean(),
          attempt_started_at_ms: integer(),
          elapsed_ms: non_neg_integer(),
          first_body_ms: non_neg_integer() | nil,
          last_body_ms: non_neg_integer() | nil,
          received_bytes: non_neg_integer() | nil,
          received_chunks: non_neg_integer() | nil,
          http_status: pos_integer() | nil,
          first_content_ms: non_neg_integer() | nil,
          last_content_ms: non_neg_integer() | nil,
          content_deltas: non_neg_integer()
        }

  @doc "A fresh progress array for one logical model request."
  @spec new() :: t()
  def new, do: :atomics.new(@slots, signed: true)

  @doc "Make `ref` the array the calling process's writers update."
  @spec install(t() | nil) :: :ok
  def install(ref) do
    if is_reference(ref), do: Process.put(@key, ref), else: Process.delete(@key)
    :ok
  end

  @doc "The array installed in the calling process, or `nil`."
  @spec current() :: t() | nil
  def current, do: Process.get(@key)

  @doc """
  Start attempt number `attempt` of the request: clears every counter of the
  previous attempt so the snapshot describes only the attempt in flight.
  """
  @spec begin_attempt(pos_integer(), t() | nil) :: :ok
  def begin_attempt(attempt, ref \\ current())

  def begin_attempt(attempt, ref) when is_reference(ref) and is_integer(attempt) do
    for slot <- @first_body..@settled, do: :atomics.put(ref, slot, 0)
    :atomics.put(ref, @attempt_started_mono, now())
    :atomics.put(ref, @attempt_started_wall, System.system_time(:millisecond))
    :atomics.put(ref, @attempt, attempt)
    :ok
  end

  def begin_attempt(_attempt, _ref), do: :ok

  @doc "The attempt in flight returned to the retry loop, with any result."
  @spec settle(t() | nil) :: :ok
  def settle(ref \\ current())

  def settle(ref) when is_reference(ref) do
    :atomics.put(ref, @settled, 1)
    :ok
  end

  def settle(_ref), do: :ok

  @doc "A response body chunk of `byte_count` bytes arrived with HTTP `status`."
  @spec observe_body(non_neg_integer(), term(), t() | nil) :: :ok
  def observe_body(byte_count, status, ref \\ current())

  def observe_body(byte_count, status, ref) when is_reference(ref) and is_integer(byte_count) do
    at = now()
    _ = :atomics.compare_exchange(ref, @first_body, 0, at)
    :atomics.put(ref, @last_body, at)
    :atomics.add(ref, @bytes, byte_count)
    :atomics.add(ref, @chunks, 1)
    if is_integer(status) and status > 0, do: :atomics.put(ref, @http_status, status)
    :ok
  end

  def observe_body(_byte_count, _status, _ref), do: :ok

  @doc "A text, tool-argument or reasoning delta reached the round."
  @spec observe_content(t() | nil) :: :ok
  def observe_content(ref \\ current())

  def observe_content(ref) when is_reference(ref) do
    at = now()
    _ = :atomics.compare_exchange(ref, @first_content, 0, at)
    :atomics.put(ref, @last_content, at)
    :atomics.add(ref, @content, 1)
    :ok
  end

  def observe_content(_ref), do: :ok

  @doc """
  The progress of the attempt in flight, or `nil` when `ref` is not a progress
  array or no attempt has begun on it.
  """
  @spec snapshot(t() | nil) :: snapshot() | nil
  def snapshot(ref) when is_reference(ref) do
    case :atomics.get(ref, @attempt) do
      attempt when attempt > 0 ->
        started = :atomics.get(ref, @attempt_started_mono)
        body_seen? = :atomics.get(ref, @first_body) != 0

        %{
          attempt: attempt,
          in_flight: :atomics.get(ref, @settled) == 0,
          attempt_started_at_ms: :atomics.get(ref, @attempt_started_wall),
          elapsed_ms: max(now() - started, 0),
          first_body_ms: relative(ref, @first_body, started),
          last_body_ms: relative(ref, @last_body, started),
          received_bytes: if(body_seen?, do: :atomics.get(ref, @bytes)),
          received_chunks: if(body_seen?, do: :atomics.get(ref, @chunks)),
          http_status: positive(:atomics.get(ref, @http_status)),
          first_content_ms: relative(ref, @first_content, started),
          last_content_ms: relative(ref, @last_content, started),
          content_deltas: :atomics.get(ref, @content)
        }

      _no_attempt ->
        nil
    end
  rescue
    # A reference that is not an atomics array: nothing to read.
    ArgumentError -> nil
  end

  def snapshot(_ref), do: nil

  defp relative(ref, slot, started) do
    case :atomics.get(ref, slot) do
      0 -> nil
      at -> max(at - started, 0)
    end
  end

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
