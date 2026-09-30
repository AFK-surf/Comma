defmodule SalixAgent.CapabilityRequests do
  @moduledoc """
  Durable capability requests raised by agent tools.

  A capability request is scoped to an agent group for storage, listing,
  streaming, and completion. The source agent/session fields are provenance and
  the target for delivering completion back into the runtime.
  """

  @behaviour SalixAgent.CapabilityRequestStore

  alias SalixAgent.{Control, GroupContext}
  alias SalixStore.{Ids, Keys, S3}

  @callback notify_capability_request(request :: map()) :: :ok

  @list_read_concurrency 8
  @default_request_ttl_seconds 120
  @receipt_result_budget_ms 30_000
  @request_types ~w(host_access computer_use_start location oauth_authorization runtime_auth ifc_declassify)

  # How long one confirmed information-flow transfer stays confirmed. Long
  # enough for the Router to retry the effect it was refused for, short
  # enough that a receipt is not a standing permission
  # (docs/verification.md).
  @declassification_ttl_ms 60 * 60 * 1000

  @impl true
  def create_capability_request(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, source_agent_id} <- required_string(attrs, "source_agent_id"),
         {:ok, source_session_id} <- required_string(attrs, "source_session_id"),
         true <- Ids.valid_session_id?(source_session_id),
         {:ok, tool_call_id} <- required_string(attrs, "tool_call_id"),
         {:ok, request_type} <- required_string(attrs, "request_type"),
         {:ok, request_payload} <- object(attrs["request_payload"], "request_payload"),
         {:ok, response_payload} <- optional_object(attrs["response_payload"], "response_payload"),
         {:ok, surface_ref} <- optional_object(attrs["surface_ref"], "surface_ref"),
         {:ok, expires_at} <- request_expiry(attrs["expires_at"]),
         {:ok, agent} <- Control.get(source_agent_id),
         {:ok, scope} <- request_scope(attrs, agent),
         {:ok, _group} <- GroupContext.get(scope.group_id, scope.tenant_id) do
      now = now()

      request_id =
        request_id(
          attrs,
          source_agent_id,
          source_session_id,
          tool_call_id,
          request_type
        )

      record =
        %{
          "request_id" => request_id,
          "group_id" => scope.group_id,
          "tenant_id" => scope.tenant_id,
          "source_agent_id" => source_agent_id,
          "source_session_id" => source_session_id,
          "tool_call_id" => tool_call_id,
          "request_type" => request_type,
          "status" => nonblank(attrs["status"]) || "pending",
          "request_payload" => request_payload,
          "response_payload" => response_payload,
          "surface_kind" => nonblank(attrs["surface_kind"]),
          "surface_ref" => surface_ref,
          "expires_at" => expires_at,
          "created_at" => attrs["created_at"] || now,
          "updated_at" => now,
          "completed_at" => attrs["completed_at"]
        }

      case upsert_record(
             Keys.ctl_capability_request(scope.group_id, request_id),
             record,
             fn current ->
               if terminal?(current) do
                 current
               else
                 current
                 |> Map.merge(Map.drop(record, ["created_at", "expires_at"]))
                 |> Map.put("created_at", current["created_at"] || record["created_at"])
               end
             end
           ) do
        {:ok, request} ->
          with :ok <- register_location_timeout(request) do
            notify(request)
            {:ok, request}
          end

        {:error, _reason} = err ->
          err
      end
    else
      false -> {:error, {:bad_request, "source_session_id is invalid"}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def pending_capability_request?(agent_id, session_id, tool_call_id)
      when is_binary(agent_id) and agent_id != "" and is_binary(session_id) and
             is_binary(tool_call_id) and tool_call_id != "" do
    if Ids.valid_session_id?(session_id) do
      with {:ok, agent} <- Control.get(agent_id),
           group_id when is_binary(group_id) <- nonblank(agent["group_id"]),
           tenant_id when is_binary(tenant_id) <- nonblank(agent["tenant_id"]) do
        case find_request_for_tool_call(group_id, tenant_id, agent_id, session_id, tool_call_id) do
          {:ok, %{} = request} -> visible_for_status?(request, "pending")
          {:ok, nil} -> false
          {:error, _unavailable} -> true
        end
      else
        _ -> false
      end
    else
      false
    end
  end

  def pending_capability_request?(_agent_id, _session_id, _tool_call_id), do: false

  @impl true
  def cancel_capability_request(agent_id, session_id, tool_call_id, reason)
      when is_binary(agent_id) and agent_id != "" and is_binary(session_id) and
             is_binary(tool_call_id) and tool_call_id != "" do
    if Ids.valid_session_id?(session_id) do
      with {:ok, agent} <- Control.get(agent_id),
           group_id when is_binary(group_id) <- nonblank(agent["group_id"]),
           tenant_id when is_binary(tenant_id) <- nonblank(agent["tenant_id"]),
           {:ok, %{} = request} <-
             find_request_for_tool_call(
               group_id,
               tenant_id,
               agent_id,
               session_id,
               tool_call_id
             ),
           true <- is_map(request) do
        cancel(request, reason)
      else
        {:ok, nil} -> {:ok, :not_found}
        false -> {:ok, :not_found}
        {:error, _} = err -> err
        _ -> {:ok, :not_found}
      end
    else
      {:error, :invalid_session_id}
    end
  end

  def cancel_capability_request(_agent_id, _session_id, _tool_call_id, _reason),
    do: {:ok, :not_found}

  @impl true
  def reconcile_capability_request(agent_id, session_id, tool_call_id, execution_result \\ nil) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, agent} <- Control.get(agent_id),
         group_id when is_binary(group_id) <- nonblank(agent["group_id"]),
         tenant_id when is_binary(tenant_id) <- nonblank(agent["tenant_id"]),
         {:ok, request} <-
           find_request_for_tool_call(group_id, tenant_id, agent_id, session_id, tool_call_id) do
      case request do
        nil ->
          {:ok, :not_found}

        request ->
          transition(request, fn current ->
            if is_map(execution_result) do
              status =
                if execution_result["status"] in ["failed", "error", "cancelled"],
                  do: "failed",
                  else: "completed"

              terminal_record(current, status, %{}, execution_result)
            else
              current
            end
          end)
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
      _ -> {:ok, :not_found}
    end
  end

  def topic(group_id), do: "capability_requests:" <> to_string(group_id)

  def list_group(group_id, tenant_id, opts \\ []) do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, limit} <- request_limit(Keyword.get(opts, :limit)) do
      status = trim(Keyword.get(opts, :status) || "pending")

      requests =
        group_id
        |> Keys.ctl_capability_requests_prefix()
        |> list_records()
        |> Enum.filter(&(&1["tenant_id"] == tenant_id))
        |> Enum.filter(&visible_for_status?(&1, status))
        |> Enum.filter(&(blank?(status) or &1["status"] == status))
        |> Enum.sort_by(&{&1["updated_at"] || 0, &1["created_at"] || 0, &1["request_id"]}, :desc)
        |> Enum.take(limit)

      {:ok, requests}
    end
  end

  @doc "Read one bounded storage page of runtime-auth requests for a group."
  def list_runtime_auth_page(group_id, tenant_id, opts \\ []) do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, limit} <- runtime_auth_page_limit(Keyword.get(opts, :limit)),
         {:ok, cursor} <- list_cursor(Keyword.get(opts, :cursor)),
         {:ok, page} <-
           S3.list(
             Keys.ctl_capability_requests_prefix(group_id),
             [max_keys: limit] ++ if(cursor, do: [continuation_token: cursor], else: [])
           ) do
      requests =
        page.objects
        |> read_records()
        |> Enum.filter(
          &(&1["tenant_id"] == tenant_id and &1["request_type"] == "runtime_auth" and
              visible_for_status?(&1, "pending"))
        )
        |> Enum.sort_by(&{&1["updated_at"] || 0, &1["request_id"]}, :desc)

      {:ok, %{"requests" => requests, "next_cursor" => page.next}}
    end
  end

  @doc "Point-read one runtime-auth request without scanning its group."
  def get_runtime_auth(group_id, request_id, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "runtime_auth") do
      {:ok, request}
    end
  end

  def get(group_id, request_id, tenant_id), do: find(group_id, request_id, tenant_id)

  def share_location(group_id, request_id, attrs, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "location"),
         {:ok, response} <- location_response(attrs),
         {:ok, settled} <- settle_location(request, "completed", response),
         :ok <- require_location_completion(settled),
         :ok <- deliver_stored_result(settled) do
      {:ok, settled}
    end
  end

  defp require_location_completion(%{"status" => "completed"}), do: :ok

  defp require_location_completion(_request),
    do: {:error, {:conflict, :already_settled}}

  @doc "Settle a location deadline and retry delivery of its durable outcome."
  def expire_location(group_id, request_id, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "location"),
         {:ok, settled} <-
           settle_location(request, "expired", %{
             "status" => "error",
             "error" => "Location request timed out."
           }) do
      case settled["status"] do
        status when status in ["completed", "failed", "expired"] ->
          deliver_stored_result(settled)

        "cancelled" ->
          :ok
      end
    end
  end

  # The request CAS selects the outcome before the session receives it. The
  # timer remains armed until that delivery succeeds, including after restart.
  defp settle_location(request, status, response) do
    result =
      update_record_checked(
        Keys.ctl_capability_request(request["group_id"], request["request_id"]),
        fn current ->
          cond do
            terminal?(current) ->
              {:ok, reconcile_terminal_result(current)}

            status == "completed" and expired?(current) ->
              {:error, {:bad_request, "capability request has expired"}}

            status == "expired" and not expired?(current) ->
              {:error, :not_due}

            current["status"] == "pending" ->
              {:ok, terminal_record(current, status, response, location_result(response))}

            true ->
              {:error, {:conflict, :already_settled}}
          end
        end
      )

    case result do
      {:ok, settled} ->
        notify(settled)
        {:ok, settled}

      error ->
        error
    end
  end

  defp register_location_timeout(
         %{"request_type" => "location", "expires_at" => expires} = request
       )
       when is_integer(expires) do
    id = "location-timeout:" <> request["request_id"]

    SalixStore.Timers.register(%{
      "timer_id" => id,
      "kind" => "location_timeout",
      "agent_id" => request["source_agent_id"],
      "session_id" => request["source_session_id"],
      "deadline_ms" => expires * 1_000,
      "source_message_id" => id,
      "payload" => Map.take(request, ["group_id", "tenant_id", "request_id"])
    })
  end

  defp register_location_timeout(_request), do: :ok

  def confirm_oauth_authorization(group_id, request_id, tenant_id) do
    response = %{"status" => "confirmed"}

    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "oauth_authorization"),
         {:ok, completed} <-
           complete(
             request,
             response,
             completed_result(
               Map.put(response, "message", "oauth authorization was confirmed by the user")
             )
           ),
         :ok <- deliver_stored_result(completed) do
      {:ok, completed}
    end
  end

  def decide_host_access(group_id, request_id, attrs, tenant_id) do
    decide_permission(group_id, request_id, attrs, tenant_id, "host_access")
  end

  def decide_computer_use_start(group_id, request_id, attrs, tenant_id) do
    decide_permission(group_id, request_id, attrs, tenant_id, "computer_use_start")
  end

  @doc """
  Records a person's decision on one information-flow transfer
  (`docs/verification.md` §6.2).

  The answer settles the request first, in one compare-and-set, and only a
  settlement that actually moved it out of `pending` goes on to write
  anything. A card can be delivered twice, its buttons survive a failed
  update, and two people can press opposite ones at the same moment; a check
  before the write would let all of those through and the second receipt
  would silently replace the first. Once settled the request stays settled:
  a replay writes no second receipt and cannot turn a refusal into consent.

  Approval then writes the receipt *before* the agent is told anything, so
  the retry the Router makes next finds it. A receipt is scoped to the
  `(requester, sources, destination)` that was shown, expires on its own, and
  is consumed by the one effect that uses it; a refusal writes nothing at
  all. A receipt that cannot be written fails the decision rather than
  reporting consent that grants nothing.
  """
  @spec decide_declassification(String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def decide_declassification(group_id, request_id, attrs, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "ifc_declassify"),
         {:ok, approved} <- optional_bool(attrs, "approved", false),
         {:ok, settled} <- settle(request, %{"approved" => approved}) do
      if settled["status"] == "expired" do
        _ = deliver_stored_result(settled)
        {:error, {:bad_request, "capability request has expired"}}
      else
        # Only the decision CAS winner can create a receipt. Recovery never does.
        result =
          case write_declassification_receipt(settled, approved) do
            :ok -> permission_result(settled, approved, attrs)
            {:error, _} -> receipt_incomplete_result()
          end

        with {:ok, completed} <- settle_receipt_result(settled, result),
             :ok <- deliver_stored_result(completed) do
          if approved and completed["result"]["status"] != "completed" do
            {:error, {:bad_request, "authorization receipt result could not be confirmed"}}
          else
            {:ok, completed}
          end
        end
      end
    end
  end

  # The transition *is* the write. `update_record/2` is a compare-and-set over
  # the stored record, so a request that is no longer pending — or that ran
  # out its own clock while the card sat in the conversation — loses here
  # rather than in a preflight read that two callers could both pass.
  defp settle(request, response_payload) do
    now = now()

    result =
      update_record_checked(
        Keys.ctl_capability_request(request["group_id"], request["request_id"]),
        fn
          %{"status" => "pending"} = current ->
            current = ensure_request_deadline(current)

            if expired?(current) do
              {:ok, expired_record(current)}
            else
              {:ok,
               current
               |> Map.put("status", "completed")
               |> Map.put("response_payload", response_payload || %{})
               |> Map.put("updated_at", now)
               |> Map.put("completed_at", now)
               |> Map.put(
                 "settlement_deadline_ms",
                 System.system_time(:millisecond) + @receipt_result_budget_ms
               )}
            end

          _settled ->
            {:error, {:conflict, :already_settled}}
        end
      )

    case result do
      {:ok, settled} ->
        notify(settled)
        {:ok, settled}

      {:error, _reason} = err ->
        err
    end
  end

  defp write_declassification_receipt(_request, false), do: :ok

  defp write_declassification_receipt(request, true) do
    case SalixAgent.Tools.IFC.receipt_attrs(request, @declassification_ttl_ms) do
      {:ok, receipt_id, attrs} ->
        case SalixStore.IFC.put_receipt(
               request["tenant_id"],
               request["group_id"],
               receipt_id,
               attrs
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, {:bad_request, "receipt write failed: #{inspect(reason)}"}}
        end

      :error ->
        {:error, {:bad_request, "declassification request is missing its flow"}}
    end
  end

  def complete_runtime_auth(group_id, request_id, attrs, tenant_id) when is_map(attrs) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "runtime_auth"),
         outcome when is_binary(outcome) <- attrs["outcome"] || attrs[:outcome],
         actor_id when is_binary(actor_id) <- attrs["actor_id"] || attrs[:actor_id],
         {:ok, response} <-
           SalixAgent.Tools.RuntimeAuth.validate_completion(request, outcome, actor_id),
         {:ok, completed} <- complete(request, response, completed_result(response)),
         :ok <- deliver_stored_result(completed) do
      {:ok, completed}
    else
      nil -> {:error, {:bad_request, "runtime auth completion fields are required"}}
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "invalid runtime auth completion"}}
    end
  end

  def complete_runtime_auth(_group_id, _request_id, _attrs, _tenant_id),
    do: {:error, {:bad_request, "invalid runtime auth completion"}}

  defp find(group_id, request_id, tenant_id) do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, request} <- get_record(Keys.ctl_capability_request(group_id, request_id)),
         true <- request["tenant_id"] == tenant_id and request["group_id"] == group_id do
      {:ok, request}
    else
      false -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  defp required_string(attrs, key) do
    case nonblank(attrs[key]) do
      nil -> {:error, {:bad_request, "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp object(value, _key) when is_map(value), do: {:ok, value}
  defp object(_value, key), do: {:error, {:bad_request, "#{key} must be an object"}}

  defp optional_object(nil, _key), do: {:ok, %{}}
  defp optional_object(value, key), do: object(value, key)

  defp request_scope(attrs, agent) do
    agent_tenant_id = nonblank(agent["tenant_id"])
    agent_group_id = nonblank(agent["group_id"])
    requested_tenant_id = nonblank(attrs["tenant_id"])
    requested_group_id = nonblank(attrs["group_id"])

    tenant_id = requested_tenant_id || agent_tenant_id
    group_id = requested_group_id || agent_group_id

    cond do
      blank?(group_id) ->
        {:error, {:bad_request, "source agent has no group"}}

      tenant_id != agent_tenant_id ->
        {:error, {:bad_request, "tenant_id does not match source agent"}}

      not blank?(requested_group_id) and not blank?(agent_group_id) and
          requested_group_id != agent_group_id ->
        {:error, {:bad_request, "group_id does not match source agent"}}

      true ->
        {:ok, %{tenant_id: tenant_id, group_id: group_id}}
    end
  end

  defp request_id(attrs, source_agent_id, source_session_id, tool_call_id, request_type) do
    case nonblank(attrs["request_id"]) do
      nil ->
        identity =
          Enum.join(
            [source_agent_id, source_session_id, tool_call_id, request_type],
            "\u001F"
          )

        "cap-" <>
          (:crypto.hash(:sha256, identity)
           |> Base.url_encode64(padding: false))

      explicit_id ->
        explicit_id
    end
  end

  defp terminal?(%{"status" => status})
       when status in ["completed", "failed", "expired", "cancelled"],
       do: true

  defp terminal?(_request), do: false

  defp visible_for_status?(request, "pending") do
    request["status"] == "pending" and not expired?(request)
  end

  defp visible_for_status?(_request, _status), do: true

  defp expired?(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: now() >= expires_at

  defp expired?(_request), do: false

  defp require_type(%{"request_type" => type}, type), do: :ok

  defp require_type(_request, _type),
    do: {:error, {:bad_request, "wrong capability request type"}}

  defp location_response(%{"status" => "success", "location" => location})
       when is_map(location) do
    with {:ok, lat} <- number_value(location["latitude"], "latitude"),
         {:ok, lng} <- number_value(location["longitude"], "longitude") do
      {:ok,
       %{
         "status" => "success",
         "location" =>
           %{"latitude" => lat, "longitude" => lng}
           |> put_optional("accuracy_m", location["accuracy_m"])
       }}
    end
  end

  defp location_response(%{"status" => "error"} = attrs) do
    {:ok, %{"status" => "error", "error" => trim(attrs["error"]) || "Location unavailable"}}
  end

  defp location_response(_attrs), do: {:error, {:bad_request, "invalid location completion"}}

  defp number_value(value, _name) when is_number(value), do: {:ok, value}
  defp number_value(_value, name), do: {:error, {:bad_request, "#{name} must be a number"}}

  defp location_result(%{"status" => "success", "location" => location}) do
    completed_result(%{
      "status" => "completed",
      "location" => Map.take(location, ["latitude", "longitude"])
    })
  end

  defp location_result(%{"status" => "error"} = response) do
    failed_result(
      "location_unavailable",
      trim(response["error"]) || "Location unavailable",
      %{"status" => "failed"},
      "Location is unavailable."
    )
  end

  defp decide_permission(group_id, request_id, attrs, tenant_id, request_type) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, request_type),
         {:ok, approved} <- optional_bool(attrs, "approved", false),
         {:ok, completed} <-
           complete(
             request,
             %{"approved" => approved} |> put_optional("mode", nonblank(attrs["mode"])),
             permission_result(request, approved, attrs)
           ),
         :ok <- deliver_stored_result(completed) do
      {:ok, completed}
    end
  end

  defp permission_result(request, true, _attrs) do
    completed_result(%{"status" => "approved", "capability" => permission_capability(request)})
  end

  defp permission_result(request, false, attrs) do
    capability = permission_capability(request)
    payload = %{"capability" => capability} |> put_optional("mode", nonblank(attrs["mode"]))

    failed_result(
      "permission_denied",
      "permission denied: " <> capability,
      payload,
      "Permission was denied."
    )
  end

  defp deliver_stored_result(%{"result" => result} = request) when is_map(result),
    do: deliver_async_tool_completion(request, result)

  defp deliver_stored_result(_request), do: {:error, :capability_result_unavailable}

  defp permission_capability(%{"request_type" => type, "request_payload" => payload}) do
    get_in(payload || %{}, [type, "capability"]) || type
  end

  defp deliver_async_tool_completion(request, result) do
    case SalixAgent.complete_async_tool_call(
           request["source_agent_id"],
           request["source_session_id"],
           request["tool_call_id"],
           result,
           %{
             "tool_name" => tool_name_for_request(request)
           }
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp completed_result(payload) do
    content = Jason.encode!(payload)

    %{
      "content" => content,
      "output" => content,
      "status" => "completed",
      "error" => false
    }
  end

  defp failed_result(error_class, error_message, payload, public_summary) do
    content =
      payload
      |> Map.put("status", "failed")
      |> Map.put("error", error_message)
      |> Jason.encode!()

    %{
      "content" => content,
      "output" => content,
      "status" => "failed",
      "error" => true,
      "error_class" => error_class,
      "error_message" => error_message,
      "diagnostic_visibility" => "user_reportable",
      "public_summary" => public_summary
    }
  end

  defp tool_name_for_request(%{"request_type" => "location"}), do: "location.request"

  defp tool_name_for_request(%{"request_type" => "oauth_authorization"}),
    do: "oauth.request_authorization"

  defp tool_name_for_request(%{"request_type" => "runtime_auth"}), do: "runtime.auth"

  defp tool_name_for_request(%{"request_type" => "ifc_declassify"}),
    do: "ifc.request_declassification"

  defp tool_name_for_request(_request), do: "permission.request"

  defp complete(request, response_payload, result) do
    transition(request, fn current ->
      terminal_record(current, "completed", response_payload, result)
    end)
  end

  defp cancel(request, reason) do
    transition(request, fn current ->
      result =
        failed_result(
          "capability_request_cancelled",
          reason || "Request was cancelled",
          %{"status" => "cancelled"},
          "The request was cancelled."
        )

      terminal_record(
        current,
        "cancelled",
        %{"status" => "cancelled", "reason" => reason},
        result
      )
    end)
  end

  # Persist the winning result before delivery; repeated delivery replays it.
  defp transition(request, pending_fun) do
    result =
      update_record(
        Keys.ctl_capability_request(request["group_id"], request["request_id"]),
        fn current ->
          current = ensure_request_deadline(current)

          cond do
            terminal?(current) -> reconcile_terminal_result(current)
            expired?(current) -> expired_record(current)
            true -> pending_fun.(current)
          end
        end
      )

    case result do
      {:ok, settled} ->
        if settled != request, do: notify(settled)
        {:ok, settled}

      error ->
        error
    end
  end

  defp ensure_request_deadline(%{"expires_at" => deadline} = request) when is_integer(deadline),
    do: request

  defp ensure_request_deadline(request) do
    created_at = if is_integer(request["created_at"]), do: request["created_at"], else: 0
    Map.put(request, "expires_at", created_at + @default_request_ttl_seconds)
  end

  defp terminal_record(request, status, response, result) do
    timestamp = now()

    request
    |> Map.put("status", status)
    |> Map.put("response_payload", response)
    |> Map.put("result", result)
    |> Map.put("updated_at", timestamp)
    |> Map.put("completed_at", timestamp)
  end

  defp settle_receipt_result(request, proposed_result) do
    update_record(
      Keys.ctl_capability_request(request["group_id"], request["request_id"]),
      fn current ->
        cond do
          is_map(current["result"]) -> current
          receipt_result_due?(current) -> Map.put(current, "result", receipt_incomplete_result())
          true -> Map.put(current, "result", proposed_result)
        end
      end
    )
  end

  defp reconcile_terminal_result(%{"result" => result} = request) when is_map(result), do: request

  defp reconcile_terminal_result(
         %{"request_type" => "ifc_declassify", "status" => "completed"} = request
       ) do
    if receipt_result_due?(request),
      do: Map.put(request, "result", receipt_incomplete_result()),
      else: request
  end

  defp reconcile_terminal_result(request) do
    response = request["response_payload"] || %{}

    result =
      cond do
        request["status"] == "expired" ->
          expired_record(request)["result"]

        request["status"] in ["failed", "cancelled"] ->
          failed_result(
            "capability_request_inactive",
            "External capability request is no longer active",
            response,
            "The request did not complete."
          )

        request["request_type"] == "location" and response["status"] in ["success", "error"] ->
          location_result(response)

        request["request_type"] in ["host_access", "computer_use_start"] ->
          permission_result(request, response["approved"] == true, response)

        true ->
          completed_result(response)
      end

    Map.put(request, "result", result)
  end

  defp receipt_result_due?(request) do
    deadline = request["settlement_deadline_ms"]
    not is_integer(deadline) or System.system_time(:millisecond) >= deadline
  end

  defp receipt_incomplete_result do
    failed_result(
      "capability_receipt_result_unknown",
      "The permission decision was recorded, but its authorization receipt could not be confirmed",
      %{"status" => "failed"},
      "The permission result could not be confirmed."
    )
  end

  defp expired_record(request) do
    result =
      failed_result(
        "capability_request_expired",
        "External capability request expired",
        %{"status" => "expired"},
        "The request expired before it was completed."
      )

    terminal_record(request, "expired", %{"status" => "expired"}, result)
  end

  defp find_request_for_tool_call(group_id, tenant_id, agent_id, session_id, tool_call_id) do
    Enum.reduce_while(@request_types, {:ok, nil}, fn request_type, _not_found ->
      request_id = request_id(%{}, agent_id, session_id, tool_call_id, request_type)

      case get_record(Keys.ctl_capability_request(group_id, request_id)) do
        {:ok,
         %{
           "tenant_id" => ^tenant_id,
           "source_agent_id" => ^agent_id,
           "source_session_id" => ^session_id,
           "tool_call_id" => ^tool_call_id,
           "request_type" => ^request_type
         } = request} ->
          {:halt, {:ok, request}}

        {:ok, _mismatched} ->
          {:cont, {:ok, nil}}

        {:error, :not_found} ->
          {:cont, {:ok, nil}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp notify(request) do
    case Application.get_env(:salix_agent, :capability_request_notifier_mod) do
      nil ->
        :ok

      mod ->
        mod.notify_capability_request(request)
    end
  rescue
    _ -> :ok
  end

  defp request_limit(nil), do: {:ok, 100}
  defp request_limit(""), do: {:ok, 100}
  defp request_limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, 500)}

  defp request_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, min(int, 500)}
      _ -> {:error, {:bad_request, "invalid limit"}}
    end
  end

  defp request_limit(_value), do: {:error, {:bad_request, "invalid limit"}}

  defp runtime_auth_page_limit(nil), do: {:ok, 50}
  defp runtime_auth_page_limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}
  defp runtime_auth_page_limit(_value), do: {:error, {:bad_request, "invalid limit"}}

  defp list_cursor(nil), do: {:ok, nil}
  defp list_cursor(""), do: {:ok, nil}
  defp list_cursor(value) when is_binary(value) and byte_size(value) <= 4_096, do: {:ok, value}
  defp list_cursor(_value), do: {:error, {:bad_request, "invalid cursor"}}

  defp get_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp list_records(prefix) do
    case S3.list_all(prefix) do
      {:ok, objects} ->
        read_records(objects)

      {:error, _} ->
        []
    end
  end

  defp read_records(objects) do
    context = SystemsObservability.Context.capture()

    objects
    |> Task.async_stream(
      fn %{key: key} ->
        SystemsObservability.Context.run(context, fn ->
          case get_record(key) do
            {:ok, rec} -> [rec]
            _ -> []
          end
        end)
      end,
      max_concurrency: @list_read_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, records} -> records end)
  end

  defp upsert_record(key, new_rec, update_fun), do: upsert_record(key, new_rec, update_fun, 5)
  defp upsert_record(_key, _new_rec, _update_fun, 0), do: {:error, :precondition_failed}

  defp upsert_record(key, new_rec, update_fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)
        updated = update_fun.(current)

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} -> {:ok, updated}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, :not_found} ->
        case S3.put(key, Jason.encode!(new_rec), if_none_match: "*") do
          {:ok, _} -> {:ok, new_rec}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # `update_record/2` for a caller that may decide, having seen the current
  # record, that there is nothing to write: the function returns `{:ok,
  # updated}` or `{:error, reason}`, and an error aborts without a write and
  # without consuming a retry.
  defp update_record_checked(key, fun), do: update_record_checked(key, fun, 5)
  defp update_record_checked(_key, _fun, 0), do: {:error, :precondition_failed}

  defp update_record_checked(key, fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)

        with {:ok, updated} <- fun.(current) do
          case S3.put(key, Jason.encode!(updated), if_match: etag) do
            {:ok, _} -> {:ok, updated}
            {:error, :precondition_failed} -> update_record_checked(key, fun, attempts - 1)
            {:error, _} = err -> err
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp update_record(key, fun), do: update_record(key, fun, 5)
  defp update_record(_key, _fun, 0), do: {:error, :precondition_failed}

  defp update_record(key, fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)
        updated = fun.(current)

        if updated == current do
          {:ok, current}
        else
          case S3.put(key, Jason.encode!(updated), if_match: etag) do
            {:ok, _} -> {:ok, updated}
            {:error, :precondition_failed} -> update_record(key, fun, attempts - 1)
            {:error, _} = err -> err
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp optional_bool(attrs, key, default) do
    case Map.get(attrs, key) do
      nil -> {:ok, default}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:bad_request, "#{key} must be a boolean"}}
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp nonblank(value), do: nonblank(value, nil)

  defp nonblank(value, default) when is_binary(value),
    do: if(trim(value) == "", do: default, else: trim(value))

  defp nonblank(nil, default), do: default
  defp nonblank(value, _default), do: value

  defp blank?(value), do: is_nil(nonblank(value))

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp request_expiry(nil), do: {:ok, now() + @default_request_ttl_seconds}
  defp request_expiry(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp request_expiry(_value),
    do: {:error, {:bad_request, "expires_at must be a positive Unix timestamp in seconds"}}

  defp now, do: System.system_time(:second)
end
