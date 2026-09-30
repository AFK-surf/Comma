defmodule SalixAgent.Tools.DeviceConnection do
  @moduledoc "Router-owned Connector installation with consent on the target computer."

  def defs do
    [
      {"device.create_connector_install_command",
       "Create the direct Connector installation command for a target Mac or Linux computer. Give the command to the user to run there and confirm local consent. No SSH or Drive setup is required. Creates one device credential per call. Retain device_id and reuse this command after an uncertain result. Verify the returned file through Connector. Starts read-only in the background until reboot, without an OS startup service.",
       install_schema(), &__MODULE__.install/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]}
    ]
  end

  def install_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"name" => %{"type" => "string", "minLength" => 1, "maxLength" => 80}},
      "required" => ["name"]
    }
  end

  def install(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, install_schema()),
         {:ok, result} <-
           SalixAgent.EnvDispatch.create_device_install(ctx[:agent_id], args["name"]) do
      Jason.encode!(result)
    else
      {:error, reason} when is_binary(reason) ->
        failure("invalid_arguments", reason)

      {:error, :forbidden} ->
        failure("forbidden", "Only the workspace Router can prepare device setup.")

      {:error, :connector_release_unavailable} ->
        failure(
          "connector_release_unavailable",
          "Connector downloads are unavailable. No device credential was created."
        )

      _ ->
        failure(
          "connector_install_command_failed",
          "The server could not generate the Connector setup command."
        )
    end
  end

  defp failure(code, message) do
    {:tool_failure, Jason.encode!(%{"code" => code, "message" => message}), code,
     "user_reportable", message, []}
  end
end
