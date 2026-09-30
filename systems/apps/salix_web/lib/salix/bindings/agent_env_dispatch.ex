defmodule Salix.Bindings.AgentEnvDispatch do
  @moduledoc false

  @behaviour SalixAgent.EnvDispatch

  @impl true
  def create_device_install(agent_id, name),
    do: SalixWeb.EnvDispatch.create_device_install(agent_id, name)

  @impl true
  def list_devices(agent_id, opts), do: SalixWeb.EnvDispatch.list_devices(agent_id, opts)

  @impl true
  def list_envs(agent_id), do: SalixWeb.EnvDispatch.list_envs(agent_id)

  @impl true
  def get_device(agent_id, device_id), do: SalixWeb.EnvDispatch.get_device(agent_id, device_id)

  @impl true
  def exec(agent_id, target, cmd, opts),
    do: SalixWeb.EnvDispatch.exec(agent_id, target, cmd, opts)

  @impl true
  def request(agent_id, target, method, params),
    do: SalixWeb.EnvDispatch.request(agent_id, target, method, params)

  @impl true
  def computer_use(agent_id, target, action),
    do: SalixWeb.EnvDispatch.computer_use(agent_id, target, action)

  @impl true
  def android(agent_id, target, action),
    do: SalixWeb.EnvDispatch.android(agent_id, target, action)

  @impl true
  def process_list(agent_id, target),
    do: SalixWeb.EnvDispatch.process_list(agent_id, target)

  @impl true
  def process_write(agent_id, target, process_name, data, opts),
    do: SalixWeb.EnvDispatch.process_write(agent_id, target, process_name, data, opts)

  @impl true
  def process_tail(agent_id, target, process_name, opts),
    do: SalixWeb.EnvDispatch.process_tail(agent_id, target, process_name, opts)

  @impl true
  def read_stream(agent_id, target, path),
    do: SalixWeb.EnvDispatch.read_stream(agent_id, target, path)

  @impl true
  def write_stream(agent_id, target, path, stream),
    do: SalixWeb.EnvDispatch.write_stream(agent_id, target, path, stream)
end
