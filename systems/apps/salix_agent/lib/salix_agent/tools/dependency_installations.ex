defmodule SalixAgent.Tools.DependencyInstallations do
  @moduledoc "Agent declarations for rebuildable packages on its connected Group VM."

  def defs do
    [
      {"env.dependency_installations",
       "List, declare, or remove dependency installation directories on this Group VM. Declarations distinguish repository packages from manually installed tools; they do not decide which files an archive omits. After a restore, supported installations run in the background. Use list for the current path and elapsed time; cancel stops that installer and leaves normal shell access available. A directory deleted before the next archive is removed from declarations. Use action=start to retry a failed installation or action=remove to stop future automatic installation for one path.",
       schema(), &__MODULE__.call/2, SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()}
    ]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(device_id environment action),
      "properties" => %{
        "device_id" => %{"type" => "string"},
        "environment" => %{"type" => "string"},
        "action" => %{
          "type" => "string",
          "enum" => ~w(list declare remove start cancel)
        },
        "path" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => ~w(tool repository)},
        "manager" => %{
          "type" => "string",
          "enum" => ~w(npm pnpm yarn bun pip uv manual)
        },
        "working_directory" => %{"type" => "string"},
        "packages" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "maxItems" => 32
        }
      }
    }
  end

  def call(args, ctx) do
    target = %{
      device_id: Map.fetch!(args, "device_id"),
      environment_id: Map.fetch!(args, "environment")
    }

    params = Map.drop(args, ["device_id", "environment"])

    case SalixAgent.EnvDispatch.request(
           ctx.agent_id,
           target,
           "dependency_installations",
           params
         ) do
      {:ok, result} -> Jason.encode!(result)
      {:error, reason} -> raise "dependency declarations unavailable: #{inspect(reason)}"
    end
  end
end
