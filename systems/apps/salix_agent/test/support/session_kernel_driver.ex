defmodule SalixAgent.TestSupport.SessionKernelDriver do
  @moduledoc false
  # Configuration requests are synchronous. Clock requests remain visible to
  # tests that explicitly resume a chosen timestamp.
  def step(state, event), do: settle(SalixVerifiedKernel.Session.step(state, event))

  defp settle({:observe_config, :salix_agent, key, default, token}) do
    settle(
      SalixVerifiedKernel.Session.step(
        token,
        {:observed_config, Application.get_env(:salix_agent, key, default)}
      )
    )
  end

  defp settle(result), do: result
end
