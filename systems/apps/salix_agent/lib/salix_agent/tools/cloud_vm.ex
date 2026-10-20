defmodule SalixAgent.Tools.CloudVM do
  @moduledoc """
  `cloud_vm.start`: the agent turns on its Group's Cloud VM itself, and sees
  it come up, before giving it work (`SalixAgent.CloudVM.start/3`).
  """

  alias SalixAgent.Tools.AsyncPolicy

  def defs do
    [
      {"cloud_vm.start",
       "Start the Workspace's Cloud VM and wait until its station is connected. Omit agent_id to start it for yourself, including as a Comma Router, or name a Worker of this Workspace. Answers each state it went through with seconds since the start.\n\nThe Cloud VM belongs to the Workspace. The Workspace's Cloud VM switch permits startup and Task placement there; a Cloud VM binding only makes it the Worker's default Task location. Nothing starts it otherwise: a Task with runs_on {\"kind\":\"cloud_vm\"} is refused while it is not running, and a message to it then fails. States: none, creating, archived, waking, ready, connected, failed, ...; a VM already connected answers at once. Starting takes from seconds to a few minutes.",
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

    case SalixAgent.CloudVM.start(
           ctx[:agent_id],
           worker_id,
           AsyncPolicy.exec_readiness_timeout_ms()
         ) do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, reason, steps} ->
        message = describe(reason)

        {:tool_failure,
         Jason.encode!(%{"code" => code(reason), "message" => message, "steps" => steps}),
         code(reason), "user_reportable", message, []}
    end
  end

  defp code(:cloud_vm_disabled), do: "cloud_vm_disabled"
  defp code(:worker_not_found), do: "agent_not_found"
  defp code({:runner_offline, _runner}), do: "runner_offline"
  defp code(:cloud_vm_failed), do: "cloud_vm_failed"
  defp code(:timeout), do: "cloud_vm_start_timeout"
  defp code(:not_configured), do: "cloud_vm_unavailable"
  defp code(_reason), do: "cloud_vm_start_failed"

  defp describe(:cloud_vm_disabled),
    do: "The Workspace's Cloud VM switch is off, so no Agent of it can start its Cloud VM."

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
