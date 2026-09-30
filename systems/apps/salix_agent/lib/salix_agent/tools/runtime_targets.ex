defmodule SalixAgent.Tools.RuntimeTargets do
  @moduledoc "Existing runtime target discovery handed off from Agent tools to the environment domain."
  @description "Discover a bounded page of existing runtime targets. kind=connected pages devices (at most 50 candidates); kind=compute requires provider=codex/pi/claude and pages the current product's Workloads. Pass an item's entire target unchanged to agent.create_worker.runtime or agent.rebind_runtime.target. Empty items with next_cursor are not exhaustion. This never creates, wakes, logs into or stops an environment."
  def defs,
    do: [
      {"env.runtime_targets", @description, schema(), &__MODULE__.call/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "read"]}
    ]

  def schema,
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["connected", "compute"]},
        "provider" => %{"type" => "string", "enum" => ~w(codex pi claude kimi)},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
        "cursor" => %{"type" => ["string", "null"]}
      },
      "required" => ["kind"]
    }

  def call(args, ctx) do
    result =
      with true <-
             is_map(args) and Enum.all?(Map.keys(args), &(&1 in ~w(kind provider limit cursor))),
           {:ok, %{"role" => "router"} = caller} <- SalixAgent.Control.get_record(ctx.agent_id),
           true <- SalixAgent.Control.visible?(caller),
           true <- args["kind"] in ["connected", "compute"],
           limit = Map.get(args, "limit", 20),
           true <- is_integer(limit) and limit in 1..50,
           true <- is_nil(args["provider"]) or args["provider"] in ~w(codex pi claude kimi),
           {:ok, page} <-
             SalixAgent.AgentManagement.Ports.page_targets(caller, Map.put(args, "limit", limit)) do
        {:ok, page}
      else
        false -> {:error, :invalid_arguments}
        error -> error
      end

    case result do
      {:ok, page} ->
        Jason.encode!(page)

      {:error, reason} ->
        issue = SalixAgent.AgentManagement.Error.public(reason)

        {:tool_failure, Jason.encode!(issue), issue["code"], "user_reportable", issue["message"],
         []}

      _ ->
        raise "Runtime target discovery is unavailable."
    end
  end
end
