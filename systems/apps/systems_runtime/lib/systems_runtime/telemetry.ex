defmodule SystemsRuntime.Telemetry do
  @moduledoc "`:telemetry`: each function is the `:telemetry` function of the same name."

  def attach(id, event, function, config), do: attach_many(id, [event], function, config)

  def attach_many(id, events, function, config) when is_function(function, 4),
    do: :telemetry.attach_many(id, events, function, config)

  def detach(id), do: :telemetry.detach(id)

  def list_handlers(prefix), do: :telemetry.list_handlers(prefix)

  def execute(event, measurements, metadata) when is_number(measurements),
    do: execute(event, %{value: measurements}, metadata)

  def execute(event, measurements, metadata) when is_map(measurements) and is_map(metadata),
    do: :telemetry.execute(event, measurements, metadata)
end
