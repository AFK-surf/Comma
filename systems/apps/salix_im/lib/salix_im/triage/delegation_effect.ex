defmodule SalixIM.Triage.DelegationEffect do
  @moduledoc """
  Applies bounded Triage delegations through the canonical Task owner.

  Source authority and cited versions are checked around target preparation.
  Ordinary assignments read new messages in the Worker before public effects.
  The immutable obligation and ordinal identify one Task across retries.
  New selected-Worker decisions return created with that Task identity.
  Historical Router handoffs retain routed receipts, which do not prove creation.

  Protocol anchor: `tla/salix/TriageProductEffect.tla`.
  """

  alias SalixIM.Ports.TriageDelegation
  alias SalixIM.Triage.SlackEffectAdapter.Freshness

  @type result ::
          {:ok, [map()]}
          | {:error, term(), boolean(), [map()]}

  @spec apply(map(), keyword()) :: result()
  def apply(claim, opts \\ [])

  def apply(%{obligation_id: obligation_id, payload: payload} = claim, opts)
      when is_binary(obligation_id) and is_map(payload) and is_list(opts) do
    freshness_port = Keyword.get(opts, :freshness_port, Freshness)
    delegation_port = Keyword.get(opts, :delegation_port, TriageDelegation)
    port_opts = Keyword.get(opts, :port_opts, [])

    payload
    |> Map.get("delegations", [])
    |> normalize_delegations()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {delegation, index}, {:ok, acc} ->
      case execute_one(
             claim,
             delegation,
             index,
             freshness_port,
             delegation_port,
             port_opts
           ) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        {:error, reason, retryable?, result} ->
          {:halt, {:error, reason, retryable?, Enum.reverse([result | acc])}}
      end
    end)
    |> reverse_success()
  end

  def apply(_claim, _opts), do: {:error, :invalid_product_obligation, false, []}

  defp normalize_delegations(delegations) when is_list(delegations), do: delegations
  defp normalize_delegations(_delegations), do: []

  defp execute_one(
         claim,
         %{"task" => task} = delegation,
         index,
         freshness_port,
         delegation_port,
         port_opts
       )
       when is_binary(task) and task != "" do
    request_id = "triage-delegation:#{claim.obligation_id}:#{index}"
    # Only the materializer's domain-assignment marker permits current-source
    # intake. Public effects and historical model decisions keep strict checks.
    port_opts = Keyword.put(port_opts, :purpose, :worker_intake)

    with {:ok, %{status: :fresh} = first} <- freshness_port.check(claim, port_opts),
         {:ok, prepared} <- delegation_port.prepare(claim, delegation, request_id),
         {:ok, %{status: :fresh} = second} <- freshness_port.check(claim, port_opts),
         true <- same_authority?(first, second),
         {:ok, receipt} <- delegation_port.commit(prepared) do
      delegation_receipt(receipt, request_id, index, delegation)
    else
      {:ok, %{status: :stale, reason: reason}} ->
        {:ok, suppressed(index, delegation, reason)}

      false ->
        {:ok, suppressed(index, delegation, :authority_changed_during_prepare)}

      {:error, reason, retryable?} when is_boolean(retryable?) ->
        result = blocked(index, delegation, reason, retryable?)

        if retryable?,
          do: {:error, reason, true, result},
          else: {:ok, result}

      {:error, reason} ->
        retryable? = retryable_error?(reason)
        result = blocked(index, delegation, reason, retryable?)

        if retryable?,
          do: {:error, reason, true, result},
          else: {:ok, result}

      _other ->
        {:error, :delegation_unavailable, true,
         blocked(index, delegation, :delegation_unavailable, true)}
    end
  rescue
    _exception ->
      {:error, :delegation_unavailable, true,
       blocked(index, delegation, :delegation_unavailable, true)}
  catch
    :exit, _reason ->
      {:error, :delegation_unavailable, true,
       blocked(index, delegation, :delegation_unavailable, true)}
  end

  defp execute_one(_claim, delegation, index, _freshness, _port, _opts),
    do: {:ok, blocked(index, delegation, :invalid_delegation, false)}

  defp reverse_success({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_success(other), do: other

  defp delegation_receipt(
         %{
           "disposition" => "created",
           "request_id" => request_id,
           "conversation_id" => conversation_id,
           "worker_agent_id" => worker_id
         },
         request_id,
         index,
         delegation
       )
       when is_binary(conversation_id) and is_binary(worker_id),
       do:
         {:ok,
          %{
            "index" => index,
            "status" => "created",
            "conversation_id" => conversation_id,
            "worker_agent_id" => worker_id,
            "source_count" => source_count(delegation)
          }}

  defp delegation_receipt(
         %{"disposition" => "routed", "request_id" => request_id},
         request_id,
         index,
         delegation
       ),
       do:
         {:ok,
          %{"index" => index, "status" => "routed", "source_count" => source_count(delegation)}}

  defp delegation_receipt(_receipt, _request_id, index, delegation),
    do:
      {:error, :invalid_delegation_receipt, false,
       blocked(index, delegation, :invalid_delegation_receipt, false)}

  defp suppressed(index, delegation, reason),
    do: %{
      "index" => index,
      "status" => "suppressed_stale",
      "reason" => safe_reason(reason),
      "source_count" => source_count(delegation)
    }

  defp blocked(index, delegation, reason, retryable?),
    do: %{
      "index" => index,
      "status" => if(retryable?, do: "retry_scheduled", else: "proposed"),
      "reason" => safe_reason(reason),
      "source_count" => source_count(delegation)
    }

  defp source_count(%{"source_refs" => refs}) when is_list(refs), do: length(refs)
  defp source_count(_delegation), do: 0

  defp same_authority?(left, right), do: left.authority_ref == right.authority_ref

  defp retryable_error?(reason),
    do:
      reason in [
        :source_unavailable,
        :source_authority_unavailable,
        :slack_triage_authority_unavailable,
        :task_create_unavailable,
        :timeout,
        :unavailable
      ] or match?({:rate_limited, _}, reason)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "delegation_unavailable"
end
