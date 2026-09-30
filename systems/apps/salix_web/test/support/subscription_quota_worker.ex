defmodule SalixWeb.TestSubscriptionQuotaWorker do
  @moduledoc false
  use GenServer

  def start_link(worker), do: GenServer.start_link(__MODULE__, worker)
  def init(worker), do: {:ok, worker}

  # Keep real credential normalization, but never send fixture credentials to
  # the provider when account creation reads subscription details.
  def handle_call({:start, id, data, reply_to} = request, _from, worker) do
    if Jason.decode!(data)["op"] == "/quota" do
      snapshot = %{"plan_type" => "pro", "windows" => []}

      send(
        reply_to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(snapshot))}}
      )

      send(reply_to, {:subscription, id, %{"type" => "done"}})
      {:reply, :ok, worker}
    else
      {:reply, GenServer.call(worker, request), worker}
    end
  end

  def handle_cast({kind, id, _caller}, worker) when kind in [:ack, :cancel] do
    GenServer.cast(worker, {kind, id, self()})
    {:noreply, worker}
  end
end
