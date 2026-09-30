defmodule SalixIM.Triage.Admission do
  @moduledoc """
  Projects one current typed Slack receipt into the durable Triage bucket.

  The immutable S3 receipt is authoritative and must exist first. PostgreSQL
  then projects its exact body, source aliases, membership, and bucket in one
  transaction; a final authority read prevents work admitted across a connect
  rotation from being accepted as current. Ambient admission has one global
  source winner, while directed admission is independently unique per stable
  recipient, so another connect's ambient win cannot suppress an explicit
  address.

  Modeled in `tla/salix/TriageReceiptAdmission.tla`.
  """

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.Bucketing
  alias SalixIM.{ProviderConnects, ProviderReceipts}
  alias SalixStore.TriageRecordStore

  def accept(namespace, authority, receipt) do
    with {:ok, status, _durable} <- accept_membership(namespace, authority, receipt),
         do: {:ok, status}
  end

  @doc """
  Same admission, additionally returning the durable bucket the receipt landed in.

  The admission transaction already returned that record, so an engine that
  wants to arm the receipt's debounce window need not issue another storage
  read. `nil` means the receipt took no membership at all.
  """
  @spec accept_membership(String.t(), map(), map()) ::
          {:ok, :accepted | :duplicate, map() | nil} | {:error, term()}
  def accept_membership(namespace, authority, receipt)
      when is_binary(namespace) and is_map(authority) and is_map(receipt) do
    with :ok <- ProviderConnects.verify_slack_triage_authority(authority),
         {:ok, receipt} <- ProviderReceipts.normalize_slack_triage_receipt(receipt),
         :ok <- ProviderReceipts.verify_slack_triage_receipt(authority, receipt),
         :ok <- Bucketing.validate_receipt(receipt),
         {:ok, lane} <- admission_lane(authority, receipt),
         {:ok, status, durable} <- admit(namespace, authority, receipt, lane),
         :ok <- ProviderConnects.verify_slack_triage_authority(authority) do
      {:ok, status, durable}
    end
  end

  def accept_membership(_namespace, _authority, _receipt),
    do: {:error, :invalid_triage_admission}

  defp admit(namespace, authority, receipt, lane) do
    admission = %{
      namespace: namespace,
      physical_source: Bucketing.source_key(receipt),
      recipient: authority["connect_id"],
      bucket_identity: Bucketing.scope_key(receipt),
      lane: lane,
      receipt: receipt
    }

    case TriageRecordStore.admit_receipt(admission) do
      {:ok, %{status: status, durable: durable}} ->
        {:ok, status, durable}

      # Fault-injection suites deliberately replace the native PostgreSQL
      # adapter with the S3 fake. Keep that explicit test seam on the legacy
      # CAS projection; production's default adapter always takes the atomic
      # transaction above.
      {:error, :unsupported} ->
        admit_compatibility(namespace, receipt)

      {:error, _reason} = error ->
        error
    end
  end

  defp admit_compatibility(namespace, receipt) do
    with {:ok, projection_status, alias_status} <- Bucketing.claim_receipt(namespace, receipt),
         {:ok, _membership, durable} <- maybe_append(namespace, receipt, alias_status) do
      {:ok, admission_status(projection_status, alias_status), durable}
    end
  end

  defp maybe_append(namespace, receipt, :canonical),
    do: Bucketing.append_membership(namespace, receipt)

  defp maybe_append(_namespace, _receipt, :superseded), do: {:ok, :superseded, nil}

  defp admission_status(:accepted, :canonical), do: :accepted
  defp admission_status(:duplicate, :canonical), do: :duplicate
  defp admission_status(_projection_status, :superseded), do: :duplicate

  defp admission_lane(_authority, %{"triage_event" => %{"addressing_kind" => "ambient"}}),
    do: {:ok, :ambient}

  defp admission_lane(
         authority,
         %{"triage_event" => %{"addressing_kind" => "directed"} = event}
       ) do
    scope = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => get_in(event, ["bucket", "channel_id"]),
      "root_thread_ts" => get_in(event, ["bucket", "thread_ts"])
    }

    case ThreadRouteOwner.lookup(scope) do
      {:ok, :triage} -> {:ok, :both}
      {:ok, owner} when owner in [:legacy, :assistant, :task] -> {:ok, :directed}
      {:owned_elsewhere, _owner} -> {:ok, :directed}
      :unbound -> {:ok, :directed}
      _unavailable -> {:error, :triage_admission_unavailable}
    end
  end

  defp admission_lane(_authority, _receipt), do: {:error, :invalid_triage_admission}
end
