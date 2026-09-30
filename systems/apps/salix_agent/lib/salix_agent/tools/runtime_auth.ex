defmodule SalixAgent.Tools.RuntimeAuth do
  @moduledoc """
  Router-facing, credential-free control for one exact external-worker runtime.

  Status reads the current bounded projection. Mutating actions create one
  existing capability request for a human administrator; the Router never owns
  an administrator identity and therefore cannot start, verify, or cancel a
  target attempt itself.
  """

  alias SalixAgent.{CapabilityRequestStore, Control, Waits}
  alias SalixAgent.Tools.AsyncPolicy

  @wait AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @request_ttl_seconds 15 * 60
  @router_opts [roles: ["router"], safety: "write"]

  def defs do
    [
      {"runtime.auth",
       "Read authentication status for one exact Compute worker, or request an administrator to start, verify, or cancel authentication. This tool never accepts credentials. For a pending request, show management_url through the current visible reply path and wait for its completion.",
       schema(), &__MODULE__.call/2, @wait, @router_opts}
    ]
  end

  def call(args, ctx) when is_map(args) and is_map(ctx) do
    args = stringify(args)
    action = args["action"]

    with :ok <- validate_shape(action, args),
         {:ok, caller} <- caller(ctx),
         {:ok, worker, target} <- exact_worker(caller, args["target"]),
         {:ok, status} <- status(worker, target, caller, ctx) do
      case action do
        "status" -> Jason.encode!(project_status(status, target))
        _ -> request_human(action, args, status, caller, worker, target, ctx)
      end
    else
      {:error, reason} -> raise "runtime.auth failed: #{format_reason(reason)}"
    end
  end

  def call(_args, _ctx), do: raise("runtime.auth requires an object")

  @doc false
  def validate_completion(%{"request_type" => "runtime_auth"} = request, outcome, actor_id)
      when outcome in ~w(saved_unverified authenticated canceled failed unknown) and
             is_binary(actor_id) and actor_id != "" do
    payload = get_in(request, ["request_payload", "runtime_auth"]) || %{}
    target_payload = payload["target"] || %{}

    with true <- request["status"] == "pending",
         true <- not expired?(request),
         {:ok, worker} <- Control.get(target_payload["agent_id"], request["tenant_id"]),
         true <- worker["group_id"] == request["group_id"],
         config when is_map(config) <- worker["runtime_config"],
         true <-
           config["kind"] == "compute_workload" and
             config["workload_id"] == target_payload["workload_id"] and
             config["binding_revision"] == target_payload["binding_revision"] and
             get_in(config, ["owner_scope", "id"]) == target_payload["project_id"],
         provider when provider in ["codex", "pi", "claude"] <-
           get_in(config, ["runtime_spec", "provider"]),
         {:ok, status} <-
           completion_status(worker, request, target_payload["workload_id"], provider, actor_id),
         :ok <- validate_outcome(payload["action"], outcome, status) do
      {:ok,
       %{
         "outcome" => outcome,
         "target" => %{
           "kind" => "compute_workload",
           "workload_id" => target_payload["workload_id"],
           "agent_id" => target_payload["agent_id"]
         },
         "management_url" => payload["management_url"]
       }}
    else
      _ -> {:error, :runtime_auth_target_changed}
    end
  end

  def validate_completion(_request, _outcome, _actor_id),
    do: {:error, :invalid_runtime_auth_completion}

  defp request_human(action, args, status, caller, worker, target, ctx) do
    with {:ok, request_spec} <- request_spec(action, args, status),
         :ok <- ensure_current_worker(caller, worker, target),
         {:ok, management_url} <-
           management_url(caller.tenant_id, target.project_id, target.workload_id),
         {:ok, request} <-
           CapabilityRequestStore.create_capability_request(%{
             "tenant_id" => caller.tenant_id,
             "group_id" => caller.group_id,
             "source_agent_id" => caller.agent_id,
             "source_session_id" => session_id(ctx),
             "tool_call_id" => tool_call_id(ctx),
             "request_type" => "runtime_auth",
             "request_payload" => %{
               "runtime_auth" =>
                 Map.merge(request_spec, %{
                   "target" => %{
                     "kind" => "compute_workload",
                     "workload_id" => target.workload_id,
                     "project_id" => target.project_id,
                     "agent_id" => worker["agent_id"],
                     "binding_revision" => target.binding_revision
                   },
                   "management_url" => management_url,
                   "requested_by" => caller.agent_id
                 })
             },
             "expires_at" => System.system_time(:second) + @request_ttl_seconds
           }) do
      management_url = management_request_url(management_url, request["request_id"])

      content =
        Jason.encode!(%{
          "status" => "requires_admin",
          "request_id" => request["request_id"],
          "tool_call_id" => tool_call_id(ctx),
          "management_url" => management_url,
          "target" => %{
            "kind" => "compute_workload",
            "workload_id" => target.workload_id,
            "agent_id" => worker["agent_id"]
          },
          "message" => "runtime authentication requires an Agent Swarm administrator"
        })

      wait =
        Waits.build(
          "runtime authentication for " <> target.workload_id,
          @wait,
          "auto_wait",
          %{"tool_call_id" => tool_call_id(ctx), "tool_name" => "runtime.auth"}
        )

      {content,
       [
         %{
           "type" => "async_tool_call_started",
           "session_id" => session_id(ctx),
           "tool_call_id" => tool_call_id(ctx),
           "tool_name" => "runtime.auth",
           "input" => Jason.encode!(args),
           "status" => "running",
           "completion_mode" => "external_callback",
           "started_at" => System.system_time(:millisecond),
           "auto_wait_seconds" => @wait
         }
         |> Map.merge(CapabilityRequestStore.execution_fields(request)),
         Waits.event(session_id(ctx), wait)
       ]}
    else
      {:error, reason} -> raise "runtime.auth request failed: #{format_reason(reason)}"
    end
  end

  defp request_spec("start", args, status) do
    method = args["method"]
    backend = args["backend"]

    if Enum.any?(status["methods"] || [], fn candidate ->
         field(candidate, :method) == method and field(candidate, :backend) == backend
       end) do
      {:ok, %{"action" => "start", "method" => method, "backend" => backend}}
    else
      {:error, :unsupported_runtime_auth_method}
    end
  end

  defp request_spec("verify", _args, status) do
    backend = field(status["auth"] || %{}, :backend)

    if is_binary(backend) and
         Enum.any?(status["methods"] || [], fn candidate ->
           field(candidate, :method) == "verify" and field(candidate, :backend) == backend
         end) do
      {:ok, %{"action" => "verify", "backend" => backend}}
    else
      {:error, :verification_unavailable}
    end
  end

  defp request_spec("cancel", args, status) do
    attempt = status["attempt"] || %{}

    if field(attempt, :attempt_id) == args["attempt_id"] do
      {:ok, %{"action" => "cancel", "attempt_id" => args["attempt_id"]}}
    else
      {:error, :runtime_auth_target_changed}
    end
  end

  defp status(worker, target, caller, ctx) do
    adapter =
      Application.get_env(:salix_agent, :runtime_auth_adapter, SalixEnv.ComputeRuntimeAuth)

    adapter.call_for_external_worker(:status, worker, %{
      workload_id: target.workload_id,
      provider: target.provider,
      group_id: caller.group_id,
      generation: "derive",
      actor_id: "router:" <> caller.agent_id <> ":" <> session_id(ctx)
    })
  end

  defp completion_status(worker, request, workload_id, provider, actor_id) do
    adapter =
      Application.get_env(:salix_agent, :runtime_auth_adapter, SalixEnv.ComputeRuntimeAuth)

    adapter.call_for_external_worker(:status, worker, %{
      workload_id: workload_id,
      provider: provider,
      group_id: request["group_id"],
      generation: "derive",
      actor_id: actor_id
    })
  end

  defp validate_outcome(action, outcome, status) do
    allowed =
      case action do
        "start" -> ~w(saved_unverified authenticated canceled failed unknown)
        "verify" -> ~w(authenticated failed unknown)
        "cancel" -> ~w(canceled failed unknown)
        _ -> []
      end

    cond do
      outcome not in allowed ->
        {:error, :invalid_runtime_auth_completion}

      outcome == "authenticated" and field(status["auth"] || %{}, :status) != "authenticated" ->
        {:error, :runtime_auth_target_changed}

      outcome == "saved_unverified" and field(status["auth"] || %{}, :status) != "configured" ->
        {:error, :runtime_auth_target_changed}

      outcome == "canceled" and is_map(status["attempt"]) ->
        {:error, :runtime_auth_target_changed}

      true ->
        :ok
    end
  end

  defp expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: System.system_time(:second) >= expires_at

  defp expired?(_request), do: false

  defp caller(ctx) do
    agent_id = context_string(ctx, :agent_id)
    tenant_id = context_string(ctx, :tenant_id)
    group_id = context_string(ctx, :group_id)

    with {:ok, agent} <- Control.get(agent_id, tenant_id),
         true <- agent["role"] == "router" and agent["group_id"] == group_id do
      {:ok, %{agent_id: agent_id, tenant_id: tenant_id, group_id: group_id}}
    else
      _ -> {:error, :runtime_auth_not_authorized}
    end
  end

  defp exact_worker(caller, %{
         "kind" => "compute_workload",
         "workload_id" => workload_id,
         "agent_id" => agent_id
       }) do
    with true <- is_binary(workload_id) and byte_size(workload_id) in 1..256,
         true <- is_binary(agent_id) and byte_size(agent_id) in 1..256,
         {:ok, worker} <- Control.get(agent_id, caller.tenant_id),
         true <- worker["group_id"] == caller.group_id,
         true <- worker_for_workload?(worker, workload_id) do
      config = worker["runtime_config"]
      spec = config["runtime_spec"]

      {:ok, worker,
       %{
         workload_id: workload_id,
         agent_id: agent_id,
         project_id: get_in(config, ["owner_scope", "id"]),
         provider: spec["provider"],
         binding_revision: config["binding_revision"]
       }}
    else
      _ -> {:error, :runtime_auth_target_not_visible}
    end
  end

  defp exact_worker(_caller, _target), do: {:error, :invalid_runtime_auth_target}

  defp worker_for_workload?(agent, workload_id) do
    config = agent["runtime_config"] || %{}

    agent["role"] == "worker" and agent["status"] not in ["cancelled", "failed"] and
      config["kind"] == "compute_workload" and config["workload_id"] == workload_id and
      is_integer(config["binding_revision"]) and config["binding_revision"] > 0 and
      get_in(config, ["owner_scope", "type"]) == "project" and
      get_in(config, ["runtime_spec", "provider"]) in ["codex", "pi", "claude"]
  end

  defp ensure_current_worker(caller, worker, target) do
    with {:ok, current} <- Control.get(worker["agent_id"], caller.tenant_id),
         true <- current["group_id"] == caller.group_id,
         config when is_map(config) <- current["runtime_config"],
         true <-
           config["kind"] == "compute_workload" and
             config["workload_id"] == target.workload_id and
             config["binding_revision"] == target.binding_revision and
             get_in(config, ["runtime_spec", "provider"]) == target.provider and
             get_in(config, ["owner_scope", "id"]) == target.project_id do
      :ok
    else
      _ -> {:error, :runtime_auth_target_changed}
    end
  end

  defp project_status(status, target) do
    %{
      "target" => %{
        "kind" => "compute_workload",
        "workload_id" => target.workload_id,
        "agent_id" => target.agent_id
      },
      "provider" => status["provider"],
      "auth" => status["auth"],
      "native_ready" => status["native_ready"],
      "dispatch_ready" => status["dispatch_ready"],
      "methods" => status["methods"] || [],
      "attempt" => status["attempt"]
    }
  end

  defp management_url(tenant_id, project_id, workload_id) do
    fun =
      Application.get_env(
        :salix_agent,
        :runtime_auth_management_url_fn,
        &default_management_url/3
      )

    fun.(tenant_id, project_id, workload_id)
  end

  defp default_management_url(tenant_id, project_id, workload_id) do
    with true <- is_binary(project_id) and project_id != "",
         {:ok, record} <- SalixStore.TenantConfigs.get(tenant_id, "conversation_links"),
         template when is_binary(template) <-
           get_in(record, ["value", "conversation_url_template"]),
         %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) <-
           URI.parse(template) do
      base = %URI{scheme: scheme, host: host, port: uri.port}
      query = URI.encode_query(%{"target" => workload_id})
      {:ok, URI.to_string(%{base | path: "/runtime-auth/projects/" <> project_id, query: query})}
    else
      _ -> {:error, :runtime_auth_management_url_unavailable}
    end
  end

  defp management_request_url(url, request_id) do
    uri = URI.parse(url)

    query =
      uri.query
      |> then(&if(&1, do: URI.decode_query(&1), else: %{}))
      |> Map.put("request", request_id)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  defp validate_shape("status", args), do: exact_keys(args, ~w(action target))
  defp validate_shape("verify", args), do: exact_keys(args, ~w(action target))
  defp validate_shape("start", args), do: exact_keys(args, ~w(action backend method target))
  defp validate_shape("cancel", args), do: exact_keys(args, ~w(action attempt_id target))
  defp validate_shape(_, _args), do: {:error, :invalid_runtime_auth_action}

  defp exact_keys(args, keys) do
    if Enum.sort(Map.keys(args)) == Enum.sort(keys) and
         Enum.all?(Map.take(args, keys -- ["target"]), fn {_key, value} ->
           is_binary(value) and byte_size(value) in 1..128
         end),
       do: :ok,
       else: {:error, :invalid_runtime_auth_request}
  end

  defp schema do
    target = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(kind workload_id agent_id),
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["compute_workload"]},
        "workload_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
        "agent_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 256}
      }
    }

    branch = fn action, required, properties ->
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["action", "target" | required],
        "properties" =>
          Map.merge(
            %{
              "action" => %{"type" => "string", "enum" => [action]},
              "target" => target
            },
            properties
          )
      }
    end

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action", "target"],
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(status start verify cancel)},
        "target" => target,
        "method" => %{
          "type" => "string",
          "enum" => ["native_login", "credential_import"]
        },
        "backend" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "attempt_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
      },
      "oneOf" => [
        branch.("status", [], %{}),
        branch.("start", ~w(method backend), %{
          "method" => %{"type" => "string", "enum" => ["native_login", "credential_import"]},
          "backend" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
        }),
        branch.("verify", [], %{}),
        branch.("cancel", ["attempt_id"], %{
          "attempt_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
        })
      ]
    }
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp context_string(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> ""
    end
  end

  defp session_id(ctx), do: context_string(ctx, :session_id)
  defp tool_call_id(ctx), do: context_string(ctx, :tool_call_id)
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
