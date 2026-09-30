defmodule Salix.Bindings.EnvRuntimeProxy do
  @moduledoc false

  @behaviour SalixEnv.RuntimeProxy

  @impl true
  def handle(env_id, params, meta), do: SalixWeb.RuntimeProxy.handle(env_id, params, meta)
end
