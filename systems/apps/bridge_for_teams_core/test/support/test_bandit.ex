defmodule BridgeForTeams.TestBandit do
  @moduledoc false

  def start_unlinked!(options) do
    {:ok, pid} = Bandit.start_link(kernel_assigned_port(options))
    SystemsRuntime.Proc.unlink(pid)
    endpoint(pid)
  end

  def start_supervised!(options) do
    {:ok, pid} =
      ExUnit.Callbacks.start_supervised(
        {Bandit, kernel_assigned_port(options)},
        id: {__MODULE__, SystemsRuntime.Proc.make_ref()}
      )

    endpoint(pid)
  end

  defp kernel_assigned_port(options), do: Keyword.put(options, :port, 0)

  defp endpoint(pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, port: port, url: "http://127.0.0.1:#{port}"}
  end
end
