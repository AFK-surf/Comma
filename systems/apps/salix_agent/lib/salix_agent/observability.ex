defmodule SalixAgent.Observability do
  @moduledoc """
  Runtime agent observability behaviour.

  The default implementation is no-op. Production can configure
  `:salix_agent, :agent_observability_mod` to a sink adapter; emitters must
  never let telemetry failures affect the agent loop.
  """

  @callback tool_call(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback agent_run(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback inbox_dead_letter(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback round_phase(map()) :: :ok | {:ok, map()} | {:error, term()}
  @callback llm_attempt(map()) :: :ok | {:ok, map()} | {:error, term()}

  # inbox_dead_letter and round_phase are optional: the configured production
  # sink (BillingCore.AgentObservability) lives outside this app and older
  # sinks (and test fakes) may not implement them. Emitters guard on
  # function_exported? so a missing sink drops the event instead of raising.
  @optional_callbacks inbox_dead_letter: 1, round_phase: 1, llm_attempt: 1

  require Logger

  def tool_call(fact), do: safe_call(:tool_call, fact)
  def agent_run(fact), do: safe_call(:agent_run, fact)

  def inbox_dead_letter(fact), do: optional_call(:inbox_dead_letter, fact)

  @doc "Round phase fact (see `SalixAgent.PhaseTelemetry`); dropped by sinks without the callback."
  def round_phase(fact), do: optional_call(:round_phase, fact)

  @doc "Failed provider attempt fact (see `SalixAgent.AttemptTelemetry`); dropped by sinks without the callback."
  def llm_attempt(fact), do: optional_call(:llm_attempt, fact)

  defp optional_call(function, fact) do
    if function_exported?(impl(), function, 1) do
      safe_call(function, fact)
    else
      :ok
    end
  end

  defp impl, do: Application.get_env(:salix_agent, :agent_observability_mod, __MODULE__.Noop)

  defp safe_call(function, fact) do
    apply(impl(), function, [fact])
  rescue
    exception ->
      Logger.warning("agent observability #{function} failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("agent observability #{function} exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def inbox_dead_letter(_fact), do: :ok

    @impl true
    def round_phase(_fact), do: :ok

    @impl true
    def llm_attempt(_fact), do: :ok
  end
end
