defmodule SystemsObservability.Instrumentation do
  @moduledoc false

  require Logger

  def setup do
    # Instrumentation is attached exactly once by the release-owned
    # systems_observability application. Failures are diagnostic-only: tracing
    # must never prevent the business supervisor from starting.
    safe_setup(:bandit, fn -> SystemsObservability.BanditInstrumentation.setup() end)

    safe_setup(:phoenix, fn ->
      OpentelemetryPhoenix.setup(adapter: :bandit, liveview: false)
    end)

    :ok
  end

  defp safe_setup(_name, fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, :already_exists} ->
        :ok

      {:error, {:already_exists, _}} ->
        :ok

      _other ->
        setup_failed()
    end
  rescue
    _exception -> setup_failed()
  catch
    _kind, _reason -> setup_failed()
  end

  defp setup_failed do
    Logger.warning("systems_observability.instrumentation.setup_failed",
      error_class: "internal"
    )

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
