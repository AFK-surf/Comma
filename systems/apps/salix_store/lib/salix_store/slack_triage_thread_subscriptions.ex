defmodule SalixStore.SlackTriageThreadSubscriptions do
  @moduledoc """
  Immutable, generation-fenced continuation admissions created by confirmed
  BFT Triage replies.

  A row proves only that Comma successfully replied once on this exact Slack
  thread under this exact provider generation and agent. It is a bounded
  Slack-ingress index, not Conversation state, a scheduler, a reply policy, or
  a second runtime. Callers must additionally pin the current provider
  authority and the `:triage` thread-route owner before admitting an ordinary
  human reply.

  The fact is append-only for one exact scope. Evaluator silence does not
  mutate it: admitted replies still pass through the normal evaluator, which
  may reply, stay silent, collect context, delegate, or schedule follow-up.
  Disablement, generation rotation, or route-owner drift makes the old exact
  row ineligible without a subscription lifecycle of its own.

  See `tla/salix/SlackTriageThreadSubscription.tla` for the executable
  provider-success, retry, generation, author, and admission invariants.
  """

  alias SalixStore.{Ids, Repo, ULID}

  @scope_keys ~w(
    tenant_id group_id connect_id connect_generation workspace_id channel_id
    root_thread_ts agent_id
  )
  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{6}\z/
  @obligation_id ~r/\Atriage-product-[0-9a-f]{64}\z/
  @provider_message_ref ~r/\Aslack:[0-9]{1,12}\.[0-9]{6}\z/

  @type activation_status :: :created | :existing

  @doc "Creates one exact admission; every later activation is an immutable no-op."
  @spec activate(map(), map()) ::
          {:ok, activation_status()} | {:error, :invalid | :unavailable}
  def activate(scope, provenance) when is_map(scope) and is_map(provenance) do
    with {:ok, scope} <- validate_scope(scope),
         {:ok, obligation_id, message_id, provider_message_ref} <-
           validate_provenance(provenance),
         {:ok, result} <-
           Repo.query(
             activate_sql(),
             values(scope) ++ [obligation_id, message_id, provider_message_ref]
           ) do
      case result.rows do
        [[1]] -> {:ok, :created}
        [] -> confirm_existing(scope)
      end
    else
      {:error, :invalid} = error -> error
      _other -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def activate(_scope, _provenance), do: {:error, :invalid}

  @doc "Reads the exact immutable admission without renewing or changing it."
  @spec status(map()) ::
          {:ok, :active} | {:error, :invalid | :not_found | :unavailable}
  def status(scope) when is_map(scope) do
    with {:ok, scope} <- validate_scope(scope),
         {:ok, result} <- Repo.query(status_sql(), values(scope)) do
      case result.rows do
        [[1]] -> {:ok, :active}
        [] -> {:error, :not_found}
      end
    else
      {:error, :invalid} = error -> error
      _other -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def status(_scope), do: {:error, :invalid}

  @doc "Builds the exact scope carried by a product obligation."
  @spec product_scope(map(), map()) :: {:ok, map()} | {:error, :invalid}
  def product_scope(target, identity) when is_map(target) and is_map(identity) do
    group_id = identity["project_salix_group_id"]
    agent_id = identity["salix_agent_id"]

    if Ids.valid_group_id?(group_id) and Ids.valid_agent_id_for_group?(agent_id, group_id) do
      scope = %{
        "tenant_id" => Ids.tenant_id_from_group!(group_id),
        "group_id" => group_id,
        "connect_id" => target["connect_id"],
        "connect_generation" => target["connect_generation"],
        "workspace_id" => target["workspace_id"],
        "channel_id" => target["channel_id"],
        "root_thread_ts" => target["thread_ts"],
        "agent_id" => agent_id
      }

      validate_scope(scope)
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  end

  def product_scope(_target, _identity), do: {:error, :invalid}

  defp confirm_existing(scope) do
    case status(scope) do
      {:ok, :active} -> {:ok, :existing}
      _missing_or_unavailable -> {:error, :unavailable}
    end
  end

  defp activate_sql do
    """
    INSERT INTO slack_triage_thread_subscriptions (
      tenant_id, group_id, connect_id, connect_generation, workspace_id,
      channel_id, root_thread_ts, agent_id,
      activated_by_obligation_id, activated_by_message_id,
      activated_by_provider_message_ref,
      inserted_at, updated_at
    ) VALUES (
      $1, $2, $3, $4, $5, $6, $7, $8,
      $9, $10, $11, statement_timestamp(), statement_timestamp()
    )
    ON CONFLICT (
      tenant_id, group_id, connect_id, connect_generation, workspace_id,
      channel_id, root_thread_ts, agent_id
    ) DO NOTHING
    RETURNING 1
    """
  end

  defp status_sql do
    """
    SELECT 1
    FROM slack_triage_thread_subscriptions
    WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3
      AND connect_generation = $4 AND workspace_id = $5 AND channel_id = $6
      AND root_thread_ts = $7 AND agent_id = $8
    """
  end

  defp validate_scope(scope) do
    if Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and
         Ids.valid_tenant_id?(scope["tenant_id"]) and
         Ids.valid_group_id_for_tenant?(scope["group_id"], scope["tenant_id"]) and
         canonical_nonblank?(scope["connect_id"]) and
         ULID.valid?(scope["connect_generation"]) and
         canonical_nonblank?(scope["workspace_id"]) and
         canonical_nonblank?(scope["channel_id"]) and
         is_binary(scope["root_thread_ts"]) and
         Regex.match?(@slack_ts, scope["root_thread_ts"]) and
         Ids.valid_agent_id_for_group?(scope["agent_id"], scope["group_id"]) do
      {:ok, scope}
    else
      {:error, :invalid}
    end
  end

  defp validate_provenance(%{"obligation_id" => obligation_id} = provenance) do
    message_id = provenance["message_id"]
    provider_message_ref = provenance["provider_message_ref"]

    valid_reference? =
      case {message_id, provider_message_ref} do
        {message_id, nil} ->
          Ids.valid_message_id?(message_id)

        {nil, provider_message_ref} ->
          is_binary(provider_message_ref) and
            Regex.match?(@provider_message_ref, provider_message_ref)

        _other ->
          false
      end

    if Map.keys(provenance) -- ~w(obligation_id message_id provider_message_ref) == [] and
         is_binary(obligation_id) and Regex.match?(@obligation_id, obligation_id) and
         valid_reference?,
       do: {:ok, obligation_id, message_id, provider_message_ref},
       else: {:error, :invalid}
  end

  defp validate_provenance(_provenance), do: {:error, :invalid}

  defp values(scope), do: Enum.map(@scope_keys, &Map.fetch!(scope, &1))

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)
end
