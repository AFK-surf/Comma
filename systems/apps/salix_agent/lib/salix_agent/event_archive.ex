defmodule SalixAgent.EventArchive do
  @moduledoc """
  Seam for archiving raw agent-loop I/O.

  Every item the loop RECEIVES or SENDS crosses one of six boundaries
  (docs/observability.md), and each one calls
  `record/1` here. The default implementation is no-op; production configures
  `:salix_agent, :event_archive_mod` to an adapter that seals to an age
  recipient and writes to ClickHouse.

  Two rules this module exists to enforce:

    * **Archiving can never affect the loop.** Every call is wrapped like
      `SalixAgent.Observability` — exceptions and exits are caught and logged,
      never propagated. A broken archive degrades to a gap, not to a failed
      turn. There is no mode in which it degrades to anything else: a `:strict`
      mode once claimed to, and could not, because every call site here
      discards the return value. It was removed rather than repaired, since
      wiring it up would contradict the rule in `systems/AGENTS.md` that
      archiving must never change a business result.

    * **Sealing happens in the calling process**, inside the adapter's
      `record/1`, before anything is buffered. The loop's plaintext therefore
      never enters a mailbox, a batch, or a crash dump. Do not "optimize" this
      by handing raw payloads to a GenServer.

  ## Payload discipline

  `record/1` takes the raw boundary object. Callers pass what actually crossed
  the boundary — full message lists, full tool arguments, full provider
  responses — and specifically do NOT redact, truncate, or summarize first.
  Redaction belongs to whoever holds the private key, not to the writer.
  """

  require Logger

  alias SalixAgent.AppRevision

  @type boundary ::
          :delivery
          | :llm_request
          | :llm_response
          | :tool_call
          | :tool_result
          | :egress

  @type fact :: %{
          required(:boundary) => boundary(),
          required(:direction) => :in | :out,
          required(:payload) => term(),
          optional(atom()) => term()
        }

  @callback record(fact()) :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Is the adapter actually able to archive right now?

  Optional. An adapter that cannot seal — no recipients configured, or a
  recipient list that failed to parse — must answer `false`, or callers pay
  full payload-assembly and delta-capture cost for items it discards on its
  first line.
  """
  @callback active?() :: boolean()

  @doc """
  Take the stream position an item WILL occupy, before producing it.

  Optional. The return value is opaque to callers and is handed back through
  `record/1` as `:reservation`.

  This exists for exactly one failure: a process that dies without running its
  own cleanup. Normally a lost item still consumes a `seq` at `record/1` time.
  But `Process.exit(pid, :kill)` is untrappable, so a cancelled dependency job
  never reaches the emitter at all — the item is never produced and no `seq` is
  consumed, so not even the *position* of the loss is recorded.

  ## What reserving does and does not buy

  It buys ONE thing: the `seq` is consumed up front, so the hole has a position.
  It does NOT make the loss visible on its own. `Completeness` finds a hole by
  bounding it between two stored rows, so an unredeemed reservation is
  reportable only if a LATER item lands on the same run. When the killed
  dispatch was the run's last activity, the reservation is the tail, nothing
  bounds it, and `archive.verify` reports a clean run — see the tail-loss test
  in `event_archive_test.exs`.

  And there is no counter to fall back on: `reserve/1` emits no telemetry, and
  nothing later notices that a reservation went unredeemed (the process that
  held it is gone). So an unredeemed TAIL reservation leaves no live signal at
  all. Making it one would need a sweep comparing reserved against written
  positions, which does not exist.

  Reserving is therefore a strict improvement over not reserving, and not a
  guarantee. Do not describe an unredeemed reservation as "the signal".
  """
  @callback reserve(fact()) :: term()

  @optional_callbacks active?: 0, reserve: 1

  @inbound ~w(delivery llm_response tool_result)a

  @doc """
  Archive one boundary crossing.

  `direction` is derived from the boundary rather than passed, so a caller
  cannot mislabel which way an item was travelling.
  """
  @spec record(map()) :: :ok | {:ok, map()} | {:error, term()}
  def record(%{boundary: boundary} = fact) do
    fact =
      fact
      |> Map.put(:direction, direction(boundary))
      |> Map.put_new_lazy(:app_revision, &AppRevision.value/0)

    safe_call(fact)
  end

  def record(_fact), do: {:error, :missing_boundary}

  @doc """
  Reserve the stream position an item will occupy. Returns `nil` when no
  adapter is configured, when it does not implement `reserve/1`, or on any
  failure — a reservation is an optimization for detectability, never a
  precondition for archiving.

  Hand the result back to `record/1` under `:reservation`.
  """
  @spec reserve(map()) :: term() | nil
  def reserve(%{boundary: boundary} = fact) do
    module = impl()

    if module != __MODULE__.Noop and function_exported?(module, :reserve, 1) do
      module.reserve(Map.put(fact, :direction, direction(boundary)))
    end
  rescue
    exception ->
      Logger.warning("event archive reserve failed: #{brief(exception)}")
      nil
  catch
    kind, _reason ->
      Logger.warning("event archive reserve exited: #{inspect(kind)}")
      nil
  end

  def reserve(_fact), do: nil

  @doc """
  Is a real archive configured AND able to accept items?

  Emitters gate all payload assembly on this. It consults the adapter, not just
  its presence: a wired adapter with no usable recipients archives nothing, and
  charging the loop for that would be pure waste.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    module = impl()

    cond do
      module == __MODULE__.Noop -> false
      function_exported?(module, :active?, 0) -> module.active?()
      true -> true
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp direction(boundary) when boundary in @inbound, do: :in
  defp direction(_boundary), do: :out

  defp impl, do: Application.get_env(:salix_agent, :event_archive_mod, __MODULE__.Noop)

  defp safe_call(fact) do
    impl().record(fact)
  rescue
    exception ->
      Logger.warning("event archive record failed: #{brief(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("event archive record exited: #{inspect(kind)}")
      {:error, {kind, reason}}
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(_fact), do: :ok
  end

  # Exception messages can carry the offending VALUE (Protocol.UndefinedError
  # appends "Got value: ..."), which is agent content. Logs are unencrypted, so
  # only the exception type and a short prefix are recorded.
  defp brief(exception) do
    exception.__struct__
    |> inspect()
    |> Kernel.<>(": ")
    |> Kernel.<>(exception |> Exception.message() |> String.slice(0, 120))
  end
end
