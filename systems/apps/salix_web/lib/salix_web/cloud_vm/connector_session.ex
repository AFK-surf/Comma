defmodule SalixWeb.CloudVM.ConnectorSession do
  @moduledoc "Uses the existing Connector protocol owner over a managed transport."
  use GenServer, restart: :temporary

  alias SalixWeb.ConnectorSocket

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :transport)
    Process.monitor(parent)
    apply_result(ConnectorSocket.init(opts), %{transport: parent, protocol: nil}, :init)
  end

  @impl true
  def handle_info({:connector_frame, parent, frame}, %{transport: parent} = state) do
    ConnectorSocket.handle_in({frame, [opcode: :text]}, state.protocol)
    |> apply_result(state, :message)
  end

  def handle_info({:DOWN, _, :process, parent, _}, %{transport: parent} = state),
    do: {:stop, :normal, state}

  def handle_info(message, state) do
    ConnectorSocket.handle_info(message, state.protocol)
    |> apply_result(state, :message)
  end

  @impl true
  def terminate(reason, %{protocol: protocol}) when not is_nil(protocol),
    do: ConnectorSocket.terminate(reason, protocol)

  def terminate(_, _), do: :ok

  defp apply_result({:ok, protocol}, state, phase),
    do: reply(%{state | protocol: protocol}, phase)

  defp apply_result({:push, frames, protocol}, state, phase) do
    Enum.each(List.wrap(frames), fn {:text, frame} ->
      send(state.transport, {:connector_push, self(), frame})
    end)

    reply(%{state | protocol: protocol}, phase)
  end

  defp apply_result({:stop, reason, protocol}, state, :message),
    do: {:stop, reason, %{state | protocol: protocol}}

  defp apply_result({:stop, reason, _close, protocol}, state, :message),
    do: {:stop, reason, %{state | protocol: protocol}}

  defp apply_result({:stop, reason, _protocol}, _state, :init), do: {:stop, reason}

  defp reply(state, :init), do: {:ok, state}
  defp reply(state, :message), do: {:noreply, state}
end
