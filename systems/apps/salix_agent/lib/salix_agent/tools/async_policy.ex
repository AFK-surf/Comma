defmodule SalixAgent.Tools.AsyncPolicy do
  @moduledoc false

  @normal_tool_auto_wait_seconds 20
  @user_interaction_tool_auto_wait_seconds 120

  @wait_for_default_seconds 300
  @wait_for_max_seconds 1_800

  @wait_for_activation_cap 20

  # One readiness budget for the tool deadline and the Group VM waiter.
  def exec_readiness_timeout_ms do
    Application.get_env(:salix_agent, :cloud_vm_exec_readiness_timeout_ms, 300_000)
    |> max(0)
    |> min(300_000)
  end

  def normal_tool_auto_wait_seconds, do: @normal_tool_auto_wait_seconds
  def user_interaction_tool_auto_wait_seconds, do: @user_interaction_tool_auto_wait_seconds
  def wait_for_default_seconds, do: @wait_for_default_seconds
  def wait_for_max_seconds, do: @wait_for_max_seconds

  # Circuit breaker for self-wake polling loops: `wait_for` fails once this
  # many consecutive wait timeouts have woken the session with no new external
  # input in between. Configurable; 0 disables the budget.
  def wait_for_activation_cap,
    do: Application.get_env(:salix_agent, :wait_for_activation_cap, @wait_for_activation_cap)
end
