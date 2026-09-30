defmodule SalixAgent.SSH.Sessions do
  @moduledoc """
  Outbound SSH sessions (`SalixAgent.SSH.Session`) of one Agent session.

  Each session actor (`SalixAgent.InternalSessionActor`,
  `SalixAgent.ExternalSessionActor`) supervises its own SSH sessions. On the
  first `ssh.open` it starts one `DynamicSupervisor` linked to itself, so
  every SSH session ends when the actor ends. An actor with SSH session
  processes is not idle and does not stop or get evicted for idleness.

  Tool jobs run on the node of their session actor, so every lookup is local:
  `SalixAgent.SSH.Registry` maps `{agent_id, session_id, ssh_session_id}` to
  the session, and another Agent session cannot reach it.

  Admission runs inside the actor (`start/2`), so it is serialized per Agent
  session. An Agent session has at most #{4} open SSH sessions. Closed and
  failed sessions stay readable for a short time: at most #{8} per Agent
  session, oldest removed first.
  """

  alias SalixAgent.SSH.{Connection, Session}

  @registry SalixAgent.SSH.Registry
  @max_open 4
  @max_retained 8
  @open_timeout_ms 40_000
  @actor_timeout_ms 10_000

  # ---- tool side (runs in the tool job) ---------------------------------------

  @doc "Open a session, or return the one this tool call already opened."
  @spec open(map()) :: {:ok, map()} | {:error, map()}
  def open(spec) do
    with {:ok, pid} <- existing_or_admitted(spec) do
      case Session.request(pid, :await_open, @open_timeout_ms) do
        {:error, reason} when is_atom(reason) -> {:error, gone(spec.id, reason)}
        result -> result
      end
    end
  end

  defp existing_or_admitted(spec) do
    case Registry.lookup(@registry, key(spec)) do
      [{pid, _}] -> {:ok, pid}
      [] -> admit_through_actor(spec)
    end
  end

  defp admit_through_actor(spec) do
    result =
      case actor(spec.agent_id, spec.session_id) do
        {:internal, pid} ->
          SalixAgent.SessionResidency.call(pid, {:ssh_start, spec}, @actor_timeout_ms)

        {:external, pid} ->
          GenServer.call(pid, {:ssh_start, spec}, @actor_timeout_ms)

        nil ->
          {:error, :no_session_actor}
      end

    case result do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, %{"code" => _} = diagnostic} -> {:error, diagnostic}
      other -> {:error, unavailable(other)}
    end
  catch
    :exit, reason -> {:error, unavailable(reason)}
  end

  defp actor(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, {:internal_session, agent_id, session_id}) do
      [{pid, _}] ->
        {:internal, pid}

      [] ->
        case Registry.lookup(SalixAgent.Registry, {:external_session, agent_id, session_id}) do
          [{pid, _}] -> {:external, pid}
          [] -> nil
        end
    end
  end

  @doc "Send a request to one session of the calling Agent session."
  @spec request(map(), String.t(), term(), pos_integer()) :: {:ok, map()} | {:error, map()}
  def request(owner, id, message, timeout_ms) do
    with {:ok, pid} <- lookup(owner, id) do
      case Session.request(pid, message, timeout_ms) do
        {:error, reason} when is_atom(reason) -> {:error, gone(id, reason)}
        result -> result
      end
    end
  end

  @doc """
  Run `{module, function, args}` in the calling tool job with the session's
  connection prepended to `args`. Used for exec and SFTP channels.
  """
  @spec with_connection(map(), String.t(), mfa(), pos_integer()) :: term()
  def with_connection(owner, id, {module, function, args}, timeout_ms) do
    with {:ok, pid} <- lookup(owner, id) do
      case Session.request(pid, :connection, timeout_ms) do
        {:ok, conn, _summary} -> apply(module, function, [conn | args])
        {:error, reason} when is_atom(reason) -> {:error, gone(id, reason)}
        {:error, diagnostic} -> {:error, diagnostic}
      end
    end
  end

  @doc "The Agent session's SSH sessions, open and recently closed."
  @spec list(map()) :: {:ok, [map()]}
  def list(owner) do
    sessions =
      owner
      |> entries()
      |> Enum.sort_by(fn {_key, _pid, value} -> value.started_at end)
      |> Enum.map(fn {{_agent, _session, id}, _pid, value} ->
        %{
          "ssh_session_id" => id,
          "status" => to_string(value.status),
          "host" => value.host,
          "port" => value.port,
          "user" => value.user
        }
      end)

    {:ok, sessions}
  end

  # ---- actor side (runs in the session actor) ----------------------------------

  @doc """
  Admit and start an SSH session under the calling actor's supervisor.
  Returns the reply and the supervisor, which the actor keeps in its state.
  """
  @spec start(pid() | nil, map()) :: {{:ok, pid()} | {:error, map()}, pid()}
  def start(supervisor, spec) do
    supervisor = ensure_supervisor(supervisor)

    reply =
      case Registry.lookup(@registry, key(spec)) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          entries = entries(spec)
          remove_retained(supervisor, entries)

          with :ok <- within_limit(entries) do
            case DynamicSupervisor.start_child(supervisor, {Session, spec}) do
              {:ok, pid} ->
                # The actor's idle check depends on its SSH sessions; the
                # monitor wakes it when one exits.
                Process.monitor(pid)
                {:ok, pid}

              {:error, {:already_started, pid}} ->
                {:ok, pid}

              {:error, reason} ->
                {:error, unavailable(reason)}
            end
          end
      end

    {reply, supervisor}
  end

  @doc "Whether the actor's supervisor holds any SSH session process."
  @spec live?(pid() | nil) :: boolean()
  def live?(supervisor) when is_pid(supervisor) do
    DynamicSupervisor.count_children(supervisor).active > 0
  catch
    :exit, _ -> false
  end

  def live?(_supervisor), do: false

  defp ensure_supervisor(supervisor) when is_pid(supervisor), do: supervisor

  defp ensure_supervisor(nil) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    supervisor
  end

  defp within_limit(entries) do
    open = Enum.filter(entries, fn {_key, _pid, value} -> open?(value) end)

    if length(open) >= @max_open do
      {:error,
       Connection.diagnostic(
         "ssh_session_limit",
         "This Agent session already has #{@max_open} open SSH sessions. Close one with ssh.close before opening another.",
         %{
           "limit" => @max_open,
           "open_ssh_session_ids" => Enum.map(open, fn {{_, _, id}, _pid, _value} -> id end)
         }
       )}
    else
      :ok
    end
  end

  defp remove_retained(supervisor, entries) do
    entries
    |> Enum.reject(fn {_key, _pid, value} -> open?(value) end)
    |> Enum.sort_by(fn {_key, _pid, value} -> value.started_at end, :desc)
    |> Enum.drop(@max_retained - 1)
    |> Enum.each(fn {_key, pid, _value} -> DynamicSupervisor.terminate_child(supervisor, pid) end)
  end

  # ---- helpers --------------------------------------------------------------------

  defp lookup(owner, id) do
    case Registry.lookup(@registry, {owner.agent_id, owner.session_id, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, gone(id, :not_found)}
    end
  end

  defp entries(owner) do
    Registry.select(@registry, [
      {{{:"$1", :"$2", :"$3"}, :"$4", :"$5"},
       [{:==, :"$1", owner.agent_id}, {:==, :"$2", owner.session_id}],
       [{{{{:"$1", :"$2", :"$3"}}, :"$4", :"$5"}}]}
    ])
  end

  defp key(spec), do: {spec.agent_id, spec.session_id, spec.id}

  defp open?(%{status: status}), do: status in [:connecting, :open]

  defp unavailable(reason) do
    Connection.diagnostic(
      "ssh_unavailable",
      "The SSH session could not start in this Agent session. Retry the call.",
      %{"reason" => inspect(reason)}
    )
  end

  defp gone(id, :busy) do
    Connection.diagnostic(
      "session_busy",
      "The SSH session did not answer in time. Retry the call.",
      %{"ssh_session_id" => id}
    )
  end

  defp gone(id, _reason) do
    Connection.diagnostic(
      "ssh_session_not_found",
      "No SSH session #{id} exists in this Agent session. Sessions end on ssh.close, when the remote shell exits or disconnects, after 30 minutes without use, and when the Agent session's runtime stops, for example on an Agent restart or a platform deploy. Open a new session with ssh.open; remote work that must survive this belongs in tmux or screen on the remote host.",
      %{"ssh_session_id" => id}
    )
  end
end
