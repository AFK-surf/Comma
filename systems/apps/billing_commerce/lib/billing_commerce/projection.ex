defmodule BillingCommerce.Projection do
  @moduledoc "Best-effort billing source lifecycle projection."

  @spec emit(map()) :: :ok
  def emit(attrs) when is_map(attrs) do
    sink =
      attrs[:typed_sink] || Application.get_env(:billing_commerce, :billing_source_typed_sink)

    sink =
      case sink do
        nil -> Application.get_env(:salix_analytics, :typed_sink, SalixAnalytics.TypedSinkWorker)
        false -> nil
        other -> other
      end

    if sink do
      row = SalixAnalytics.BillingSourceEvent.build(attrs)
      _ = sink.insert([row])
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
