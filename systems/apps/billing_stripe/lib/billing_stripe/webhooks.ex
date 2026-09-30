defmodule BillingStripe.Webhooks do
  @moduledoc """
  Stripe webhook signature verification and transactional journal processing.

  Crash/retry and acknowledgement safety are modeled in
  `tla/billing/WebhookJournal.tla`.
  """

  alias BillingStripe.Events

  @spec handle_webhook(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_webhook(payload, signature_header, opts \\ [])
      when is_binary(payload) and is_binary(signature_header) do
    BillingStripe.Telemetry.observe(:stripe_webhook, "system", fn ->
      do_handle_webhook(payload, signature_header, opts)
    end)
  end

  defp do_handle_webhook(payload, signature_header, opts) do
    secret = Keyword.get(opts, :secret) || Application.get_env(:billing_stripe, :webhook_secret)

    with {:ok, event} <- verify(payload, signature_header, secret, opts),
         :ok <- journal_event(event, payload),
         {:ok, {result, duplicate?}} <- process_journaled(event) do
      {:ok, %{event: event, result: result, idempotent: duplicate?}}
    end
  end

  @spec verify(binary(), binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(payload, signature_header, secret, opts \\ [])

  def verify(_payload, _signature_header, secret, _opts)
      when not is_binary(secret) or secret == "",
      do: {:error, :stripe_webhook_not_configured}

  def verify(payload, signature_header, secret, opts) do
    tolerance = Keyword.get(opts, :tolerance, 300)

    api = Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)

    with {:ok, event} <-
           api.construct_webhook_event(
             payload,
             signature_header,
             secret,
             tolerance,
             Keyword.drop(opts, [:secret, :now, :tolerance])
           ) do
      {:ok, stringify_event(event)}
    else
      {:error, reason} -> {:error, verify_error(reason)}
    end
  end

  defp journal_event(%{"id" => id, "type" => type} = event, payload) do
    repo = Application.fetch_env!(:billing_stripe, :repo)
    sql = Ecto.Adapters.SQL
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    object = get_in(event, ["data", "object"]) || %{}

    sql.query!(
      repo,
      """
      INSERT INTO billing_stripe_events (
        id,
        payload_digest,
        event_type,
        object_id,
        object_type,
        status,
        inserted_at,
        updated_at
      ) VALUES ($1, $2, $3, $4, $5, 'processing', now(), now())
      ON CONFLICT (id) DO NOTHING
      """,
      [id, digest, type, object["id"], object["object"] || object["type"]]
    )

    :ok
  end

  defp process_journaled(event) do
    repo = Application.fetch_env!(:billing_stripe, :repo)

    # The journal survives a request crash, but its business effects and the
    # processed marker commit together. A concurrent retry waits on this row;
    # processing/failed rows are retryable without a lease or a recovery worker.
    result =
      repo.transaction(fn ->
        %{rows: [[status]]} =
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT status FROM billing_stripe_events WHERE id = $1 FOR UPDATE",
            [event["id"]]
          )

        if status == "processed" do
          {%{duplicate: true}, true}
        else
          case safe_process(event) do
            {:ok, result} ->
              mark_event(repo, event["id"], "processed", nil)
              {result, false}

            {:error, reason} ->
              repo.rollback(reason)
          end
        end
      end)

    case result do
      {:ok, {_result, false}} = ok ->
        project_stripe_event(event, "stripe_event_processed", "processed", nil)
        ok

      {:ok, {_result, true}} = ok ->
        ok

      {:error, reason} ->
        error = inspect(reason)
        mark_event(repo, event["id"], "failed", error)
        project_stripe_event(event, "stripe_event_failed", "failed", error)
        {:error, reason}
    end
  end

  defp safe_process(event) do
    Events.process(event)
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  end

  defp mark_event(repo, id, status, error) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_stripe_events
      SET status = $2,
          error = $3,
          processed_at = CASE WHEN $2 = 'processed' THEN now() ELSE processed_at END,
          updated_at = now()
      WHERE id = $1 AND status != 'processed'
      """,
      [id, status, error]
    )
  end

  defp project_stripe_event(event, event_kind, status, reason) do
    object = get_in(event, ["data", "object"]) || %{}
    metadata = Events.billing_metadata(object)

    BillingCommerce.Projection.emit(%{
      source_key: "stripe:#{event["id"]}:#{status}",
      occurred_at: DateTime.utc_now(),
      surface: metadata["surface"] || "unknown",
      billing_account_id: metadata["billing_account_id"] || "unknown",
      product_owner_type: metadata["product_owner_type"] || "unknown",
      product_owner_id: metadata["product_owner_id"] || "unknown",
      event_kind: event_kind,
      source_type: "stripe_event",
      source_id: event["id"],
      source_event_id: event["id"],
      idempotency_key: "stripe:event:#{event["id"]}",
      package_code: metadata["package_code"],
      package_version: metadata["package_version"],
      status: status,
      reason: reason,
      provider: "stripe",
      provider_event_id: event["id"],
      metadata: %{"event_type" => event["type"], "object_id" => object["id"]}
    })
  end

  defp stringify_event(%_{} = event), do: event |> Map.from_struct() |> stringify_event()

  defp stringify_event(%{} = event) do
    Map.new(event, fn {key, value} -> {to_string(key), stringify_event(value)} end)
  end

  defp stringify_event(values) when is_list(values), do: Enum.map(values, &stringify_event/1)

  defp stringify_event(value), do: value

  defp verify_error(reason)
       when reason in [:invalid_signature, :invalid_signature_header, :stale_signature],
       do: reason

  defp verify_error(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "Timestamp outside the tolerance zone") ->
        :stale_signature

      String.contains?(reason, "Unable to extract timestamp") ->
        :invalid_signature_header

      String.contains?(reason, "No signatures found with expected scheme") ->
        :invalid_signature_header

      String.contains?(reason, "No signatures found matching") ->
        :invalid_signature

      true ->
        reason
    end
  end

  defp verify_error(reason), do: reason
end
