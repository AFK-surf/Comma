defmodule KernelAgent.Driver do
  @moduledoc """
  Storage and command plumbing over the verified kernel's Session cursors.

  A revision is the kernel's cursor: fresh, committed, or pending. `write/3`
  stages events without I/O; `fence/2` makes the staged events durable through
  the kernel's fence: prepare, stamp, encode to `{:cas, key, bytes, base}`, and
  the storage result. Commands (`:input`, `:activate`, ...) run through the
  kernel's command driver, which asks this module to validate writes, perform
  effects, and fence.
  """

  alias KernelAgent.Store
  alias SalixVerifiedKernel.Session, as: K

  defstruct [:root, :key, :cursor]

  @report &__MODULE__.report/2

  @doc false
  def report(_outcome, _started), do: :ok

  @doc "The committed revision, or a fresh one when nothing is stored."
  def open(root, agent_id, session_id, attrs) do
    parent = self()

    reader = fn key, accept ->
      send(parent, {:session_key, key})
      accept.(Store.read(root, key))
    end

    result = K.read_revision(agent_id, session_id, reader)

    # The kernel asks for the object only when the session id is valid.
    key =
      receive do
        {:session_key, key} -> key
      after
        0 -> nil
      end

    case result do
      {:ok, cursor} ->
        {:ok, %__MODULE__{root: root, key: key, cursor: cursor}, :loaded}

      {:error, :not_found} ->
        state = K.new(agent_id, session_id, attrs)
        {:ok, %__MODULE__{root: root, key: key, cursor: K.start_revision(state, nil)}, :born}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The working state handle."
  def state(%__MODULE__{cursor: cursor}), do: cursor |> K.revision_view() |> elem(0)

  def pending?(%__MODULE__{cursor: cursor}), do: K.revision_pending?(cursor)

  @doc "Whether nothing is stored yet: the session is not born."
  def fresh?(%__MODULE__{cursor: cursor}), do: cursor |> K.revision_view() |> elem(1) |> is_nil()

  def query(rev, name, args \\ nil), do: K.query(state(rev), name, args)

  @doc "A query that reads external data through `read`."
  def query(rev, name, args, read), do: K.query(state(rev), name, args, read)
  def get(rev, field), do: K.get(state(rev), field)

  @doc "Stages events on the working revision. No I/O."
  def write(%__MODULE__{} = rev, [], _hwm), do: rev

  # Every write passes the kernel's validation first, as production commits do.
  # The kernel builds these events, so an invalid one is a broken invariant.
  def write(%__MODULE__{cursor: cursor} = rev, events, hwm) do
    case query(rev, :validate_events, events) do
      :ok -> %{rev | cursor: K.write_revision(cursor, events, hwm, @report)}
      {:error, reason} -> raise "invalid session events: #{inspect(reason)}"
    end
  end

  @doc "`{:ok, revision}` with every staged write durable."
  def fence(%__MODULE__{} = rev) do
    if pending?(rev) do
      with {:ok, fence} <- K.start_revision_fence(rev.cursor, rev.key) do
        {fence, request} =
          fence |> K.stamp_revision_fence(stamp(rev), @report) |> K.encode_revision_fence()

        case K.resume_revision_fence_cursor(fence, store_cas(rev, request)) do
          {:ok, cursor} -> {:ok, %{rev | cursor: cursor}}
          {:error, _candidate, reason} -> {:error, reason}
        end
      end
    else
      {:ok, rev}
    end
  end

  @doc "Stages and fences one commit."
  def commit(rev, events, hwm) do
    rev |> write(events, hwm) |> fence()
  end

  @doc "Plans a materialization. `{revision, outcome, changed?}`."
  def plan(%__MODULE__{cursor: cursor} = rev, mode) do
    {cursor, outcome, changed} = K.plan_revision(cursor, mode, @report)
    {%{rev | cursor: cursor}, outcome, changed}
  end

  @doc """
  Runs one kernel command to its return. `effect` answers the command's
  external effects. Returns `{result, revision}`.
  """
  def command(%__MODULE__{cursor: cursor} = rev, command, args, effect) do
    cursor |> K.start_command(command, args, nil, @report) |> drive(rev, effect)
  end

  defp drive({input, {:return, result, _checkpoint}}, rev, _effect),
    do: {result, %{rev | cursor: K.command_revision(input)}}

  # The command driver asks the host to validate each write. The kernel's
  # `validate_events` answers, as it does for production.
  defp drive({input, {:validate_write, events}}, rev, effect) do
    result = query(rev, :validate_events, events)
    input |> K.command_step(:write_result, result, @report) |> drive(rev, effect)
  end

  defp drive({input, {:effect, request}}, rev, effect),
    do: input |> K.command_step(:effect_result, effect.(request), @report) |> drive(rev, effect)

  defp drive({input, {:fence}}, rev, effect) do
    confirmed =
      if K.revision_pending?(K.command_revision(input)) do
        {:ok, fence} = K.start_revision_fence(input, rev.key)

        {fence, request} =
          fence |> K.stamp_revision_fence(stamp(rev), @report) |> K.encode_revision_fence()

        case K.resume_revision_fence_cursor(fence, store_cas(rev, request)) do
          {:ok, confirmed} -> confirmed
          # One owner writes this store, so a conflict is a broken invariant.
          {:error, _candidate, reason} -> raise "session fence failed: #{inspect(reason)}"
        end
      else
        {confirmed, {:committed}} = K.command_step(input, :fence_clean, nil, @report)
        confirmed
      end

    confirmed |> K.command_step(:next, nil, @report) |> drive(rev, effect)
  end

  defp store_cas(rev, {:cas, key, bytes, base}), do: Store.cas(rev.root, key, bytes, base)

  # The fence's commit metadata. A single local owner has no work index,
  # activity revision, or runtime identity; each write gets a fresh storage
  # revision.
  defp stamp(_rev) do
    revision = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {nil, [], nil, revision, revision, nil, nil}
  end
end
