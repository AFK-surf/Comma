defmodule Comma.AgentPolicies do
  @moduledoc "Conversation policy checks before runtime delivery."

  alias BillingCore.FeeControl.Request

  def authorize_send(workspace, conversation, session, attrs) do
    operation_id =
      [conversation["id"], attrs["client_request_id"] || attrs[:client_request_id]]
      |> Enum.map(&to_string/1)
      |> Enum.join(":")

    with :ok <- allowed_tools?(session, attrs),
         {:ok, updated_session} <- Comma.Accounts.consume_budget(session, operation_id),
         {:ok, fee_check} <- authorize_fee_control(workspace, conversation) do
      {:ok, %{session: updated_session, fee_control: fee_check}}
    end
  end

  defp allowed_tools?(%{"restricted" => true, "tool_allowlist" => allowlist}, attrs)
       when is_list(allowlist) and allowlist != [] do
    requested = attrs["requested_tools"] || attrs[:requested_tools] || []

    if requested != [] and Enum.all?(requested, &(&1 in allowlist)) do
      :ok
    else
      {:error, :tool_not_allowed}
    end
  end

  defp allowed_tools?(_session, _attrs), do: :ok

  defp authorize_fee_control(workspace, conversation) do
    if Comma.Salix.Client.conversation_uses_private_model?(workspace, conversation) do
      {:ok, %{allowed?: true, reason: "tenant_credentials"}}
    else
      authorize_platform_fee_control(workspace, conversation)
    end
  end

  defp authorize_platform_fee_control(workspace, conversation) do
    billing_context = get_in(conversation, ["internal", "billing_context"]) || %{}

    if SalixAgent.AccountPool.agent_uses_pool?(
         billing_context["salix_agent_id"],
         billing_context["salix_tenant_id"]
       ) do
      {:ok, %{allowed?: true, reason: "tenant_account_pool"}}
    else
      with {:ok, free?} <- Comma.Billing.RouterModels.free_conversation?(workspace, conversation) do
        authorize_platform_fee(workspace, billing_context, free?)
      end
    end
  end

  defp authorize_platform_fee(workspace, billing_context, free?) do
    request = %Request{
      billing_account_id: billing_context["billing_account_id"],
      provider: "runtime",
      sku: "llm",
      resource_kind: :llm,
      action: :start,
      mode: :enforce,
      estimated_credits: if(free?, do: 0, else: workspace["estimated_request_credits"] || 1),
      balance_snapshot: workspace["billing_balance_snapshot"] || 0,
      row_context: %{
        "billing_account_id" => billing_context["billing_account_id"],
        "surface" => billing_context["surface"],
        "product_owner_type" => billing_context["product_owner_type"],
        "product_owner_id" => billing_context["product_owner_id"],
        "tenant_id" => billing_context["salix_tenant_id"],
        "group_id" => billing_context["salix_group_id"],
        "entrypoint" => billing_context["entrypoint"],
        "actor_type" => billing_context["actor_type"]
      }
    }

    result =
      case safe_fee_control(request) do
        {:ok, result} -> result
        {:error, reason} -> fee_control_fallback(request, reason)
      end

    notify_fee_control(result, billing_context)

    if result.allowed? do
      {:ok, result}
    else
      {:error, {:billing_unavailable, result}}
    end
  end

  defp safe_fee_control(%Request{} = request) do
    BillingCore.FeeControl.authorize(request)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fee_control_fallback(%Request{} = request, reason) do
    %{
      mode: :enforce,
      allowed?: false,
      would_block: true,
      cache_hit: false,
      cache_age_ms: nil,
      cache_ttl_ms: nil,
      query_performed: false,
      query_duration_ms: 0,
      balance_snapshot: nil,
      provider: request.provider,
      sku: request.sku,
      resource_kind: request.resource_kind,
      action: request.action,
      reason: "fee_control_error",
      error: inspect(reason)
    }
  end

  defp notify_fee_control(result, billing_context) do
    case Application.get_env(:comma_core, :fee_control_observer) do
      observer when is_pid(observer) ->
        send(observer, {:comma_fee_control_check, result, billing_context})

      _ ->
        :ok
    end
  end
end
