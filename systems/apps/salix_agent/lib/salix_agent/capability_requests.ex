defmodule SalixAgent.CapabilityRequests do
  @moduledoc """
  Durable capability requests raised by agent tools.

  A capability request is scoped to an agent group for storage, listing,
  streaming, and completion. The source agent/session fields are provenance and
  the target for delivering completion back into the runtime.
  """

  @behaviour SalixAgent.CapabilityRequestStore

  require Logger

  alias SalixAgent.{Control, GroupContext}
  alias SalixStore.Ids
  alias SalixAgent.CapabilityRequestStore.PG

  @callback notify_capability_request(request :: map()) :: :ok

  @default_request_ttl_seconds 120
  @receipt_result_budget_ms 30_000
  @pending_page 100
  @request_types ~w(host_access computer_use_start location oauth_authorization ifc_declassify account_link channel_link plugin_install)

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

      with {:ok, request} <-
             PG.upsert(
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
        notify(request)
        {:ok, request}
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

  @doc "A person's own location requests, across every Group (`surface_ref.requester`)."
  def location_requester_topic(requester), do: "location_requests:" <> to_string(requester)

  def list_group(group_id, tenant_id, opts \\ []) do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, limit} <- request_limit(Keyword.get(opts, :limit)) do
      PG.list_group(
        group_id,
        tenant_id,
        trim(Keyword.get(opts, :status) || "pending"),
        now(),
        limit
      )
    end
  end

  def get(group_id, request_id, tenant_id), do: find(group_id, request_id, tenant_id)

  @doc "Read every active pending Conversation request, then finished requests up to the limit."
  def list_conversation(group_id, tenant_id, conversation_id, opts \\ [])
      when is_binary(conversation_id) and conversation_id != "" do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, limit} <- request_limit(Keyword.get(opts, :limit)) do
      PG.list_conversation(group_id, tenant_id, conversation_id, now(), limit)
    end
  end

  @doc "The pending location requests a person's own message led to, at most `limit`."
  def pending_location_requests(requester, limit \\ 20) when is_binary(requester) do
    PG.pending_location(requester, now(), limit)
  end

  def due_location_requests(opts \\ []), do: PG.page_expired(opts)
  def due_result_deliveries(opts \\ []), do: PG.page_result_delivery(opts)

  def retry_result_delivery(group_id, request_id, tenant_id, opts \\ []) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         do: deliver_stored_result(request, opts)
  end

  def share_location(group_id, request_id, attrs, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "location"),
         {:ok, response} <- location_response(attrs),
         {:ok, settled} <- settle_location(request, "completed", response),
         :ok <- require_location_completion(settled) do
      # The stored ending is the answer; telling the Agent replays it if it cannot be told now.
      deliver_logged(settled)
      {:ok, settled}
    end
  end

  defp require_location_completion(%{"status" => "completed"}), do: :ok

  defp require_location_completion(_request),
    do: {:error, {:conflict, :already_settled}}

  @doc """
  Settle a due deadline (a location request's, a channel link attempt's, or a
  plugin install request's) and retry delivery of its durable outcome.
  """
  def expire_location(group_id, request_id, tenant_id, opts \\ []) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         {:ok, settled} <- expire_due(request) do
      case settled["status"] do
        status when status in ["completed", "failed", "expired"] ->
          deliver_stored_result(settled, opts)

        "cancelled" ->
          :ok
      end
    end
  end

  defp expire_due(%{"request_type" => "location"} = request) do
    response = %{"status" => "error", "error" => "Location request timed out."}
    settle_due(request, "expired", response, location_result(response))
  end

  defp expire_due(%{"request_type" => "channel_link"} = request) do
    provider = channel_link_provider(request)
    response = %{"status" => "expired", "provider" => provider}

    settle_due(
      request,
      "expired",
      response,
      failed_result(
        "channel_link_expired",
        "the #{provider} link attempt expired before the user completed it; start channel.link again if they still want it",
        response,
        "The channel link attempt expired."
      )
    )
  end

  defp expire_due(%{"request_type" => "plugin_install"} = request) do
    response = %{"status" => "expired", "plugin_id" => plugin_install_id(request)}

    settle_due(
      request,
      "expired",
      response,
      failed_result(
        "plugin_install_expired",
        "the user did not install the plugin before the request expired; ask again only if they still want it",
        response,
        "The plugin install request expired."
      )
    )
  end

  defp expire_due(_request), do: {:error, {:bad_request, "wrong capability request type"}}

  defp settle_location(request, status, response),
    do: settle_due(request, status, response, location_result(response))

  # The row revision selects the outcome before the Session receives it.
  # The same write records that its stored result still needs delivery.
  defp settle_due(request, status, response, result) do
    settled =
      update_record_checked(
        request,
        fn current ->
          cond do
            terminal?(current) ->
              {:ok, reconcile_terminal_result(current)}

            status == "completed" and expired?(current) ->
              {:error, {:bad_request, "capability request has expired"}}

            status == "expired" and not expired?(current) ->
              {:error, :not_due}

            current["status"] == "pending" ->
              {:ok, terminal_record(current, status, response, result)}

            true ->
              {:error, {:conflict, :already_settled}}
          end
        end
      )

    case settled do
      {:ok, settled} ->
        notify(settled)
        {:ok, settled}

      error ->
        error
    end
  end

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

  @doc """
  Ends the pending OAuth authorization requests a finished browser flow
  answers: the one that started it (`state`), and any other that asks for the
  same account (`provider` and `alias`), however the person connected it. The
  verified callback, not a client, is the success authority. Each waiting
  `oauth.request_authorization` call returns the binding. A flow that no
  pending request in the Group asks for ends nothing.
  """
  @spec complete_oauth_authorization(String.t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def complete_oauth_authorization(group_id, tenant_id, flow) when is_map(flow) do
    with {:ok, pending} <- list_group(group_id, tenant_id, status: "pending") do
      answered = Enum.filter(pending, &answers_oauth_flow?(&1, flow))
      account = nonblank(flow["provider_account_name"])

      # Each ending is stored before its Agent is told, and telling replays it: one Agent
      # that cannot be told now leaves no other request pending.
      ended =
        for request <- answered,
            {:ok, completed} <- [
              complete(request, connected_response(account), connected_result(request, account))
            ] do
          deliver_logged(completed)
          completed
        end

      {:ok, ended}
    end
  end

  @doc """
  The app a request's card asked for is in place: the request now waits on the
  provider's page, and the card shows it. `input` is done with.
  """
  @spec open_oauth_authorization(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def open_oauth_authorization(group_id, request_id, tenant_id, authorization_url) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "oauth_authorization"),
         {:ok, opened} <-
           update_record(request, fn current ->
             update_in(current, ["request_payload", "oauth_authorization"], fn oauth ->
               oauth
               |> Map.delete("input")
               |> Map.put("authorization_url", authorization_url)
             end)
           end) do
      notify(opened)
      {:ok, opened}
    end
  end

  @doc "A CLI login's command ended without logging in: its card says so."
  def fail_login(group_id, request_id, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id) do
      transition(request, fn current ->
        terminal_record(
          current,
          "failed",
          %{"status" => "failed"},
          failed_result(
            "login_failed",
            "the login did not finish",
            %{},
            "The login did not finish."
          )
        )
      end)
    end
  end

  defp deliver_logged(request) do
    case deliver_stored_result(request) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "capability request result not delivered: #{inspect(reason) |> String.slice(0, 200)}"
        )
    end
  end

  defp connected_response(account),
    do: put_optional(%{"status" => "connected"}, "provider_account_name", account)

  defp connected_result(request, account) do
    oauth = get_in(request, ["request_payload", "oauth_authorization"]) || %{}

    %{
      "status" => "completed",
      "provider" => oauth["provider"],
      "alias" => oauth["alias"],
      "message" => "the user connected the account"
    }
    |> put_optional("provider_account_name", account)
    |> completed_result()
  end

  defp answers_oauth_flow?(%{"request_type" => "oauth_authorization"} = request, flow) do
    oauth = get_in(request, ["request_payload", "oauth_authorization"]) || %{}

    (is_binary(flow["state"]) and oauth["state"] == flow["state"]) or
      (is_binary(flow["provider"]) and oauth["provider"] == flow["provider"] and
         oauth["alias"] == flow["alias"])
  end

  defp answers_oauth_flow?(_request, _flow), do: false

  @doc """
  A chat user linked their product account (`task_request.*` raised the
  request with the link it posted them): the waiting call returns that they
  did, and the Agent goes on with what they asked.
  """
  @spec complete_account_link(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def complete_account_link(group_id, request_id, tenant_id) do
    response = %{"status" => "linked"}

    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "account_link"),
         {:ok, completed} <-
           complete(
             request,
             response,
             completed_result(
               Map.put(
                 response,
                 "message",
                 "the requester linked their account; go on with what they asked without asking again"
               )
             )
           ) do
      deliver_logged(completed)
      {:ok, completed}
    end
  end

  @doc """
  The Group's Workspace connected a chat channel (`channel.link` raised the
  request and posted the user what to scan, open or send): every call waiting
  for that provider returns `linked` with `details`, and the Agent tells the
  user. A completion with nothing waiting is nothing.
  """
  @spec complete_channel_link(String.t(), String.t(), String.t(), map()) :: :ok
  def complete_channel_link(group_id, tenant_id, provider, details \\ %{})
      when is_binary(provider) do
    response = Map.merge(%{"status" => "linked", "provider" => provider}, details)

    result =
      completed_result(
        Map.put(
          response,
          "message",
          "the user connected #{provider}; tell them it is connected and go on with what they asked"
        )
      )

    settle_channel_links(group_id, tenant_id, provider, fn request ->
      complete(request, response, result)
    end)
  end

  @doc """
  One channel link attempt needs the Agent before it can connect (WeChat asks
  the user for a verification code): the call that waits for it returns
  `response` (a `status` other than linked) with `message` for the Agent, and
  the attempt stays open for a later call.
  """
  @spec complete_channel_link_request(String.t(), String.t(), String.t(), map(), String.t()) ::
          :ok
  def complete_channel_link_request(group_id, tenant_id, request_id, response, message)
      when is_map(response) and is_binary(message) do
    settle_channel_link(group_id, tenant_id, request_id, fn request ->
      complete(request, response, completed_result(Map.put(response, "message", message)))
    end)
  end

  @doc """
  One channel link attempt ended without connecting (its QR login expired, the
  user cancelled it in Settings, another attempt replaced it): the call that
  waits for it returns `failed` with `reason`. Other calls, waiting for other
  attempts of the same provider, go on.
  """
  @spec fail_channel_link_request(String.t(), String.t(), String.t(), String.t()) :: :ok
  def fail_channel_link_request(group_id, tenant_id, request_id, reason) when is_binary(reason) do
    settle_channel_link(group_id, tenant_id, request_id, fn request ->
      provider = channel_link_provider(request)
      response = %{"status" => "failed", "provider" => provider, "reason" => reason}

      transition(request, fn current ->
        terminal_record(
          current,
          "failed",
          response,
          failed_result(
            "channel_link_failed",
            "the #{provider} link attempt ended without connecting: #{reason}; start channel.link again if the user still wants it",
            response,
            "The channel did not connect."
          )
        )
      end)
    end)
  end

  defp settle_channel_link(group_id, tenant_id, request_id, settle) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "channel_link"),
         {:ok, settled} <- settle.(request) do
      deliver_logged(settled)
    else
      {:error, reason} ->
        Logger.warning("channel link request not settled: #{inspect(reason)}")
    end

    :ok
  end

  defp settle_channel_links(group_id, tenant_id, provider, settle) do
    case each_pending(group_id, tenant_id, "channel_link", fn request ->
           if channel_link_provider(request) == provider do
             case settle.(request) do
               {:ok, settled} -> deliver_logged(settled)
               {:error, _reason} -> :ok
             end
           end
         end) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("channel link requests not read: #{inspect(reason)}")
    end

    :ok
  end

  # Every active pending request of `type` in the Group, read in bounded pages.
  defp each_pending(group_id, tenant_id, type, fun, cursor \\ nil) do
    case PG.pending_of_type(group_id, tenant_id, type, now(), cursor, @pending_page) do
      {:ok, %{items: items, next: next}} ->
        Enum.each(items, fun)
        if next, do: each_pending(group_id, tenant_id, type, fun, next), else: :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp channel_link_provider(request),
    do: get_in(request, ["request_payload", "channel_link", "provider"])

  @doc """
  The Group's Workspace installed `plugin_id`, through any path (the card,
  the Plugins page): every `plugin.request_install` call waiting for it
  returns installed, and the Agent goes on with what the person asked. An
  install with nothing waiting is nothing.
  """
  @spec complete_plugin_install(String.t(), String.t(), String.t()) :: :ok
  def complete_plugin_install(group_id, tenant_id, plugin_id) when is_binary(plugin_id) do
    response = %{"status" => "installed", "plugin_id" => plugin_id}

    result =
      completed_result(
        Map.put(
          response,
          "message",
          "the user installed the plugin; go on with what they asked without asking again"
        )
      )

    case each_pending(group_id, tenant_id, "plugin_install", fn request ->
           if plugin_install_id(request) == plugin_id do
             case complete(request, response, result) do
               {:ok, completed} -> deliver_logged(completed)
               {:error, _reason} -> :ok
             end
           end
         end) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("plugin install requests not read: #{inspect(reason)}")
    end

    :ok
  end

  @doc "A person declines a plugin install request: the Agent's waiting call returns that they declined."
  @spec decline_plugin_install(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def decline_plugin_install(group_id, request_id, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "plugin_install"),
         {:ok, completed} <-
           complete(
             request,
             %{"status" => "declined"},
             failed_result(
               "permission_denied",
               "the user declined to install the plugin",
               %{"status" => "declined", "plugin_id" => plugin_install_id(request)},
               "The user declined to install the plugin."
             )
           ) do
      deliver_logged(completed)
      {:ok, completed}
    end
  end

  defp plugin_install_id(%{"request_type" => "plugin_install"} = request),
    do: get_in(request, ["request_payload", "plugin_install", "plugin_id"])

  defp plugin_install_id(_request), do: nil

  @doc "A person declines an OAuth authorization request: the Agent's waiting call returns that they declined."
  @spec decline_oauth_authorization(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def decline_oauth_authorization(group_id, request_id, tenant_id) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "oauth_authorization"),
         {:ok, completed} <-
           complete(
             request,
             %{"status" => "declined"},
             failed_result(
               "permission_denied",
               "the user declined to connect the account",
               %{"status" => "declined"},
               "The user declined to connect the account."
             )
           ) do
      # The stored ending is the answer; telling the Agent replays it if it cannot be told now.
      deliver_logged(completed)
      {:ok, completed}
    end
  end

  def decide_host_access(group_id, request_id, attrs, tenant_id) do
    decide_permission(group_id, request_id, attrs, tenant_id, "host_access")
  end

  @doc """
  A person's answer on a Comma request card to a phone's consent (`env.android`).
  The stored ending is the answer: the Agent that asked is told now, or when it
  can be, as for a declined account.
  """
  def answer_computer_use_start(group_id, request_id, approved, tenant_id)
      when is_boolean(approved) do
    with {:ok, request} <- find(group_id, request_id, tenant_id),
         :ok <- require_type(request, "computer_use_start"),
         {:ok, completed} <-
           complete(
             request,
             %{"approved" => approved},
             permission_result(request, approved, %{})
           ) do
      deliver_logged(completed)
      {:ok, completed}
    end
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
        request,
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
                 SystemsClock.system_time(:millisecond) + @receipt_result_budget_ms
               )}
            end

          _settled ->
            {:error, {:conflict, :already_settled}}
        end,
        settle_unknown: false
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

  defp find(group_id, request_id, tenant_id) do
    with {:ok, _group} <- GroupContext.get(group_id, tenant_id),
         {:ok, request} <- PG.get(group_id, request_id),
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
           %{"latitude" => lat, "longitude" => lng, "read_at" => read_at()}
           |> put_optional("accuracy_m", location["accuracy_m"])
       }}
    end
  end

  defp location_response(%{"status" => "error"} = attrs) do
    {:ok, %{"status" => "error", "error" => trim(attrs["error"]) || "Location unavailable"}}
  end

  defp location_response(_attrs), do: {:error, {:bad_request, "invalid location completion"}}

  defp read_at do
    SystemsClock.system_time(:second) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  defp number_value(value, _name) when is_number(value), do: {:ok, value}
  defp number_value(_value, name), do: {:error, {:bad_request, "#{name} must be a number"}}

  defp location_result(%{"status" => "success", "location" => location}) do
    completed_result(%{
      "status" => "completed",
      "location" => Map.take(location, ["latitude", "longitude", "accuracy_m", "read_at"])
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

  defp deliver_stored_result(request, opts \\ [])

  defp deliver_stored_result(%{"status" => "cancelled"}, _opts), do: :ok

  # A station's call waited for this itself (`SalixAgent.Tools.OAuth`): no Session to tell.
  defp deliver_stored_result(
         %{"request_payload" => %{"oauth_authorization" => %{"station_call" => true}}} = request,
         _opts
       ),
       do: PG.acknowledge_delivery(request)

  defp deliver_stored_result(%{"result" => result} = request, opts) when is_map(result) do
    with :ok <- deliver_async_tool_completion(request, result, opts),
         do: PG.acknowledge_delivery(request)
  end

  defp deliver_stored_result(_request, _opts), do: {:error, :capability_result_unavailable}

  defp permission_capability(%{"request_type" => type, "request_payload" => payload}) do
    get_in(payload || %{}, [type, "capability"]) || type
  end

  defp deliver_async_tool_completion(request, result, opts) do
    case SalixAgent.complete_async_tool_call(
           request["source_agent_id"],
           request["source_session_id"],
           request["tool_call_id"],
           result,
           %{
             "tool_name" => tool_name_for_request(request)
           },
           opts
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

  @doc false
  def tool_name_for_request(%{"request_type" => "location"}), do: "location.request"

  def tool_name_for_request(%{"request_type" => "oauth_authorization"}),
    do: "oauth.request_authorization"

  def tool_name_for_request(%{"request_type" => "ifc_declassify"}),
    do: "ifc.request_declassification"

  def tool_name_for_request(%{
        "request_type" => "account_link",
        "request_payload" => %{"account_link" => %{"tool_name" => name}}
      })
      when is_binary(name),
      do: name

  def tool_name_for_request(%{"request_type" => "channel_link"}), do: "channel.link"

  def tool_name_for_request(%{"request_type" => "plugin_install"}),
    do: "plugin.request_install"

  # A phone's consent (env.android) or a simulator's (env.screen): the call that asked waits for it.
  def tool_name_for_request(%{
        "request_type" => "computer_use_start",
        "request_payload" => %{"computer_use_start" => %{"tool_name" => name}}
      })
      when name in ["env.android", "env.screen"],
      do: name

  def tool_name_for_request(_request), do: "permission.request"

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
        request,
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

  @doc "Apply the request owner's deadline policy to stored legacy facts."
  def ensure_request_deadline(%{"expires_at" => deadline} = request) when is_integer(deadline),
    do: request

  def ensure_request_deadline(request) do
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
      request,
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
    not is_integer(deadline) or SystemsClock.system_time(:millisecond) >= deadline
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
    case PG.find_tool(group_id, tenant_id, agent_id, session_id, tool_call_id, @request_types) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row.record}
      error -> error
    end
  end

  defp notify(request) do
    case SystemsRuntime.get_env(:salix_agent, :capability_request_notifier_mod) do
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

  defp update_record_checked(request, fun, opts \\ []) do
    PG.update(request["group_id"], request["request_id"], fun, opts)
  end

  defp update_record(request, fun) do
    update_record_checked(request, fn current -> {:ok, fun.(current)} end)
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

  defp now, do: SystemsClock.system_time(:second)
end
