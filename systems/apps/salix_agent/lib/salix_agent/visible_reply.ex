defmodule SalixAgent.VisibleReply do
  @moduledoc """
  External authorization and transient Participant-draft I/O.

  Lean decides scope reuse, retirement, retry, and commit order. This adapter
  reports authority responses and executes presentation requests. Canonical
  Messages require an explicit provider send.
  """

  alias SalixAgent.{DraftSurface, SessionActivity}

  @callback authorize(agent_id :: String.t(), scope :: map()) :: :ok | {:error, term()}

  @spec authorize(String.t(), map()) :: :ok | :none | {:error, term()}
  def authorize(agent_id, scope) when is_binary(agent_id) and is_map(scope) do
    case impl() do
      nil ->
        :none

      mod ->
        case safe_call(fn -> mod.authorize(agent_id, scope) end) do
          :ok -> :ok
          {:error, _} = error -> error
          other -> {:error, {:invalid_visible_reply_authorize_result, other}}
        end
    end
  end

  def authorize(_agent_id, _scope), do: :none

  @spec publish_delta(String.t(), String.t(), map(), String.t(), String.t() | nil) :: :ok
  def publish_delta(agent_id, session_id, scope, cumulative_text, raw_delta)
      when is_binary(cumulative_text) and (is_binary(raw_delta) or is_nil(raw_delta)) do
    if valid_terminal_scope?(scope) do
      if DraftSurface.put(agent_id, session_id, scope, cumulative_text) == :changed do
        SessionActivity.notify(agent_id, session_id)
      end
    else
      :ok
    end
  end

  @spec cancel(String.t(), String.t(), map()) :: :ok
  def cancel(agent_id, session_id, scope) when is_map(scope) do
    if valid_terminal_scope?(scope) do
      if DraftSurface.clear(agent_id, session_id, scope) == :changed do
        SessionActivity.notify(agent_id, session_id)
      end
    else
      :ok
    end
  end

  def cancel(_agent_id, _session_id, _scope), do: :ok

  defp impl, do: Application.get_env(:salix_agent, :visible_reply_mod)

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:visible_reply_port_error, error}}
  catch
    kind, reason -> {:error, {:visible_reply_port_error, {kind, reason}}}
  end

  defp valid_terminal_scope?(scope),
    do: SalixAgent.InternalSession.presentation_policy(:valid_terminal_scope?, scope)
end
