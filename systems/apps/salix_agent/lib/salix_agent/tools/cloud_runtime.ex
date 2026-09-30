defmodule SalixAgent.Tools.CloudRuntime do
  @moduledoc "Router preparation of an external runtime on the Group's enabled Cloud VM."

  def defs do
    [
      {"env.ensure_runtime",
       "Prepare Codex or Claude Code on this Group's enabled Cloudflare cloud VM. Reuse request_id to inspect progress or recover an uncertain result. At most 16 targets exist per VM. This installs software but does not create a Worker. The server automatically selects an enabled, compatible account from the tenant pool. Healthy bindings remain selected. Automatically selected accounts with known exhausted provider-wide quota can be replaced while the runtime is idle; failed Tasks are not replayed automatically. Manual bindings remain selected. runtime_idle means deliberate idle suspension, not a VM crash. Reusing this tool wakes the runtime. Manual binding or unbinding disables automatic selection for that target. Wait for preparation to finish. A missing target means discovery has not finished, not that the account pool is empty. The managed runtime and its isolated credentials are not the preinstalled CLI on PATH. Do not launch Codex or test account binding through env.exec or another shell tool, including managed binaries or wrappers invoked by absolute path. Account-pool authentication belongs to the Connector-managed runtime process, not a separate CLI invocation; CLI login status or authentication errors do not establish managed runtime authentication failure. Once ready, pass target unchanged to agent.create_worker.runtime. Execute and validate Codex through a Task assigned to that Worker; do not initiate a separate CLI login as a workaround. If no usable account exists, ask an authorized administrator to add or repair one. An administrator must also repair failed bindings or explicitly bind a manually unbound target. Do not supply credentials or account IDs through this tool. retry=true explicitly retries a failed installation on the same target.",
       schema(), &__MODULE__.call/2, SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       [roles: ["router"], safety: "write"]}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "provider" => %{"type" => "string", "enum" => ~w(codex claude)},
        "request_id" => %{"type" => "string", "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"},
        "retry" => %{"type" => "boolean"}
      },
      "required" => ~w(provider request_id)
    }
  end

  def call(args, ctx) do
    with true <-
           is_map(args) and Enum.all?(Map.keys(args), &(&1 in ~w(provider request_id retry))),
         true <- is_boolean(Map.get(args, "retry", false)),
         {:ok, %{"role" => "router"} = caller} <- SalixAgent.Control.get_record(ctx.agent_id),
         true <- SalixAgent.Control.visible?(caller),
         {:ok, result} <- SalixAgent.CloudVM.ensure_runtime(caller, args) do
      Jason.encode!(result)
    else
      {:error, reason}
      when reason in [
             :cloud_vm_runtime_capacity,
             :runtime_request_conflict,
             :cloud_vm_runtime_invalid_request
           ] ->
        failure(reason)

      _ ->
        failure(:cloud_runtime_unavailable)
    end
  end

  defp failure(reason) do
    message =
      case reason do
        :cloud_vm_runtime_capacity ->
          "This VM already has 16 runtime targets. Reuse an existing request ID."

        :runtime_request_conflict ->
          "This request ID already selects another provider."

        :cloud_vm_runtime_invalid_request ->
          "Use a valid request ID and enable a Cloudflare VM before preparation."

        _ ->
          "Cloud runtime preparation is unavailable. Check the VM configuration."
      end

    code = Atom.to_string(reason)

    {:tool_failure, Jason.encode!(%{"code" => code, "message" => message}), code,
     "user_reportable", message, []}
  end
end
