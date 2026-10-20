defmodule SalixAgent.TailnetTestPeer do
  require SystemsRuntime.Proc

  @moduledoc """
  A tailnet for tests (`systems/tailnet-gateway` `cmd/tailnet-testpeer`): a
  local relay, a coordination server that requires login approval, and one
  device, `nas`, that echoes on port 7 and forwards port 22 to a target.

  `start!/1` also points this node's tailnet gateway at that coordination
  server for the rest of the test.

  Waits have no deadline of their own: the CI job timeout stops a test whose
  event never comes.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias SalixAgent.Tailnet
  alias SalixAgent.Tailnet.{Gateway, Owner}

  @doc "Start the tailnet; `target` receives the device's port 22."
  def start!(target \\ nil) do
    exe = Path.join(:code.priv_dir(:salix_agent), "tailnet_testpeer")
    source = Path.expand("../../../../tailnet-gateway", __DIR__)
    {_, 0} = System.cmd("make", ["-s", "-C", source, "testpeer", "TESTPEER=" <> exe])

    args = if target, do: ["--target", target], else: []
    port = Port.open({:spawn_executable, exe}, [:binary, {:line, 65_536}, args: args])

    control_url =
      SystemsRuntime.Proc.receive do
        {^port, {:data, {:eol, line}}} -> Jason.decode!(line)["control_url"]
      end

    use_gateway!(control_url)
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{port: port, control_url: control_url}
  end

  @doc "Approve a node's login link, as a tailnet admin does."
  def approve!(%{port: port}, url) do
    true = Port.command(port, "approve " <> url <> "\n")

    SystemsRuntime.Proc.receive do
      {^port, {:data, {:eol, line}}} -> assert %{"ok" => true} = Jason.decode!(line)
    end
  end

  @doc "Wait until the Group's tailnet reaches `state`; returns the status."
  def await_state!(group_id, state) do
    await!(group_id, fn ->
      {:ok, status} = Tailnet.status(group_id)
      if status["state"] == state, do: status
    end)
  end

  @doc """
  Wait until `check` returns a value other than nil or false, reading again
  after each change to the Group's node record.
  """
  def await!(group_id, check) do
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix, :tailnet, :node_record],
        &__MODULE__.forward/4,
        {SystemsRuntime.Proc.self(), group_id}
      )

    try do
      await_change(group_id, check)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp await_change(group_id, check) do
    case check.() do
      result when result not in [nil, false] ->
        result

      _ ->
        SystemsRuntime.Proc.receive do
          {:tailnet_node_record, ^group_id} -> await_change(group_id, check)
        end
    end
  end

  @doc false
  def forward(_event, _measurements, %{group_id: group_id}, {pid, group_id}),
    do: SystemsRuntime.Proc.send(pid, {:tailnet_node_record, group_id})

  def forward(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Replace the test's gateway with one started with `opts`. Owners stay, as
  when a gateway restarts under them.
  """
  def restart_gateway!(opts) do
    :ok = stop_supervised(Gateway)
    start_supervised!({Gateway, opts})
  end

  # The application's gateway uses Tailscale's coordination server; replace
  # it with one that uses the test server, and restore it afterwards.
  defp use_gateway!(control_url) do
    Owner.drain()
    :ok = Supervisor.terminate_child(SalixAgent.Supervisor, Gateway)
    start_supervised!({Gateway, control_url: control_url})

    on_exit(fn ->
      Owner.drain()
      Supervisor.restart_child(SalixAgent.Supervisor, Gateway)
    end)
  end
end
