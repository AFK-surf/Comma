defmodule SalixAgent.LoopEnvDispatchFixture do
  @moduledoc """
  Test-only `SalixAgent.EnvDispatch` stand-in for background Loop tests: every
  `env.exec` is reported to the process registered as `:loop_env_dispatch_test`
  and answered with a fixed successful result whose stdout echoes the command.
  Everything else behaves like `SalixAgent.EnvDispatch.None`.
  """

  @registered :loop_env_dispatch_test
  @stdout_key {__MODULE__, :stdout}

  def register(pid \\ SystemsRuntime.Proc.self()) do
    if SystemsRuntime.Proc.whereis(@registered), do: Process.unregister(@registered)
    Process.register(pid, @registered)
    SystemsRuntime.PersistentTerm.put(@stdout_key, %{})
    :ok
  end

  @doc "Answer `command` with `stdout` instead of the echo, until the next `register/1`."
  def stdout_for(command, stdout) when is_binary(command) and is_binary(stdout) do
    SystemsRuntime.PersistentTerm.put(
      @stdout_key,
      Map.put(SystemsRuntime.PersistentTerm.get(@stdout_key, %{}), command, stdout)
    )

    :ok
  end

  def exec(agent_id, target, command, opts) do
    if pid = SystemsRuntime.Proc.whereis(@registered),
      do: SystemsRuntime.Proc.send(pid, {:loop_env_exec, agent_id, target, command, opts})

    stdout =
      Map.get(SystemsRuntime.PersistentTerm.get(@stdout_key, %{}), command, "ran: " <> command)

    {:ok, %{"exit_code" => 0, "stdout" => stdout, "stderr" => ""}}
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
