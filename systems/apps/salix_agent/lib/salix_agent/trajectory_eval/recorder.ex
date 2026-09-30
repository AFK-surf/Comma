defmodule SalixAgent.TrajectoryEval.Recorder do
  @moduledoc """
  Analytics emission seam for trajectory eval results.

  Mirrors the `SalixAgent.LLMMetering` pattern: production wires
  `:salix_agent, :trajectory_eval_recorder_mod` to an implementation living
  next to the analytics pipeline (`SalixAnalytics.TrajectoryEvalRecorder`);
  the default is a no-op so the runtime has no analytics dependency. Failures
  never propagate — eval reporting must not break anything.
  """

  @callback record(map()) :: :ok | {:ok, term()} | {:error, term()}

  def record(fact) when is_map(fact), do: safe_call(:record, fact)

  defp impl,
    do: Application.get_env(:salix_agent, :trajectory_eval_recorder_mod, __MODULE__.Noop)

  defp safe_call(function, fact) do
    apply(impl(), function, [fact])
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.TrajectoryEval.Recorder

    @impl true
    def record(_fact), do: :ok
  end
end
