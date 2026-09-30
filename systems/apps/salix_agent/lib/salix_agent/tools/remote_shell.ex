defmodule SalixAgent.Tools.RemoteShell do
  @moduledoc "Temporary shell access, using the current group's managed gateway."

  def defs do
    [
      {"env.remote_shell",
       "Temporary shell on a consenting user's computer; not a sandbox. prepare returns one shell script to give the user (Python 3, curl, macOS/glibc Linux). They run it and explicitly confirm yes. The script automatically submits public registration data. Retain request from prepare, then call register with that request to wait up to timeout_seconds (default 120). If status=waiting, keep waiting on the same request until expiry without repeated user messages. No copied output or startup reply is needed. register enrolls only that temporary space and returns a session-bound target. revoke can also cancel a pending request. exec runs a command via an SSH PTY, without a Comma-side synch daemon; output is terminal text. revoke removes delegation but cannot undo effects or guarantee termination of running commands: the user's Ctrl-C and device deadline stop access. If the workspace CP URL, org, or network changes, old targets are invalid, not revoked. Clean up the original delegation at its original location or ask the user to stop the helper. Never claim a dropped/timed-out connection means success, or replay a command automatically. Never put CP credentials in the script.",
       schema(), &__MODULE__.call/2, SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [safety: "write"]}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(prepare register exec revoke)},
        "seconds" => %{"type" => "integer", "minimum" => 30, "maximum" => 3600},
        "request" => %{"type" => "string", "maxLength" => 4096},
        "device_key" => %{"type" => "string"},
        "expires_at" => %{"type" => "integer"},
        "target" => %{"type" => "string"},
        "command" => %{"type" => "string"},
        "timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 120}
      },
      "required" => ["action"]
    }
  end

  def call(args, ctx) do
    result =
      with {:ok, %{"group_id" => group} = caller} <-
             SalixAgent.Control.get_record(ctx.agent_id),
           true <- SalixAgent.Control.visible?(caller),
           session when is_binary(session) and session != "" <- ctx[:session_id],
           true <- is_binary(group) and group != "",
           mod when is_atom(mod) and not is_nil(mod) <-
             Application.get_env(:salix_agent, :remote_shell_mod) do
        mod.call(group, {ctx.agent_id, session}, args)
      else
        _ -> {:error, :remote_shell_unavailable}
      end

    case result do
      {:ok, value} ->
        Jason.encode!(value)

      {:error, reason} when is_atom(reason) ->
        {:tool_failure, Jason.encode!(%{error: reason}), "remote_shell", "user_reportable",
         "Temporary shell failed: #{reason}. Do not automatically replay a command.", []}

      _ ->
        raise "Temporary shell is unavailable."
    end
  end
end
