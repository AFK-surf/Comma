defmodule SalixEnv.VM.Attachment do
  @moduledoc """
  Attachment contract for binding a provider VM transport to SalixEnv.Bridge.

  Implementations own the provider-specific socket or process transport, but
  they must register the same durable `env_id` with `SalixEnv.Bridge` so the
  EnvMessage API remains provider-neutral.
  """

  @callback ensure(keyword()) :: {:ok, pid()} | {:error, term()}
  @callback whereis(String.t()) :: pid() | nil
  @callback stop(String.t()) :: :ok
end
