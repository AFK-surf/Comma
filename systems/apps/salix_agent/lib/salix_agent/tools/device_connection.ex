defmodule SalixAgent.Tools.DeviceConnection do
  @moduledoc "Router-owned station installation for a member's target computer."

  def defs do
    [
      {"device.create_station_install_command",
       "Create the station enrollment command for a target Mac or Linux computer of the Workspace member who asked. Give the command to the user to run there.\n\nNo SSH or Drive setup is required. The command works once and expires after one hour. After enrollment, use station.list to find the station and its device_id.",
       install_schema(), &__MODULE__.install/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]},
      {"device.ask_local_account",
       "Ask a computer's owner, with a question card the server writes in this conversation, whether to run this workspace's runtime on that computer's own signed-in login. Use it when device.get shows the runtime signed in on the computer but its capabilities.task_models lists no model for it. Then end the turn blocked; the answer arrives as a new message.",
       ask_schema(), &__MODULE__.ask_local_account/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]},
      {"device.use_local_account",
       "On the turn that delivers the computer owner's yes to the card of device.ask_local_account, with that answer as ifc.request: run the runtime for this workspace on that computer's own login, with the same device_id and runtime the card asked about. Then create the Task on that computer. Anything else is refused and nothing changes.",
       local_account_schema(), &__MODULE__.use_local_account/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]}
    ]
  end

  def ask_schema,
    do:
      put_in(local_account_schema(), ["properties", "locale"], %{
        "type" => "string",
        "enum" => ["en", "zh-CN"]
      })

  def local_account_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "device_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
        "runtime" => %{"type" => "string", "enum" => ["claude", "codex"]}
      },
      "required" => ["device_id", "runtime"]
    }
  end

  def ask_local_account(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, ask_schema()),
         {:ok, card} <-
           SalixAgent.EnvDispatch.local_account_card(
             ctx[:agent_id],
             args["device_id"],
             args["runtime"],
             args["locale"] || "en",
             Map.take(ctx, [:tenant_id, :group_id, :trusted_origin])
           ) do
      SalixAgent.Tools.ImRouter.server_send(
        ctx,
        %{
          "conversation_id" => card.conversation_id,
          "request_id" => "local-account:" <> to_string(ctx[:tool_call_id] || args["device_id"]),
          "content" => card.content
        },
        %{local_account_binding: card.binding}
      )
    else
      error -> local_account_failure(error)
    end
  end

  def use_local_account(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, local_account_schema()),
         {:ok, result} <-
           SalixAgent.EnvDispatch.use_local_account(
             ctx[:agent_id],
             args["device_id"],
             args["runtime"],
             Map.take(ctx, [:tenant_id, :group_id, :trusted_origin])
           ) do
      result
      |> Map.put(
        "next",
        "Create the Task on this computer now: runs_on {\"kind\":\"station\",\"device_id\":#{Jason.encode!(args["device_id"])}} and model {\"kind\":\"runtime\",\"provider\":#{Jason.encode!(args["runtime"])}}."
      )
      |> Jason.encode!()
    else
      error -> local_account_failure(error)
    end
  end

  defp local_account_failure(error) do
    case error do
      {:error, reason} when is_binary(reason) ->
        failure("invalid_arguments", reason)

      {:error, :confirmation_required} ->
        failure(
          "confirmation_required",
          "Nothing changed. This needs the computer owner's yes, on this turn, to the card of device.ask_local_account for this same computer and runtime. Otherwise do the work with a Task inside Comma that drives the computer."
        )

      {:error, :not_owner} ->
        failure(
          "not_owner",
          "Nothing changed. Only the computer's owner can choose its own login for this workspace. Do the work with a Task inside Comma that drives the computer instead."
        )

      {:error, :station_outdated} ->
        failure(
          "station_outdated",
          "Nothing changed. That computer's Comma app is too old to take this choice from a conversation. Ask its owner to update the app or choose the account in its device settings, or do the work with a Task inside Comma that drives the computer."
        )

      {:error, :device_offline} ->
        failure("device_offline", "Nothing changed. That computer is not connected now.")

      {:error, :device_not_found} ->
        failure("device_not_found", "Nothing changed. That computer is not in this workspace.")

      {:error, {:remote_error, message}} when is_binary(message) ->
        failure("account_source_refused", "The computer refused: " <> message)

      _ ->
        failure("account_source_failed", "The computer's account choice was not confirmed.")
    end
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
           SalixAgent.EnvDispatch.create_device_install(
             ctx[:agent_id],
             args["name"],
             Map.take(ctx, [:tenant_id, :group_id, :trusted_origin])
           ) do
      Jason.encode!(result)
    else
      {:error, reason} when is_binary(reason) ->
        failure("invalid_arguments", reason)

      {:error, :forbidden} ->
        failure("forbidden", "Only the workspace Router can prepare device setup.")

      {:error, :requester_required} ->
        failure(
          "requester_required",
          "Station setup needs the Workspace member who asked, and that member must not be a read-only member."
        )

      {:error, :station_install_unavailable} ->
        failure(
          "station_install_unavailable",
          "Station setup is unavailable here. The computer joins through the Comma desktop app instead."
        )

      _ ->
        failure(
          "station_install_command_failed",
          "The server could not generate the station setup command."
        )
    end
  end

  defp failure(code, message) do
    {:tool_failure, Jason.encode!(%{"code" => code, "message" => message}), code,
     "user_reportable", message, []}
  end
end
