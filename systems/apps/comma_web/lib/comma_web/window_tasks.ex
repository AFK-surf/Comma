defmodule CommaWeb.WindowTasks do
  @moduledoc """
  Tasks that a Workspace's member starts from the New task window:

    * `POST /v1/comma/workspaces/:ws/tasks` `{text, model?, runs_on?,
      client_request_id}`: starts a Task, owned by the caller, with `text` its
      first Message (`SalixIM.ModelMentionTask.start_from_window/5`). The
      uploads `text` names (`(workspace file: /uploads/…)`, put in the Router's
      VFS by the window, as the composer's are) are shared into it first.
      Without `runs_on`, the Task runs in Comma's cloud on `model` (`{id,
      effort?}`) or the Workspace's Task model. With `runs_on: {kind: "station",
      device_id}` naming a connected Monoid (`stillfail`) station of this
      Workspace's Group, the Task runs there on the workspace's default model or
      on `model: {kind: "runtime", provider, model?}`. Answers `{task_id,
      group_id}` as soon as the Task is made, so the window opens it at once:
      nothing is posted to Home. Made once per `client_request_id`.

  A read-only member (`viewer`) starts none. A Task the Workspace cannot run
  (its model, a file that could not be passed on, an unknown or offline Monoid
  workspace) is refused (409) with why; a failure the same request may get past
  is 503 `task_unavailable`.
  """

  import Plug.Conn
  require Logger

  @text_bytes 16_000

  def start(conn, workspace_id) do
    started = SystemsClock.monotonic_time(:millisecond)

    with_member(conn, workspace_id, fn workspace, user ->
      body = conn.body_params || %{}

      with {:ok, text} <- text(body["text"]),
           {:ok, request_id} <- request_id(body["client_request_id"]),
           {:ok, runs_on} <- runs_on(body["runs_on"]),
           {:ok, model} <- model(body["model"], runs_on),
           group = workspace.salix_group_id,
           :ok <- check_stillfail_station(workspace.salix_tenant_id, group, runs_on),
           {:ok, router} <- router(group),
           {:ok, created} <-
             SalixIM.ModelMentionTask.start_from_window(
               group,
               router,
               user["id"],
               request_id,
               model
               |> Map.put(:text, text)
               |> put_present(:runs_on, runs_on)
             ) do
        Logger.info(
          "window task started group=#{group} ms=#{SystemsClock.monotonic_time(:millisecond) - started}"
        )

        json(conn, 201, %{task_id: created["conversation_id"], group_id: group})
      end
    end)
  end

  defp router(group) do
    case SalixIM.GroupDirectory.get_group(group) do
      {:ok, %{"router_agent_id" => router}} when is_binary(router) -> {:ok, router}
      {:ok, _group} -> {:error, :no_router}
      {:error, reason} -> {:error, {:group, reason}}
    end
  end

  # --- Access

  defp with_member(conn, workspace_id, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case Comma.Stations.member(user, session, workspace_id) do
          {:ok, _workspace, "viewer"} ->
            json(conn, 403, %{error: "forbidden"})

          {:ok, workspace, _role} ->
            case fun.(workspace, user) do
              %Plug.Conn{} = done -> done
              error -> error(conn, error)
            end

          {:error, :forbidden} ->
            json(conn, 403, %{error: "forbidden"})

          _ ->
            json(conn, 404, %{error: "not_found"})
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  # --- Input

  defp text(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, {:bad_request, "text is required"}}
      byte_size(text) > @text_bytes -> {:error, {:bad_request, "text is too long"}}
      true -> {:ok, text}
    end
  end

  defp text(_text), do: {:error, {:bad_request, "text is required"}}

  defp request_id(id) when is_binary(id) and byte_size(id) in 1..128, do: {:ok, id}
  defp request_id(_id), do: {:error, {:bad_request, "client_request_id is required"}}

  defp runs_on(nil), do: {:ok, nil}

  defp runs_on(%{"kind" => "station", "device_id" => device_id} = place)
       when map_size(place) == 2 and is_binary(device_id) do
    device_id = String.trim(device_id)

    if byte_size(device_id) in 1..256,
      do: {:ok, %{"kind" => "station", "device_id" => device_id}},
      else: {:error, {:bad_request, "runs_on device_id is required"}}
  end

  defp runs_on(_runs_on),
    do: {:error, {:bad_request, "runs_on must name a station device_id"}}

  defp model(nil, _runs_on), do: {:ok, %{}}

  defp model(%{"id" => id} = model, nil) when is_binary(id) and byte_size(id) in 1..256 do
    case model["effort"] do
      nil ->
        {:ok, %{model: id}}

      effort when is_binary(effort) and byte_size(effort) in 1..32 ->
        {:ok, %{model: id, effort: effort}}

      _effort ->
        {:error, {:bad_request, "model effort must be a name"}}
    end
  end

  defp model(_model, nil), do: {:error, {:bad_request, "model must name a catalog model id"}}

  defp model(%{"id" => _}, %{"kind" => "station"}),
    do: {:error, {:bad_request, "station runs_on does not accept a catalog model"}}

  defp model(%{"kind" => "runtime", "provider" => provider} = choice, %{"kind" => "station"})
       when map_size(choice) == 2 and is_binary(provider) do
    provider = String.trim(provider)

    if byte_size(provider) in 1..64,
      do: {:ok, %{runtime_model: %{"kind" => "runtime", "provider" => provider}}},
      else: {:error, {:bad_request, "model provider is required"}}
  end

  defp model(
         %{"kind" => "runtime", "provider" => provider, "model" => model_id} = choice,
         %{"kind" => "station"}
       )
       when map_size(choice) == 3 and is_binary(provider) and is_binary(model_id) do
    provider = String.trim(provider)
    model_id = String.trim(model_id)

    if byte_size(provider) in 1..64 and byte_size(model_id) in 1..256 do
      {:ok, %{runtime_model: %{"kind" => "runtime", "provider" => provider, "model" => model_id}}}
    else
      {:error, {:bad_request, "model provider and model must be non-empty strings"}}
    end
  end

  defp model(_model, %{"kind" => "station"}),
    do: {:error, {:bad_request, "model must be omitted or of kind runtime"}}

  defp check_stillfail_station(_tenant, _group, nil), do: :ok

  defp check_stillfail_station(tenant, group, %{"kind" => "station", "device_id" => device_id}) do
    case SalixEnv.Registry.get_device(tenant, group, device_id) do
      {:ok, device} ->
        cond do
          get_in(device, ["meta", "device_kind"]) != "stillfail" ->
            {:error, {:runs_on, :device_not_found, :requested}}

          device["status"] != "connected" ->
            {:error, :machine_offline}

          true ->
            :ok
        end

      {:error, :not_found} ->
        {:error, {:runs_on, :device_not_found, :requested}}

      {:error, reason} ->
        {:error, {:device, reason}}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # --- Answers

  defp error(conn, {:error, {:bad_request, message}}),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp error(conn, {:error, :machine_offline}) do
    Logger.info("window task refused reason=:machine_offline")

    json(conn, 409, %{
      error: "machine_offline",
      message: "That Monoid workspace is offline. Try again when it is back, or choose another."
    })
  end

  defp error(conn, {:error, {:runs_on, :device_offline, _source} = reason}) do
    Logger.info("window task refused reason=#{inspect(reason)}")

    json(conn, 409, %{
      error: "machine_offline",
      message: "That Monoid workspace is offline. Try again when it is back, or choose another."
    })
  end

  defp error(conn, {:error, {:billing_unavailable, decision}}) do
    {status, body} = CommaWeb.BillingErrors.billing_response(decision)
    json(conn, status, body)
  end

  defp error(conn, {:error, {:runs_on, {:billing_unavailable, decision}, _source}}) do
    {status, body} = CommaWeb.BillingErrors.billing_response(decision)
    json(conn, status, body)
  end

  defp error(conn, {:error, {:task_model_selection_failed, message}}) do
    {status, body} = CommaWeb.BillingErrors.task_model_selection_response(message)
    json(conn, status, body)
  end

  # A refusal is final: the window says why, and another try is another Task.
  # Anything else may pass when the same request comes again, and may even have
  # made the Task, so the window tries again under the same client_request_id.
  defp error(conn, {:error, reason}) do
    case SalixIM.ModelMentionTask.refusal_message(reason) do
      {:ok, message} ->
        Logger.info("window task refused reason=#{inspect(reason)}")
        json(conn, 409, %{error: "refused", message: message})

      :error ->
        Logger.warning("window task failed reason=#{inspect(reason)}")
        json(conn, 503, %{error: "task_unavailable"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
