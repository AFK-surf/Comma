defmodule SalixVerifiedKernel.Provider do
  @moduledoc false

  def call(operation, payload) do
    case SalixVerifiedKernel.invoke(:provider, operation, payload) do
      {:ok, {:value, value}} ->
        value

      {:ok, {:raised, reason}} ->
        raise ArgumentError, "invalid provider input: #{inspect(reason)}"

      {:error, domain, code} ->
        raise "provider kernel failed: #{domain}/#{code}"
    end
  end

  def body(protocol, _cfg, {:encoded_provider_request, protocol, body}, _tools, _mode)
      when is_binary(body),
      do: body

  def body(protocol, cfg, messages, tools, mode) when is_list(messages) do
    call(:encoded_body, {protocol, Map.delete(cfg, :transport), messages, tools, mode})
  end

  def endpoint(protocol, cfg, mode),
    do: call(:endpoint, {protocol, Map.delete(cfg, :transport), mode})

  def stream(resident, operation, payload) do
    case SalixVerifiedKernel.invoke_provider_stream(resident, operation, payload) do
      {next, {:ok, {:value, value}}} -> {next, value}
      {_next, error} -> raise "provider stream kernel failed: #{inspect(error)}"
    end
  end
end
