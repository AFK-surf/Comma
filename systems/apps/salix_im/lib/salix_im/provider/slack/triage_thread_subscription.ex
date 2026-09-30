defmodule SalixIM.Provider.Slack.TriageThreadSubscription do
  @moduledoc """
  Converts one provider-confirmed direct Triage reply into an immutable Slack
  thread-continuation admission used by callback routing.

  The Triage product-effect claim owns provider delivery and local completion.
  `after_reply/3` runs only after Slack confirms the exact reply. If the
  admission store is temporarily unavailable, the product obligation remains
  retryable; the next attempt first recovers the existing Slack message by its
  operation reference and retries only this local completion. Router
  Conversation state is never read or mutated by this protocol.

  The provider-success/admission boundary and its failure mutations are modeled
  in `tla/salix/SlackTriageThreadSubscription.tla`.
  """

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixStore.{Crypto, SlackTriageThreadSubscriptions}

  @route_scope_keys ~w(
    tenant_id group_id connect_id connect_generation workspace_id channel_id root_thread_ts
  )
  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{6}\z/

  @doc "Activates the exact continuation admission after a direct Slack reply succeeds."
  def after_reply(claim, result, opts \\ [])

  def after_reply(
        %{obligation_id: obligation_id, payload: payload},
        {:ok, status} = result,
        opts
      )
      when is_binary(obligation_id) and obligation_id != "" and is_map(payload) and
             is_map(status) and is_list(opts) do
    owner_port = Keyword.get(opts, :owner_port, ThreadRouteOwner)
    store_port = Keyword.get(opts, :store_port, SlackTriageThreadSubscriptions)

    context_port =
      Keyword.get(opts, :continuation_context_port, SalixIM.Triage.RouterContextProjection)

    with {:ok, scope, route_scope, provenance} <-
           subscription_identity(obligation_id, payload, status, store_port),
         :ok <- ensure_triage_owner(owner_port, route_scope, provenance),
         :ok <-
           context_port.deliver_participation(
             %{obligation_id: obligation_id, payload: payload},
             status,
             opts
           ),
         :ok <- SalixIM.Triage.Investigation.join_task(%{payload: payload}),
         {:ok, _subscription} <- store_port.activate(scope, provenance) do
      result
    else
      {:skip, _foreign_owner} ->
        result

      {:error, :invalid} ->
        {:unknown, %{"status" => "triage_subscription_contract_invalid"}, :invalid_subscription}

      {:error, reason} ->
        completion_later(result, reason)

      _other ->
        completion_later(result, :unknown)
    end
  rescue
    _exception -> completion_later(result, :exception)
  catch
    :exit, _reason -> completion_later(result, :exit)
  end

  def after_reply(_claim, {:ok, _status}, _opts),
    do: {:unknown, %{"status" => "triage_subscription_contract_invalid"}, :invalid_subscription}

  def after_reply(_claim, result, _opts), do: result

  @doc "Returns a local-completion retry while preserving confirmed provider success."
  def completion_later({:ok, status}, reason) do
    {:completion_later, {:ok, json_status(status)},
     {:triage_subscription_unavailable, safe_reason(reason)}}
  end

  @doc "Checks whether a confirmed Triage reply admits ordinary conversation continuation."
  @spec admission(map(), map(), keyword()) :: :admit | :ignore | {:error, :unavailable}
  def admission(authority, route_scope, opts \\ [])

  def admission(authority, route_scope, opts)
      when is_map(authority) and is_map(route_scope) and is_list(opts) do
    store_port = Keyword.get(opts, :store_port, SlackTriageThreadSubscriptions)

    with true <- route_matches_authority?(route_scope, authority),
         {:ok, scope} <-
           store_port.product_scope(
             %{
               "connect_id" => authority["connect_id"],
               "connect_generation" => authority["connect_generation"],
               "workspace_id" => authority["workspace_id"],
               "channel_id" => authority["approved_channel_id"],
               "thread_ts" => route_scope["root_thread_ts"]
             },
             %{
               "project_salix_group_id" => authority["group_id"],
               "salix_agent_id" => authority["inbound_agent_id"]
             }
           ) do
      case store_port.status(scope) do
        {:ok, :active} -> :admit
        {:error, :not_found} -> :ignore
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      _invalid_or_drift -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def admission(_authority, _route_scope, _opts), do: {:error, :unavailable}

  def continuation(connect, route_scope, opts \\ []) do
    authority = Map.put(connect, "approved_channel_id", route_scope["channel_id"])
    admission(authority, route_scope, opts)
  end

  defp subscription_identity(obligation_id, payload, status, store_port) do
    target = payload["target"] || %{}
    identity = payload["product_identity"] || %{}
    channel_id = status_value(status, "channel")
    message_ts = status_value(status, "ts")

    provenance = %{
      "obligation_id" => obligation_id,
      "provider_message_ref" => "slack:" <> to_string(message_ts || "")
    }

    with true <- canonical_nonblank?(payload["run_id"]),
         true <- channel_id == target["channel_id"],
         true <- is_binary(message_ts) and Regex.match?(@slack_ts, message_ts),
         {:ok, scope} <- store_port.product_scope(target, identity) do
      {:ok, scope, Map.take(scope, @route_scope_keys), provenance}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp ensure_triage_owner(owner_port, route_scope, provenance) do
    case owner_port.lookup(route_scope) do
      {:ok, :triage} ->
        :ok

      :unbound ->
        claim_identity =
          Crypto.hex([
            "comma.slack-triage-provider-confirmed-owner.v2",
            <<0>>,
            Enum.map_join(@route_scope_keys, <<0>>, &Map.fetch!(route_scope, &1)),
            <<0>>,
            provenance["obligation_id"],
            <<0>>,
            provenance["provider_message_ref"]
          ])

        case owner_port.claim_triage(route_scope, claim_identity) do
          {:ok, :triage} -> :ok
          {:conflict, _owner} -> {:skip, :foreign_owner}
          _unavailable -> {:error, :owner_unavailable}
        end

      {:ok, _foreign_owner} ->
        {:skip, :foreign_owner}

      {:owned_elsewhere, _foreign_owner} ->
        {:skip, :foreign_owner}

      _unavailable ->
        {:error, :owner_unavailable}
    end
  end

  defp route_matches_authority?(route_scope, authority) do
    route_scope == %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => route_scope["root_thread_ts"]
    }
  end

  defp status_value(status, "channel"), do: status["channel"] || status[:channel]
  defp status_value(status, "ts"), do: status["ts"] || status[:ts]

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :unknown

  defp json_status(status)
       when is_binary(status) or is_number(status) or is_boolean(status) or is_nil(status),
       do: status

  defp json_status(status) when is_atom(status), do: Atom.to_string(status)
  defp json_status(status) when is_map(status) or is_list(status), do: status
  defp json_status(_status), do: "delivered"

  defp canonical_nonblank?(value),
    do: is_binary(value) and value != "" and value == String.trim(value)
end
