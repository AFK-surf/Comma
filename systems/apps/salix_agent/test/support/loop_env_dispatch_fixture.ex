defmodule SalixAgent.LoopEnvDispatchFixture do
  @moduledoc """
  Test-only `SalixAgent.EnvDispatch` stand-in for background Loop tests: every
  `env.exec` is reported to the process registered as `:loop_env_dispatch_test`
  and answered with a fixed successful result whose stdout echoes the command.
  Everything else behaves like `SalixAgent.EnvDispatch.None`.
  """

  @registered :loop_env_dispatch_test

  def register(pid \\ self()) do
    if Process.whereis(@registered), do: Process.unregister(@registered)
    Process.register(pid, @registered)
    :ok
  end

  def exec(agent_id, target, command, opts) do
    if pid = Process.whereis(@registered),
      do: send(pid, {:loop_env_exec, agent_id, target, command, opts})

    {:ok, %{"exit_code" => 0, "stdout" => "ran: " <> command, "stderr" => ""}}
  end

  def list_devices(_agent_id, _opts), do: {:error, :no_environment}
  def list_envs(_agent_id), do: {:error, :no_environment}
  def get_device(_agent_id, _device_id), do: {:error, :no_environment}
  def computer_use(_agent_id, _target, _action), do: {:error, :no_environment}
  def android(_agent_id, _target, _action), do: {:error, :no_environment}
  def process_list(_agent_id, _target), do: {:error, :no_environment}
  def process_write(_agent_id, _target, _name, _data, _opts), do: {:error, :no_environment}
  def process_tail(_agent_id, _target, _name, _opts), do: {:error, :no_environment}
  def read_stream(_agent_id, _target, _path), do: {:error, :no_environment}
  def write_stream(_agent_id, _target, _path, _stream), do: {:error, :no_environment}
end
