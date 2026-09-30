defmodule SalixIM.Diagnostics do
  @moduledoc false

  require Logger

  @doc "Emit one sanitized IM diagnostic map to the configured sink."
  @spec emit(map()) :: :ok
  def emit(diagnostic) when is_map(diagnostic) do
    case Application.get_env(:salix_im, :diagnostic_sink) do
      nil ->
        :ok

      sink when is_function(sink, 1) ->
        safe_call(fn -> sink.(diagnostic) end)

      {module, function} when is_atom(module) and is_atom(function) ->
        safe_call(fn -> apply(module, function, [diagnostic]) end)

      module when is_atom(module) ->
        safe_call(fn -> module.record(diagnostic) end)

      other ->
        Logger.warning("salix im diagnostic sink ignored invalid config: #{inspect(other)}")
        :ok
    end
  end

  def emit(_diagnostic), do: :ok

  defp safe_call(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("salix im diagnostic sink failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("salix im diagnostic sink failed: #{inspect({kind, reason})}")
      :ok
  end
end
