defmodule SalixWeb.MeetingIngressSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :rest_for_one)
  end

  @doc false
  def children do
    [bandit_child()] ++ calendar_autojoin_children()
  end

  @doc false
  def calendar_autojoin_children do
    case Application.get_env(:salix_meet, :calendar_autojoin) do
      opts when is_list(opts) ->
        unless SalixMeet.RuntimeDriver.configured?() do
          raise "calendar autojoin requires a configured meeting runtime driver"
        end

        [
          %{
            id: SalixMeet.CalendarAutojoin,
            start: {__MODULE__, :start_calendar_autojoin, [opts]},
            restart: :permanent,
            type: :worker
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  def start_calendar_autojoin(opts, listener \\ SalixWeb.HTTPServer) do
    with pid when is_pid(pid) <- Process.whereis(listener),
         true <- Process.alive?(pid),
         {:ok, {_address, port}} when is_integer(port) and port > 0 <-
           ThousandIsland.listener_info(listener) do
      SalixMeet.CalendarAutojoin.start_link(opts)
    else
      _ -> {:error, :calendar_callback_endpoint_not_ready}
    end
  end

  defp bandit_child do
    {Bandit,
     plug: SalixWeb.Endpoint,
     port: SalixWeb.Application.port(),
     startup_log: false,
     http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false],
     thousand_island_options: [supervisor_options: [name: SalixWeb.HTTPServer]]}
  end
end
