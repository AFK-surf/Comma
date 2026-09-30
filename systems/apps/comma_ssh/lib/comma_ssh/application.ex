defmodule CommaSSH.Application do
  use Application

  def start(_type, _args) do
    children =
      [CommaSSH.Connections] ++
        if Application.get_env(:comma_ssh, :port), do: [CommaSSH.Listener], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: CommaSSH.Supervisor)
  end
end
