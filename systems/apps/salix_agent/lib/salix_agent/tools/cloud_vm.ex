defmodule SalixAgent.Tools.CloudVM do
  @moduledoc """
  `cloud_vm.start`: the agent turns on its Group's Cloud VM itself, and sees
  it come up, before giving it work (`SalixAgent.CloudVM.start/3`).

  Where the Cloud VM is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`)
  the tool is not offered (`SalixAgent.ToolDisclosure`), and a call that
  reaches it answers `cloud_vm_retired`.
  """

  alias SalixAgent.Tools.AsyncPolicy

  def defs do
    [
      {"cloud_vm.start",
       "Start the Workspace's Cloud VM and wait until its station is connected. Omit agent_id to start it for yourself, including as a Comma Router, or name a Worker of this Workspace. Answers each state it went through with seconds since the start.\n\nThe Cloud VM belongs to the Workspace. The Workspace's Cloud VM switch permits startup and Task placement there; a Cloud VM binding only makes it the Worker's default Task location. A Task with runs_on {\"kind\":\"cloud_vm\"} wakes it by itself and is given to it once it is up, so start it only to run commands on it yourself; a message to it while it is not running fails. States: none, creating, archived, waking, ready, connected, failed, ...; a VM already connected answers at once. Starting takes from seconds to a few minutes.",
       schema(), &__MODULE__.start/2, AsyncPolicy.normal_tool_auto_wait_seconds(),
       [safety: "write"]}
    ]
  end

  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" =>
            "Optional Worker in this Workspace to start the Cloud VM for. Omit it to start it for yourself."
        }
      },
      "required" => [],
      "additionalProperties" => false
    }

  def start(args, ctx) do
    worker_id =
      case args["agent_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    result =
      if SalixAgent.Sandboxes.cloud_vm_retired?(group_id(ctx)),
        do: {:error, :cloud_vm_retired, []},
        else:
          SalixAgent.CloudVM.start(
            ctx[:agent_id],
            worker_id,
            AsyncPolicy.exec_readiness_timeout_ms()
          )

    case result do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, reason, steps} ->
        message = describe(reason)

        {:tool_failure,
         Jason.encode!(%{"code" => code(reason), "message" => message, "steps" => steps}),
         code(reason), "user_reportable", message, []}
    end
  end

  # The Group of the agent that calls: its Cloud VM is the one started.
  defp group_id(ctx) do
    case ctx[:agent_id] do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        SalixStore.Ids.group_id_from_agent!(agent_id)

      _none ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp code(:cloud_vm_retired), do: "cloud_vm_retired"
  defp code(:cloud_vm_disabled), do: "cloud_vm_disabled"
  defp code(:worker_not_found), do: "agent_not_found"
  defp code({:runner_offline, _runner}), do: "runner_offline"
  defp code(:cloud_vm_failed), do: "cloud_vm_failed"
  defp code(:timeout), do: "cloud_vm_start_timeout"
  defp code(:not_configured), do: "cloud_vm_unavailable"
  defp code(_reason), do: "cloud_vm_start_failed"

  defp describe(:cloud_vm_retired),
    do:
      ~s(The Cloud VM is retired here: sandboxes have taken its place. Run commands in a sandbox Task: im_api.internal.task.create with runs_on {"kind":"sandbox"} and model {"kind":"runtime","provider":"codex"|"claude"}.)

  defp describe(:cloud_vm_disabled),
    do:
      "The Workspace has no Cloud VM available now: none is set up for it, or its setup was not read. No Agent of it can start one."

  defp describe(:worker_not_found), do: "No Worker with that agent_id is in this Workspace."

  defp describe({:runner_offline, runner}),
    do:
      "The Cloud VM was not created: the Agent VMM Host on this Project's Runner#{runner_label(runner)} is not connected, and the Project's Cloud VM runs on it. Bring that Mac online and check that its Host is running, or unbind the Runner from the Project, then start the Cloud VM again."

  defp describe(:cloud_vm_failed), do: "The Cloud VM failed to start."
  defp describe(:timeout), do: "The Cloud VM did not come up in time; it may still be starting."
  defp describe(:not_configured), do: "Cloud VMs are not available in this deployment."
  defp describe(%{"message" => message}) when is_binary(message), do: message
  defp describe(reason), do: "The Cloud VM could not be started: #{inspect(reason)}"

  defp runner_label(%{"name" => name}) when is_binary(name) and name != "",
    do: " " <> inspect(name)

  defp runner_label(_runner), do: ""
end
