defmodule SalixIM.Triage.AuthoritativeCommit do
  @moduledoc """
  Native Triage's single authoritative terminal commit.

  The fence transition is prepared and validated in memory, then PostgreSQL
  commits the terminal fence, immutable run, immutable replay and durable
  projection obligation in one transaction. Query projections converge later.

  Compound reply/reaction materialization is modeled in
  `tla/salix/TriageCompoundCommunication.tla`.
  """

  alias SalixIM.Triage.{Bucketing, Ledger, ProductObligation, RunFence}
  alias SalixIM.Triage.RunFence.Settlement
  alias SalixStore.TriageRecordStore

  # Older sealed generations one commit may offer for archival, and the byte
  # budget for reading their fences.
  @archive_backlog 50
  @archive_backlog_bytes 4 * 1024 * 1024

  @spec settle(String.t(), String.t(), map(), map(), :result | :timeout) ::
          {:ok, Settlement.t()} | {:error, term()}
  def settle(namespace, scope, active, terminal, authority)
      when is_binary(namespace) and namespace != "" do
    with {:ok, prepared} <-
           RunFence.prepare_terminal_commit(
             namespace,
             scope,
             active,
             terminal,
             authority
           ) do
      commit_prepared(namespace, prepared)
    end
  end

  def settle(_namespace, _scope, _active, _terminal, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Atomically publishes the terminal and evidence for one open recovery fence."
  @spec recover(String.t(), map(), :deadline | :interrupted_worker) ::
          {:ok, map()} | {:error, term()}
  def recover(namespace, fence, authority)
      when is_binary(namespace) and namespace != "" and is_map(fence) and
             authority in [:deadline, :interrupted_worker] do
    with {:ok, prepared} <- RunFence.prepare_recovery_commit(namespace, fence, authority),
         {:ok, settlement} <- commit_prepared(namespace, prepared) do
      {:ok, settlement.fence}
    end
  end

  def recover(_namespace, _fence, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp commit_prepared(namespace, prepared) do
    with {:ok, projection} <- authorize_projection(namespace, prepared.fence),
         {:ok, product_obligations} <-
           prepare_product_obligation(namespace, prepared.fence_key, prepared.fence),
         {:ok, evidence} <- Ledger.prepare_authoritative(namespace, projection),
         obligation =
           evidence.obligation
           |> Map.put("namespace", namespace)
           |> Map.put("fence_key", prepared.fence_key),
         {:ok, _commit} <-
           TriageRecordStore.commit_authoritative(%{
             fence_key: prepared.fence_key,
             expected_etag: prepared.expected_etag,
             fence: prepared.fence,
             run_key: evidence.run_key,
             run: evidence.run,
             replay_key: evidence.replay_key,
             replay: evidence.replay,
             obligation: obligation,
             product_obligation: product_obligations.primary,
             companion_product_obligation: product_obligations.companion,
             archived_generations: archived_generations(namespace, prepared.fence)
           }) do
      {:ok,
       %Settlement{
         fence: prepared.fence,
         outcome: prepared.outcome,
         requested_terminal: prepared.requested_terminal
       }}
    end
  end

  # Offers this commit's generation and a bounded backlog of older settled
  # generations for archival. Storage archives only generations whose
  # committed fence is terminal and holds, or may receive, the same sealed
  # copy the bucket holds. A failed read only skips the backlog.
  defp archived_generations(namespace, fence) do
    current = fence["generation"]

    own =
      case fence["sealed_generation"] do
        %{"generation" => ^current} = sealed -> [archive_entry(sealed, nil)]
        _missing -> []
      end

    own ++ settled_backlog(namespace, fence["bucket_scope"], current)
  end

  defp settled_backlog(namespace, scope, current) do
    with {:ok, %{"sealed_generations" => [_ | _] = sealed}} <- Bucketing.load(namespace, scope),
         candidates =
           sealed
           |> Enum.reject(&(&1["generation"] == current or not is_binary(&1["generation"])))
           |> Enum.take(@archive_backlog),
         true <- candidates != [],
         keys =
           Enum.map(
             candidates,
             &SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, &1["generation"])
           ),
         {:ok, fences} <- TriageRecordStore.get_bounded_many(keys, @archive_backlog_bytes) do
      candidates
      |> Enum.zip(keys)
      |> Enum.flat_map(fn {sealed, key} ->
        case settled_fence(fences[key]) do
          %{"sealed_generation" => ^sealed} ->
            [archive_entry(sealed, nil)]

          %{} = fence when not is_map_key(fence, "sealed_generation") ->
            case RunFence.attach_sealed_generation(fence, sealed) do
              {:ok, _archived} -> [archive_entry(sealed, sealed)]
              :error -> []
            end

          _unsettled ->
            []
        end
      end)
    else
      _unavailable -> []
    end
  end

  defp settled_fence({:ok, %{body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"terminal" => terminal} = fence} when is_map(terminal) -> fence
      _other -> nil
    end
  end

  defp settled_fence(_missing), do: nil

  defp archive_entry(sealed, attach) do
    sources =
      for %{"receipt_ref" => ref} = receipt when is_binary(ref) <- sealed["receipts"] || [],
          into: %{},
          do: {ref, SalixStore.Crypto.hex(Bucketing.source_key(receipt))}

    %{generation: sealed["generation"], sources: sources, attach: attach}
  end

  defp authorize_projection(namespace, %{"schema" => "comma.triage-bucket-fence.v2"} = fence),
    do: RunFence.authorize_projection_from_storage(namespace, fence)

  defp authorize_projection(_namespace, %{"schema" => "comma.triage-bucket-fence.v1"} = fence),
    do: {:ok, fence}

  defp authorize_projection(_namespace, _fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp prepare_product_obligation(
         namespace,
         fence_key,
         %{
           "terminal" => %{
             "status" => "evaluated",
             "decision" => %{"schema" => schema}
           }
         } = fence
       )
       when schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] do
    with {:ok, authorization} <-
           RunFence.authorize_product_effects_from_storage(namespace, fence),
         {:ok, obligations} <-
           ProductObligation.prepare_all(namespace, fence_key, authorization) do
      {:ok, obligations}
    end
  end

  defp prepare_product_obligation(_namespace, _fence_key, _fence),
    do: {:ok, %{primary: nil, companion: nil}}
end
