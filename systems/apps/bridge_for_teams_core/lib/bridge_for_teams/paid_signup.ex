defmodule BridgeForTeams.PaidSignup do
  @moduledoc "Paid Teams bootstrap through the existing Account, Checkout, Organization and Subscription."

  require Logger

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs, Repo, TeamsMail, TeamsPricing}
  alias BridgeForTeams.M2square.{Config, FX, Orders, Payer, Pricing, QuoteToken, Signing}
  alias BridgeForTeams.Schema.{Organization, OrgMembership}
  alias BillingCommerce.{Subscriptions, PaidCycles}

  def start_with_quote(purchase_id, attrs, quote_token, base_url) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    with {:ok, id} <- cast_uuid_for_quote(purchase_id),
         {:ok, snapshot} <-
           QuoteToken.verify(quote_token, "signup:" <> id, SystemsClock.utc_now()) do
      if attrs["provider"] == "m2square" do
        start_m2square_with_quote(id, attrs, snapshot, base_url)
      else
        start_stripe_with_quote(id, attrs, snapshot, base_url)
      end
    end
  end

  def renew_with_quote(org, attrs, quote_token, base_url) do
    now = SystemsClock.utc_now()

    with {:ok, snapshot} <- QuoteToken.verify(quote_token, "renew:" <> org.id, now) do
      if is_map(attrs) and attrs["provider"] == "m2square" do
        renew_m2square_with_quote(org, attrs, snapshot, base_url)
      else
        renew_stripe_with_quote(org, attrs, snapshot, base_url)
      end
    end
  end

  def start(purchase_id, %{"provider" => "m2square"} = attrs, base_url) do
    start_m2square(purchase_id, attrs, base_url)
  end

  def start(purchase_id, attrs, base_url) do
    with {:ok, id} <- Ecto.UUID.cast(purchase_id),
         {:ok, signup, seats} <- signup(attrs),
         :ok <-
           if(BridgeForTeams.LoginLinks.enabled?(),
             do: :ok,
             else: {:error, :teams_signin_unavailable}
           ),
         {:ok, plan} <- fetch_stripe_teams_plan(),
         owner = owner(id),
         :ok <- BillingCore.Accounts.ensure_account(owner),
         :ok <- require_subscription(owner),
         {:ok, customer} <-
           BillingStripe.ensure_customer(
             Map.merge(owner, %{
               billing_email: signup["email"],
               display_name: signup["org_name"],
               actor_type: "teams_signup",
               actor_id: id
             })
           ),
         {:ok, checkout} <-
           BillingStripe.create_checkout_session(
             Map.merge(owner, %{
               customer_id: customer.provider_customer_id,
               package_code: plan.package_code,
               package_version: plan.package_version,
               provider_price_id: plan.provider_price_id,
               mode: "subscription",
               quantity: seats,
               teams_signup: signup,
               success_url: base_url <> "/signup/payment?status=success&p=" <> id,
               cancel_url: base_url <> "/signup/payment?status=cancel&p=" <> id,
               idempotency_key: "teams:signup:" <> id
             })
             |> Map.merge(analytics_opt_out(attrs))
           ) do
      {:ok, checkout}
    else
      :error -> {:error, :invalid_teams_signup}
      {:error, _} = error -> error
    end
  end

  defp fetch_stripe_teams_plan do
    case BillingCommerce.get_provider_plan(%{
           surface: "bridge",
           provider: "stripe",
           provider_lookup_key: TeamsPricing.lookup_key(),
           synced_only: true
         }) do
      {:ok, plan} -> {:ok, plan}
      {:error, :not_found} -> {:error, :teams_price_not_configured}
      {:error, _} = error -> error
    end
  end

  def result(purchase_id) do
    with {:ok, id} <- Ecto.UUID.cast(purchase_id),
         {:ok, org} <- Orgs.get_org(id),
         {:ok, seats} when is_integer(seats) <-
           BillingCore.TeamsAccess.check(org.billing_account_id) do
      {:ok, %{slug: org.slug, name: org.name}}
    else
      _ -> {:error, :teams_signup_pending}
    end
  end

  @doc """
  Five-state local read of a Teams purchase:
    * `{:settled_active, %{id, slug, name}}` - org exists and has active paid coverage
    * `{:settled_inactive, %{id, slug, name}}` - org exists and had a payment recorded before, now inactive
    * `{:half_committed, %{id}}` - org exists in BFT, but billing has never recorded a payment yet
    * `:pending` - org does not exist yet (or invalid id)
    * `:unavailable` - billing or BFT read failed
  """
  @spec purchase_state(term()) ::
          {:settled_active, %{id: Ecto.UUID.t(), slug: String.t(), name: String.t()}}
          | {:settled_inactive, %{id: Ecto.UUID.t(), slug: String.t(), name: String.t()}}
          | {:half_committed, %{id: Ecto.UUID.t()}}
          | :pending
          | :unavailable
  def purchase_state(purchase_id) when is_binary(purchase_id) do
    case Ecto.UUID.cast(purchase_id) do
      {:ok, id} ->
        case Orgs.get_org(id) do
          {:error, :not_found} ->
            :pending

          {:ok, org} ->
            if org.billing_account_id != "ba_teams_" <> org.id do
              :unavailable
            else
              repo = billing_repo()

              case BillingCore.Accounts.verify_account(%{
                     repo: repo,
                     billing_account_id: org.billing_account_id,
                     required_surface: "bridge",
                     product_owner_type: "organization",
                     product_owner_id: org.id
                   }) do
                {:error, :billing_account_not_found} ->
                  {:half_committed, %{id: org.id}}

                {:error, _} ->
                  :unavailable

                :ok ->
                  case BillingCore.TeamsAccess.check(org.billing_account_id) do
                    {:ok, seats} when is_integer(seats) and seats > 0 ->
                      {:settled_active, %{id: org.id, slug: org.slug, name: org.name}}

                    {:ok, :unmanaged} ->
                      :unavailable

                    {:error, :teams_subscription_required} ->
                      if has_recorded_teams_seat_source?(repo, org.billing_account_id) do
                        {:settled_inactive, %{id: org.id, slug: org.slug, name: org.name}}
                      else
                        {:half_committed, %{id: org.id}}
                      end

                    {:error, :billing_account_not_found} ->
                      {:half_committed, %{id: org.id}}

                    _ ->
                      :unavailable
                  end
              end
            end
        end

      :error ->
        :pending
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  def purchase_state(_), do: :pending

  @doc """
  Reads local checkout snapshots (Stripe `subscription_checkout` or open M2square order)
  for a pending purchase without calling any external payment API.
  """
  @spec pending_checkout_snapshot(term(), DateTime.t()) ::
          {:ok, %{url: String.t(), expires_at: DateTime.t()}} | :none
  def pending_checkout_snapshot(purchase_id, now \\ SystemsClock.utc_now())

  def pending_checkout_snapshot(purchase_id, %DateTime{} = now) when is_binary(purchase_id) do
    with {:ok, id} <- Ecto.UUID.cast(purchase_id) do
      account_id = "ba_teams_" <> id
      repo = billing_repo()

      stripe_pending_snapshot(repo, account_id, now) ||
        m2square_pending_snapshot(repo, account_id, now) ||
        :none
    else
      _ -> :none
    end
  rescue
    _ -> :none
  catch
    :exit, _ -> :none
  end

  def pending_checkout_snapshot(_, _), do: :none

  defp stripe_pending_snapshot(repo, account_id, now) do
    now_unix = DateTime.to_unix(now, :second)

    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT subscription_checkout FROM billing_accounts WHERE id = $1 LIMIT 1",
           [account_id],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[%{} = pending]]}} when pending != %{} ->
        url = get_in(pending, ["session", "url"])

        expires_at =
          get_in(pending, ["session", "expires_at"]) || get_in(pending, ["request", "expires_at"])

        if pending["stage"] == "open" and non_empty_binary?(url) and
             is_integer(expires_at) and expires_at > now_unix do
          {:ok, %{url: url, expires_at: DateTime.from_unix!(expires_at)}}
        end

      _ ->
        nil
    end
  end

  defp m2square_pending_snapshot(repo, account_id, now) do
    cutoff = DateTime.add(now, -3600, :second)

    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT checkout_url, inserted_at
           FROM billing_m2square_orders
           WHERE billing_account_id = $1
             AND status = 'open'
             AND checkout_url IS NOT NULL
             AND inserted_at > $2
           ORDER BY inserted_at DESC
           LIMIT 1
           """,
           [account_id, cutoff],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[url, %DateTime{} = inserted_at]]}} ->
        expires_at = DateTime.add(inserted_at, 3600, :second)

        if non_empty_binary?(url) and DateTime.compare(expires_at, now) == :gt do
          {:ok, %{url: url, expires_at: expires_at}}
        end

      _ ->
        nil
    end
  end

  defp has_recorded_teams_seat_source?(repo, account_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1
      FROM billing_subscription_cycles c,
      LATERAL jsonb_each(
        CASE
          WHEN jsonb_typeof(c.source_metadata->'payment_sources') = 'object'
          THEN c.source_metadata->'payment_sources'
          ELSE '{}'::jsonb
        END
      ) AS src(key, val)
      WHERE c.billing_account_id = $1
        AND (src.val->>'teams_seats') ~ '^[0-9]+$'
        AND (src.val->>'teams_seats')::bigint > 0
      LIMIT 1
      """,
      [account_id],
      timeout: 1_000
    ).rows != []
  end

  def portal(org, return_url) do
    with {:ok, customer} <-
           BillingCommerce.get_active_provider_customer(%{
             billing_account_id: org.billing_account_id,
             provider: "stripe"
           }) do
      BillingStripe.create_customer_portal(%{
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        customer_id: customer.provider_customer_id,
        return_url: return_url,
        idempotency_key: "teams:portal:" <> SystemsRuntime.Proc.uuid()
      })
    end
  end

  def renew(org, %{"provider" => "m2square"} = params, base_url) do
    renew_m2square(org, params, base_url)
  end

  def renew(org, seats_or_params, base_url) do
    requested_seats =
      if is_map(seats_or_params), do: seats_or_params["seats"], else: seats_or_params

    with :ok <- managed_account(org.billing_account_id),
         seats when is_integer(seats) and seats >= 100 and seats <= 2_147_483_647 <-
           seat_count(requested_seats),
         true <- seats >= Memberships.count_org_members(org.id),
         {:ok, plan} <- fetch_stripe_teams_plan(),
         {:ok, customer} <-
           BillingStripe.ensure_customer(%{
             billing_account_id: org.billing_account_id,
             surface: "bridge",
             product_owner_type: "organization",
             product_owner_id: org.id,
             display_name: org.name,
             actor_type: "teams_renewal",
             actor_id: org.id
           }) do
      BillingStripe.create_checkout_session(%{
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: org.id,
        customer_id: customer.provider_customer_id,
        package_code: plan.package_code,
        package_version: plan.package_version,
        provider_price_id: plan.provider_price_id,
        mode: "subscription",
        quantity: seats,
        success_url: base_url <> "/orgs/" <> URI.encode_www_form(org.slug) <> "/settings/general",
        cancel_url: base_url <> "/orgs/" <> URI.encode_www_form(org.slug) <> "/settings/general",
        idempotency_key: "teams:renew:" <> SystemsRuntime.Proc.uuid()
      })
    else
      false -> {:error, :teams_seats_below_members}
      {:error, _} = error -> error
      _ -> {:error, :invalid_teams_signup}
    end
  end

  defp managed_account(account) do
    case BillingCore.TeamsAccess.check(account) do
      {:ok, :unmanaged} -> {:error, :teams_unmanaged_account}
      {:ok, seats} when is_integer(seats) -> :ok
      {:error, :teams_subscription_required} -> :ok
      {:error, _} = error -> error
    end
  end

  def process(%{"id" => event_id, "type" => type, "data" => %{"object" => object}} = event) do
    cond do
      type in [
        "charge.refunded",
        "charge.dispute.created",
        "charge.dispute.updated",
        "charge.dispute.closed"
      ] ->
        case BillingStripe.Events.process_payment_rights(event) do
          {:error, :stripe_payment_not_recorded} -> unrecorded_payment(object)
          result -> result
        end

      type in [
        "invoice.paid",
        "invoice.payment_failed",
        "checkout.session.completed",
        "checkout.session.async_payment_succeeded",
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
        "customer.subscription.paused",
        "customer.subscription.resumed"
      ] ->
        metadata = BillingStripe.Events.billing_metadata(object)
        converge(metadata, event_id, type, object)

      true ->
        {:ok, %{ignored: true}}
    end
  end

  defp unrecorded_payment(object) do
    with {:ok, charge} <- BillingStripe.Ownership.charge(object) do
      repo = SystemsRuntime.fetch_env!(:billing_commerce, :repo)

      case Ecto.Adapters.SQL.query!(
             repo,
             """
             SELECT a.teams_subscription_required FROM billing_provider_customers p
             JOIN billing_accounts a ON a.id = p.billing_account_id
             WHERE p.provider = 'stripe' AND p.provider_customer_id = $1 AND a.surface = 'bridge'
             LIMIT 1
             """,
             [charge["customer"]]
           ).rows do
        [[true]] -> {:error, :stripe_payment_not_recorded}
        _ -> {:ok, %{ignored: true, reason: :unmanaged_teams_payment}}
      end
    end
  end

  defp converge(metadata, event_id, type, object) do
    account = metadata["billing_account_id"]
    billing_repo = SystemsRuntime.fetch_env!(:billing_commerce, :repo)

    tx_result =
      billing_repo.transaction(fn ->
        case Ecto.Adapters.SQL.query!(
               billing_repo,
               "SELECT product_owner_id, subscription_checkout, teams_subscription_required FROM billing_accounts WHERE id = $1 AND surface = 'bridge' FOR UPDATE",
               [account]
             ).rows do
          [[org_id, pending, true]] ->
            with {:ok, config} <- TeamsPricing.config(),
                 {:ok, subscription_id} <- subscription_id(type, object),
                 {:ok, subscription} <-
                   config.api.retrieve_subscription(subscription_id, %{}, config.opts),
                 :ok <- subscription_owner(subscription, account, org_id),
                 {:ok, invoice_id} <- invoice_id(type, object, subscription),
                 {:ok, invoice} <- config.api.retrieve_invoice(invoice_id, %{}, config.opts),
                 {:ok, paid} <- paid_invoice(invoice, subscription, config),
                 :ok <-
                   check_stripe_m2square_overlap(
                     billing_repo,
                     account,
                     subscription,
                     invoice,
                     paid,
                     event_id
                   ),
                 :ok <- initial_payment(pending, subscription, paid),
                 first_recording? =
                   not stripe_invoice_recorded?(billing_repo, account, invoice["id"]),
                 {:ok, org} <- provision(org_id, account, pending),
                 {:ok, _} <-
                   BillingCommerce.issue_bridge_platform_unlimited(%{
                     billing_account_id: account,
                     organization_id: org.id
                   }),
                 {:ok, result} <- record(org, subscription, invoice, paid, pending, event_id) do
              eligible_paid? = eligible_paid_invoice?(paid)

              if eligible_paid? and first_recording? do
                PaidCycles.mark_confirmation_email_eligible!(
                  billing_repo,
                  account,
                  result.subscription_id,
                  invoice["id"]
                )
              end

              dispatch =
                if eligible_paid? and
                     (first_recording? or
                        PaidCycles.confirmation_email_pending?(
                          billing_repo,
                          account,
                          invoice["id"]
                        )) do
                  %{
                    kind: :teams_payment_confirmation,
                    billing_account_id: account,
                    subscription_id: result.subscription_id,
                    invoice_id: invoice["id"],
                    org_id: org.id,
                    seats: paid.teams_seats,
                    expires_at: paid.expires_at
                  }
                end

              result
              |> Map.put(:cft_completed, signup_completion(org, pending, subscription, paid))
              |> then(fn res ->
                if dispatch, do: Map.put(res, :after_commit_dispatch, dispatch), else: res
              end)
            else
              {:error, :teams_invoice_unpaid} ->
                %{pending: true}

              {:error, {:m2square_term_already_active, conflict_record}} ->
                Logger.warning(
                  "stripe teams converge blocked by active m2square_term cycle: " <>
                    "billing_account_id=#{account} subscription_id=#{inspect(conflict_record["subscription_id"])} " <>
                    "invoice_id=#{inspect(conflict_record["invoice_id"])} event_id=#{event_id}"
                )

                %{
                  conflict: :m2square_term_already_active,
                  subscription_id: conflict_record["subscription_id"],
                  invoice_id: conflict_record["invoice_id"],
                  audit_org_id: org_id,
                  conflict_record: conflict_record
                }

              {:error, reason} ->
                billing_repo.rollback(reason)
            end

          [[_, _, false]] ->
            %{ignored: true, reason: :unmanaged_teams_account}

          [] ->
            if metadata["package_version"] == TeamsPricing.version(),
              do: billing_repo.rollback(:teams_signup_not_found),
              else: %{ignored: true, reason: :foreign_product}
        end
      end)

    case tx_result do
      {:ok, %{conflict: :m2square_term_already_active, audit_org_id: org_id} = res} ->
        maybe_record_stripe_overlap_audit(org_id, res.conflict_record)
        {:ok, Map.take(res, [:conflict, :subscription_id, :invoice_id])}

      {:ok, %{cft_completed: completion} = result} ->
        capture_completion(completion)
        result = Map.delete(result, :cft_completed)

        if not billing_repo.in_transaction?() do
          {dispatch, clean_result} = Map.pop(result, :after_commit_dispatch)
          if dispatch, do: after_commit(dispatch)
          {:ok, clean_result}
        else
          {:ok, result}
        end

      other ->
        other
    end
  end

  defp eligible_paid_invoice?(paid) do
    is_integer(paid.teams_seats) and paid.teams_seats > 0 and
      not paid.fully_refunded and
      Enum.all?(Map.values(paid.disputes), &(&1 in ["won", "warning_closed"]))
  end

  @doc """
  Dispatches post-commit side effects (Stripe confirmation email) outside the
  webhook journal transaction.
  """
  def after_commit(%{kind: :teams_payment_confirmation} = dispatch) do
    _ =
      SystemsRuntime.TaskSupervisor.start_child(BridgeForTeams.TaskSupervisor, fn ->
        repo = billing_repo()

        if PaidCycles.claim_confirmation_email_send?(
             repo,
             dispatch.billing_account_id,
             dispatch.subscription_id,
             dispatch.invoice_id,
             SystemsClock.utc_now()
           ) do
          try do
            with {:ok, org} <- Orgs.get_org(dispatch.org_id),
                 recipient when is_binary(recipient) and recipient != "" <-
                   Memberships.first_owner_email(org.id),
                 true <- TeamsMail.configured?() do
              {subject, body} =
                confirmation_email_content(
                  org.name,
                  org.slug,
                  dispatch.seats,
                  dispatch.expires_at
                )

              case TeamsMail.send_message(recipient, subject, body) do
                {:ok, _} ->
                  PaidCycles.mark_confirmation_email_sent!(
                    repo,
                    dispatch.billing_account_id,
                    dispatch.subscription_id,
                    dispatch.invoice_id,
                    SystemsClock.utc_now()
                  )

                  :ok

                {:error, reason} ->
                  PaidCycles.release_confirmation_email_claim!(
                    repo,
                    dispatch.billing_account_id,
                    dispatch.subscription_id,
                    dispatch.invoice_id
                  )

                  Logger.warning(
                    "stripe confirmation email failed: invoice_id=#{dispatch.invoice_id} reason=#{inspect(reason)}"
                  )
              end
            else
              _ ->
                PaidCycles.release_confirmation_email_claim!(
                  repo,
                  dispatch.billing_account_id,
                  dispatch.subscription_id,
                  dispatch.invoice_id
                )
            end
          rescue
            error ->
              PaidCycles.release_confirmation_email_claim!(
                repo,
                dispatch.billing_account_id,
                dispatch.subscription_id,
                dispatch.invoice_id
              )

              Logger.warning(
                "stripe confirmation email crashed: invoice_id=#{dispatch.invoice_id} error=#{inspect(error)}"
              )
          end
        end
      end)

    :ok
  end

  def after_commit(_dispatch), do: :ok

  defp confirmation_email_content(org_name, org_slug, seats, expires_at) do
    expiry_date = Calendar.strftime(expires_at, "%Y-%m-%d")
    subject = "Comma for Teams payment confirmed (#{seats} seats)"
    sign_in_url = teams_login_url(org_slug)

    body =
      """
      Your Comma for Teams payment for #{org_name} has been confirmed.

      Organization slug: #{org_slug}
      Licensed seats: #{seats}
      Coverage valid through (UTC): #{expiry_date}
      Sign in: #{sign_in_url}
      """
      |> String.trim()

    {subject, body}
  end

  defp teams_login_url(org_slug) do
    query = URI.encode_query(%{"o" => org_slug})

    case SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/login?" <> query

      _ ->
        "/login?" <> query
    end
  end

  # The payment that converges a signup's pending checkout is its first: the
  # checkout is cleared in the same transaction, so later events see none.
  # Timed by the invoice payment: a webhook retried after a rollback converges
  # it again and repeats the same event, which PostHog deduplicates.
  defp signup_completion(org, pending, subscription, paid) do
    signup_completion!(org, pending, subscription, paid)
  rescue
    _ -> nil
  end

  defp signup_completion!(org, pending, subscription, paid) do
    request = is_map(pending) && pending["request"]

    if is_map(request) and is_map(request["teams_signup"]) and
         request["analytics_opt_out"] != true do
      %{
        purchase_id: org.id,
        source_id: subscription["id"],
        provider: "stripe",
        seats: paid.teams_seats,
        email: request["teams_signup"]["email"],
        occurred_at: paid.paid_at
      }
    end
  end

  # A DNT signup request keeps its opt-out in the pending checkout's request,
  # which the converging webhook reads. Absent otherwise, so the request is unchanged.
  defp analytics_opt_out(%{"analytics_opt_out" => true}), do: %{analytics_opt_out: true}
  defp analytics_opt_out(_attrs), do: %{}

  # A local order keeps the request's DNT in its signup snapshot, which the
  # settlement reads; absent otherwise, so an order without DNT is unchanged.
  defp snapshot_opt_out(%{"analytics_opt_out" => true}), do: %{"analytics_opt_out" => true}
  defp snapshot_opt_out(_attrs), do: %{}

  # The purchase an order is for, without its analytics choice: an open order
  # is reused whatever a later request's DNT says, and keeps its first choice.
  defp purchase_snapshot(snapshot) when is_map(snapshot),
    do: Map.delete(snapshot, "analytics_opt_out")

  defp purchase_snapshot(snapshot), do: snapshot

  defp capture_completion(nil), do: :ok

  # Runs inside the Stripe webhook's journal transaction: a failure here must
  # never roll back the payment, so the whole observation is guarded.
  defp capture_completion(completion) do
    BridgeForTeams.CftAnalytics.observe(fn ->
      BridgeForTeams.CftAnalytics.capture(
        completion.purchase_id,
        "cft_checkout_completed",
        completion.source_id,
        %{
          "provider" => completion.provider,
          "seats" => completion.seats,
          "is_internal" => BridgeForTeams.CftAnalytics.internal_email?(completion.email)
        },
        completion.occurred_at
      )
    end)
  end

  defp initial_payment(nil, _subscription, _paid), do: :ok

  defp initial_payment(pending, subscription, paid) do
    if get_in(subscription, ["metadata", "subscription_checkout_key"]) == pending["key"] and
         subscription["customer"] == get_in(pending, ["request", "customer_id"]) and
         get_in(pending, ["request", "quantity"]) == paid.teams_seats and
         not paid.fully_refunded and
         Enum.all?(Map.values(paid.disputes), &(&1 in ["won", "warning_closed"])) do
      :ok
    else
      {:error, :teams_initial_payment_mismatch}
    end
  end

  defp record(org, subscription, invoice, paid, pending, event_id) do
    with {:ok, result} <-
           Subscriptions.create_subscription(%{
             billing_account_id: org.billing_account_id,
             surface: "bridge",
             product_owner_type: "organization",
             product_owner_id: org.id,
             package_code: TeamsPricing.package(),
             package_version: TeamsPricing.version(),
             source_type: "stripe_subscription",
             source_id: subscription["id"],
             source_event_id: invoice["id"],
             idempotency_key: "stripe:subscription:" <> subscription["id"],
             subscription_checkout_key: pending && pending["key"],
             source_metadata: %{"stripe_customer_id" => subscription["customer"]},
             periods: [
               %{
                 cycle_key: invoice["id"],
                 valid_from: paid.valid_from,
                 expires_at: paid.expires_at,
                 source_event_id: invoice["id"]
               }
             ]
           }),
         {:ok, package} <-
           BillingCommerce.PackageCatalog.get_package_version(%{
             package_code: TeamsPricing.package(),
             version: TeamsPricing.version()
           }),
         {:ok, _} <-
           PaidCycles.record_invoice(
             result.subscription,
             package,
             invoice["id"],
             paid,
             paid.paid_at
           ),
         {:ok, _} <-
           Subscriptions.set_provider_subscription_status(%{
             source_id: subscription["id"],
             status: subscription["status"],
             source_event_id: event_id,
             source_metadata: %{
               "cancel_at_period_end" => subscription["cancel_at_period_end"] == true
             }
           }),
         {:ok, _} <-
           BillingCommerce.upsert_provider_customer_from_event(%{
             billing_account_id: org.billing_account_id,
             surface: "bridge",
             product_owner_type: "organization",
             product_owner_id: org.id,
             provider: "stripe",
             provider_customer_id: subscription["customer"],
             source_event_id: event_id
           }) do
      {:ok, %{organization_id: org.id, subscription_id: result.subscription.id}}
    end
  end

  defp paid_invoice(invoice, subscription, config) do
    lines = get_in(invoice, ["lines", "data"]) || []

    with true <- invoice["status"] == "paid" and invoice["paid_out_of_band"] != true,
         true <- invoice["currency"] == "usd" and get_in(invoice, ["lines", "has_more"]) != true,
         [line] <- Enum.filter(lines, &((&1["amount"] || 0) > 0)),
         seats when is_integer(seats) and seats >= 100 <- line["quantity"],
         price_id when is_binary(price_id) <- line_price(line),
         {:ok, plan} <-
           BillingCommerce.get_provider_plan(%{
             surface: "bridge",
             provider: "stripe",
             provider_price_id: price_id,
             synced_only: true
           }),
         true <-
           plan.package_code == TeamsPricing.package() and
             plan.package_version == TeamsPricing.version(),
         {:ok, price} <- config.api.retrieve_price(price_id, %{}, config.opts),
         :ok <- TeamsPricing.validate_terms(price),
         true <- (invoice["amount_paid"] || 0) >= seats * 24_000,
         true <-
           (get_in(invoice, ["parent", "subscription_details", "subscription"]) ||
              invoice["subscription"]) == subscription["id"],
         %{"start" => starts, "end" => ends}
         when is_integer(starts) and is_integer(ends) and ends > starts <- line["period"],
         {:ok, payment} when is_map(payment) <- BillingStripe.Payments.invoice_payment(invoice) do
      {:ok,
       Map.merge(payment, %{
         teams_seats: seats,
         valid_from: DateTime.from_unix!(starts),
         expires_at: DateTime.from_unix!(ends)
       })}
    else
      false ->
        if invoice["status"] != "paid",
          do: {:error, :teams_invoice_unpaid},
          else: {:error, :invalid_teams_payment}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_teams_payment}
    end
  end

  defp provision(org_id, account, pending) do
    case Orgs.get_org(org_id) do
      {:ok, %Organization{billing_account_id: ^account} = org} ->
        {:ok, org}

      {:error, :not_found} when is_map(pending) ->
        signup = get_in(pending, ["request", "teams_signup"])

        if is_map(signup) do
          provision_from_signup_map(org_id, account, signup)
        else
          {:error, :teams_signup_details_missing}
        end

      _ ->
        {:error, :teams_signup_owner_conflict}
    end
  end

  defp owner_user(signup) do
    case Accounts.get_user_by_email(signup["email"]) do
      {:ok, %{status: "active"} = user} ->
        {:ok, user}

      {:error, :not_found} ->
        Accounts.create_user(%{email: signup["email"], name: signup["name"]})

      _ ->
        {:error, :teams_owner_inactive}
    end
  end

  defp require_subscription(owner) do
    with :ok <- BillingCore.Accounts.verify_account(owner) do
      Ecto.Adapters.SQL.query!(
        SystemsRuntime.fetch_env!(:billing_commerce, :repo),
        "UPDATE billing_accounts SET teams_subscription_required = true WHERE id = $1",
        [owner.billing_account_id]
      )

      :ok
    end
  end

  defp owner(id),
    do: %{
      billing_account_id: "ba_teams_" <> id,
      surface: "bridge",
      product_owner_type: "organization",
      product_owner_id: id
    }

  defp signup(attrs) when is_map(attrs) do
    seats = seat_count(attrs["seats"])

    email = text(attrs["email"]) |> String.downcase()
    org_name = text(attrs["org_name"])
    name = text(attrs["name"])

    if is_integer(seats) and seats >= 100 and seats <= 2_147_483_647 and
         byte_size(email) <= 254 and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email) and
         byte_size(org_name) in 1..200 and byte_size(name) <= 200 do
      {:ok, %{"email" => email, "org_name" => org_name, "name" => name}, seats}
    else
      {:error, :invalid_teams_signup}
    end
  end

  defp signup(_), do: {:error, :invalid_teams_signup}

  defp seat_count(n) when is_integer(n), do: n

  defp seat_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp seat_count(_), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""

  defp subscription_owner(sub, account, org_id) do
    metadata = sub["metadata"] || %{}

    if metadata["surface"] == "bridge" and metadata["billing_account_id"] == account and
         metadata["product_owner_id"] == org_id and
         metadata["product_owner_type"] == "organization",
       do: :ok,
       else: {:error, :teams_subscription_owner_conflict}
  end

  defp subscription_id("customer.subscription." <> _, object), do: {:ok, object["id"]}

  defp subscription_id(_, object) do
    case object["subscription"] ||
           get_in(object, ["parent", "subscription_details", "subscription"]) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :teams_subscription_missing}
    end
  end

  defp invoice_id("invoice." <> _, object, _), do: {:ok, object["id"]}
  defp invoice_id(_, _, %{"latest_invoice" => id}) when is_binary(id), do: {:ok, id}
  defp invoice_id(_, _, _), do: {:error, :teams_invoice_missing}

  defp line_price(line) do
    get_in(line, ["pricing", "price_details", "price"]) ||
      case line["price"] do
        %{"id" => id} -> id
        id -> id
      end
  end

  # ---- M2square dual-channel orchestration, webhook & reconciliation ----

  @doc """
  Handles an inbound M2square webhook after raw-body capture.
  Verifies SHA512 signature before JSON decoding, actively calls `verifyStatus`,
  guards against replica read lag, and converges order + seat entitlements atomically.
  """
  @spec handle_m2square_webhook(binary(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def handle_m2square_webhook(raw_body, sign_header) when is_binary(raw_body) do
    cfg = Config.get()

    with :ok <- verify_webhook_signature(raw_body, sign_header, cfg),
         {:ok, %{} = body} <- decode_webhook_json(raw_body) do
      if non_empty_binary?(body["orderType"]) and body["orderType"] != "PAYMENT" do
        {:ok, %{ignored: :non_payment_order_type}}
      else
        case Orders.parse_webhook_order_id(body["mchOrderId"]) do
          :invalid ->
            Logger.warning("m2square webhook ignored invalid mchOrderId")
            {:ok, %{ignored: :unknown_order}}

          {:duplicate, base_id, suffix} ->
            handle_m2square_duplicate_webhook(base_id, suffix, body, cfg)

          {:base, base_id} ->
            handle_m2square_base_webhook(base_id, body, cfg)
        end
      end
    end
  end

  def handle_m2square_webhook(_raw_body, _sign_header), do: {:error, :bad_request}

  @doc """
  Performs an active `verifyStatus` check and state-machine convergence for `mch_order_id`.
  Does not require the order's country to remain enabled for new orders.
  """
  @spec reconcile_m2square_order(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_m2square_order(mch_order_id, opts \\ [])
      when is_binary(mch_order_id) and is_list(opts) do
    cfg = Config.get()

    if Config.credentials_configured?() do
      case Orders.get_by_mch_order_id(billing_repo(), mch_order_id) do
        {:ok, order} ->
          provider_order_id = Keyword.get(opts, :provider_order_id) || order.provider_order_id
          verify_and_converge_order(order, provider_order_id, nil, nil, cfg)

        {:error, :not_found} ->
          {:error, :order_not_found}
      end
    else
      {:error, :m2square_not_configured}
    end
  end

  @doc """
  Best-effort return-URL check for a M2square signup order, gated by a 5-second cooldown.
  Always returns `:ok` so the caller can proceed to `PaidSignup.result/1`.
  """
  @spec check_m2square_signup_return(term(), term()) :: :ok
  def check_m2square_signup_return(purchase_id, mch_order_id) do
    with {:ok, id} <- Ecto.UUID.cast(purchase_id),
         {:base, base_id} <- Orders.parse_webhook_order_id(mch_order_id),
         {:ok, order} <- Orders.get_by_mch_order_id(billing_repo(), base_id),
         true <-
           order.billing_account_id == "ba_teams_" <> id and
             order.kind == "signup" and
             non_empty_binary?(order.provider_order_id),
         true <- Orders.claim_return_check?(billing_repo(), base_id, SystemsClock.utc_now()) do
      _ = reconcile_m2square_order(base_id)
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Best-effort return-URL check for an organization's M2square renewal order, gated by a
  5-second cooldown. Always returns `:ok`.
  """
  @spec check_m2square_org_order(map(), term()) :: :ok
  def check_m2square_org_order(%{billing_account_id: account_id}, mch_order_id)
      when is_binary(account_id) do
    with {:base, base_id} <- Orders.parse_webhook_order_id(mch_order_id),
         {:ok, order} <- Orders.get_by_mch_order_id(billing_repo(), base_id),
         true <-
           order.billing_account_id == account_id and
             order.kind == "renewal" and
             non_empty_binary?(order.provider_order_id),
         true <- Orders.claim_return_check?(billing_repo(), base_id, SystemsClock.utc_now()) do
      _ = reconcile_m2square_order(base_id)
      :ok
    else
      _ -> :ok
    end
  end

  def check_m2square_org_order(_org, _mch_order_id), do: :ok

  defp start_stripe_with_quote(id, attrs, snapshot, base_url) do
    required_min = max(snapshot["stripe_min_seats"] || 100, 100)

    with {:ok, seats} <- validate_stripe_seat_min(attrs["seats"], required_min),
         {:ok, signup} <- m2square_signup_snapshot(attrs),
         :ok <-
           if(BridgeForTeams.LoginLinks.enabled?(),
             do: :ok,
             else: {:error, :teams_signin_unavailable}
           ),
         {:ok, plan} <- fetch_stripe_teams_plan(),
         owner = owner(id),
         :ok <- BillingCore.Accounts.ensure_account(owner),
         :ok <- require_subscription(owner),
         {:ok, customer} <-
           BillingStripe.ensure_customer(
             Map.merge(owner, %{
               billing_email: signup["email"],
               display_name: signup["org_name"],
               actor_type: "teams_signup",
               actor_id: id
             })
           ),
         {:ok, checkout} <-
           BillingStripe.create_checkout_session(
             Map.merge(owner, %{
               customer_id: customer.provider_customer_id,
               package_code: plan.package_code,
               package_version: plan.package_version,
               provider_price_id: plan.provider_price_id,
               mode: "subscription",
               quantity: seats,
               teams_signup: signup,
               quote_expires_at: snapshot["expires_at"],
               success_url: base_url <> "/signup/payment?status=success&p=" <> id,
               cancel_url: base_url <> "/signup/payment?status=cancel&p=" <> id,
               idempotency_key: "teams:signup:" <> id
             })
             |> Map.merge(analytics_opt_out(attrs))
           ) do
      {:ok, checkout}
    end
  end

  defp renew_stripe_with_quote(org, attrs, snapshot, base_url) do
    requested_seats = if is_map(attrs), do: attrs["seats"], else: attrs
    live_min = max(100, Memberships.count_org_members(org.id))
    required_min = max(snapshot["stripe_min_seats"] || 100, live_min)

    with :ok <- managed_account(org.billing_account_id),
         {:ok, seats} <- validate_stripe_seat_min(requested_seats, required_min),
         {:ok, plan} <- fetch_stripe_teams_plan(),
         {:ok, customer} <-
           BillingStripe.ensure_customer(%{
             billing_account_id: org.billing_account_id,
             surface: "bridge",
             product_owner_type: "organization",
             product_owner_id: org.id,
             display_name: org.name,
             actor_type: "teams_renewal",
             actor_id: org.id
           }) do
      BillingStripe.create_checkout_session(%{
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: org.id,
        customer_id: customer.provider_customer_id,
        package_code: plan.package_code,
        package_version: plan.package_version,
        provider_price_id: plan.provider_price_id,
        mode: "subscription",
        quantity: seats,
        quote_expires_at: snapshot["expires_at"],
        success_url: base_url <> "/orgs/" <> URI.encode_www_form(org.slug) <> "/settings/general",
        cancel_url: base_url <> "/orgs/" <> URI.encode_www_form(org.slug) <> "/settings/general",
        idempotency_key: "teams:renew:" <> SystemsRuntime.Proc.uuid()
      })
    end
  end

  defp start_m2square_with_quote(id, attrs, snapshot, base_url) do
    cfg = Config.effective_config()

    with true <- Config.credentials_configured?(cfg) || {:error, :m2square_unavailable},
         {:ok, live_country} <- enabled_country_in_cfg(cfg, attrs["country"]),
         {:ok, snap_country, country_for_checkout} <-
           resolve_quoted_country(live_country, snapshot),
         {:ok, seats} <-
           validate_seat_range(
             attrs["seats"],
             snap_country["min_seats"],
             snap_country["max_seats"]
           ),
         {:ok, signup_snapshot} <- m2square_signup_snapshot(attrs),
         :ok <-
           if(BridgeForTeams.LoginLinks.enabled?(),
             do: :ok,
             else: {:error, :teams_signin_unavailable}
           ),
         {:ok, quote} <-
           Pricing.quote_order(
             country_for_checkout,
             seats,
             snap_country["fx_rate"],
             snap_country["markup_rate"]
           ),
         {:ok, payer} <- validate_payer(country_for_checkout, attrs),
         owner = owner(id),
         :ok <- BillingCore.Accounts.ensure_account(owner),
         :ok <- require_subscription(owner),
         {:ok, reserved} <-
           reserve_m2square_order(%{
             billing_account_id: owner.billing_account_id,
             product_owner_id: id,
             kind: "signup",
             country_cfg: country_for_checkout,
             seats: seats,
             quote: quote,
             fx: %{source: snap_country["fx_source"] || "quote_snapshot"},
             payment_type: payer.payment_type,
             signup_snapshot: Map.merge(signup_snapshot, snapshot_opt_out(attrs)),
             quote_expires_at: snapshot["expires_at"]
           }) do
      dispatch_m2square_pay(
        reserved,
        country_for_checkout,
        quote,
        payer.gateway_fields,
        base_url,
        fn mch_order_id ->
          base_url <> "/signup/payment?status=success&m2_order=" <> mch_order_id <> "&p=" <> id
        end,
        cfg
      )
    else
      {:error, _} = error -> error
    end
  end

  defp renew_m2square_with_quote(org, attrs, snapshot, base_url) do
    cfg = Config.effective_config()
    now = SystemsClock.utc_now()

    with :ok <- managed_account(org.billing_account_id),
         true <- Config.credentials_configured?(cfg) || {:error, :m2square_unavailable},
         {:ok, live_country} <- enabled_country_in_cfg(cfg, attrs["country"]),
         {:ok, snap_country, country_for_checkout} <-
           resolve_quoted_country(live_country, snapshot),
         {:ok, seats} <-
           validate_seat_range(
             attrs["seats"],
             snap_country["min_seats"],
             snap_country["max_seats"]
           ),
         {:ok, cov} <- BillingCore.TeamsAccess.coverage(org.billing_account_id, now),
         :ok <- validate_m2square_renewal_eligibility(org, cov, seats),
         {:ok, quote} <-
           Pricing.quote_order(
             country_for_checkout,
             seats,
             snap_country["fx_rate"],
             snap_country["markup_rate"]
           ),
         {:ok, payer} <- validate_payer(country_for_checkout, attrs),
         {:ok, reserved} <-
           reserve_m2square_order(%{
             billing_account_id: org.billing_account_id,
             product_owner_id: org.id,
             kind: "renewal",
             country_cfg: country_for_checkout,
             seats: seats,
             quote: quote,
             fx: %{source: snap_country["fx_source"] || "quote_snapshot"},
             payment_type: payer.payment_type,
             signup_snapshot: nil,
             quote_expires_at: snapshot["expires_at"]
           }) do
      dispatch_m2square_pay(
        reserved,
        country_for_checkout,
        quote,
        payer.gateway_fields,
        base_url,
        fn mch_order_id ->
          base_url <>
            "/orgs/" <>
            URI.encode_www_form(org.slug) <> "/settings/general?m2_order=" <> mch_order_id
        end,
        cfg
      )
    else
      {:error, _} = error -> error
    end
  end

  defp start_m2square(purchase_id, attrs, base_url) do
    cfg = Config.effective_config()

    with {:ok, id} <- cast_uuid(purchase_id),
         true <- Config.credentials_configured?(cfg) || {:error, :m2square_unavailable},
         {:ok, country_cfg} <- enabled_country_in_cfg(cfg, attrs["country"]),
         {:ok, seats} <- m2square_seat_count(attrs["seats"]),
         {:ok, signup_snapshot} <- m2square_signup_snapshot(attrs),
         :ok <-
           if(BridgeForTeams.LoginLinks.enabled?(),
             do: :ok,
             else: {:error, :teams_signin_unavailable}
           ),
         {:ok, fx} <- FX.rate_for_country(country_cfg),
         {:ok, quote} <- Pricing.quote_order(country_cfg, seats, fx.rate, cfg.markup_rate),
         {:ok, payer} <- validate_payer(country_cfg, attrs),
         owner = owner(id),
         :ok <- BillingCore.Accounts.ensure_account(owner),
         :ok <- require_subscription(owner),
         {:ok, reserved} <-
           reserve_m2square_order(%{
             billing_account_id: owner.billing_account_id,
             product_owner_id: id,
             kind: "signup",
             country_cfg: country_cfg,
             seats: seats,
             quote: quote,
             fx: fx,
             payment_type: payer.payment_type,
             signup_snapshot: Map.merge(signup_snapshot, snapshot_opt_out(attrs))
           }) do
      dispatch_m2square_pay(
        reserved,
        country_cfg,
        quote,
        payer.gateway_fields,
        base_url,
        fn mch_order_id ->
          base_url <> "/signup/payment?status=success&m2_order=" <> mch_order_id <> "&p=" <> id
        end,
        cfg
      )
    else
      {:error, _} = error -> error
    end
  end

  defp renew_m2square(org, attrs, base_url) do
    cfg = Config.effective_config()
    now = SystemsClock.utc_now()

    with :ok <- managed_account(org.billing_account_id),
         true <- Config.credentials_configured?(cfg) || {:error, :m2square_unavailable},
         {:ok, country_cfg} <- enabled_country_in_cfg(cfg, attrs["country"]),
         {:ok, seats} <- m2square_seat_count(attrs["seats"]),
         {:ok, cov} <- BillingCore.TeamsAccess.coverage(org.billing_account_id, now),
         :ok <- validate_m2square_renewal_eligibility(org, cov, seats),
         {:ok, fx} <- FX.rate_for_country(country_cfg),
         {:ok, quote} <- Pricing.quote_order(country_cfg, seats, fx.rate, cfg.markup_rate),
         {:ok, payer} <- validate_payer(country_cfg, attrs),
         {:ok, reserved} <-
           reserve_m2square_order(%{
             billing_account_id: org.billing_account_id,
             product_owner_id: org.id,
             kind: "renewal",
             country_cfg: country_cfg,
             seats: seats,
             quote: quote,
             fx: fx,
             payment_type: payer.payment_type,
             signup_snapshot: nil
           }) do
      dispatch_m2square_pay(
        reserved,
        country_cfg,
        quote,
        payer.gateway_fields,
        base_url,
        fn mch_order_id ->
          base_url <>
            "/orgs/" <>
            URI.encode_www_form(org.slug) <> "/settings/general?m2_order=" <> mch_order_id
        end,
        cfg
      )
    else
      {:error, _} = error -> error
    end
  end

  defp validate_m2square_renewal_eligibility(org, cov, seats) do
    validate_m2square_renewal_snapshot(cov, Memberships.count_org_members(org.id), seats)
  end

  defp validate_m2square_renewal_snapshot(cov, member_count, seats) do
    min_required =
      max(
        30,
        max(
          member_count,
          if(cov.active, do: cov.licensed_seats, else: 0)
        )
      )

    cond do
      cov.has_active_stripe_subscription or (cov.active and cov.provider != "m2square") ->
        {:error, :subscription_already_exists}

      cov.has_future_paid_cycle ->
        {:error, :future_cycle_already_paid}

      seats < min_required ->
        {:error, :teams_seats_below_minimum}

      true ->
        :ok
    end
  end

  defp reserve_m2square_order(params) do
    repo = billing_repo()
    account_id = params.billing_account_id

    repo.transaction(fn ->
      pending_stripe =
        case Ecto.Adapters.SQL.query!(
               repo,
               "SELECT subscription_checkout FROM billing_accounts WHERE id = $1 FOR UPDATE",
               [account_id]
             ).rows do
          [[pending]] -> pending
          [] -> repo.rollback(:billing_account_not_found)
        end

      now = SystemsClock.utc_now()

      if is_integer(params[:quote_expires_at]) and
           DateTime.to_unix(now, :second) >= params[:quote_expires_at] do
        repo.rollback(:quote_expired)
      end

      if has_active_stripe_subscription?(repo, account_id) do
        repo.rollback(:subscription_already_exists)
      end

      if stripe_checkout_pending?(pending_stripe, now) do
        repo.rollback(:subscription_checkout_pending)
      end

      target_slot =
        case params.kind do
          "signup" ->
            if has_any_paid_cycle?(repo, account_id) do
              repo.rollback(:subscription_already_exists)
            end

            "initial"

          "renewal" ->
            cov =
              case BillingCore.TeamsAccess.coverage_in_repo(repo, account_id, now) do
                {:ok, c} -> c
                {:error, reason} -> repo.rollback(reason)
              end

            member_count = Memberships.count_org_members(params.product_owner_id)

            case validate_m2square_renewal_snapshot(cov, member_count, params.seats) do
              :ok -> :ok
              {:error, reason} -> repo.rollback(reason)
            end

            "after:" <> (Orders.prior_paid_cycle_id(repo, account_id) || "none")
        end

      if Orders.paid_slot_exists?(repo, account_id, target_slot) do
        conflict_reason =
          if params.kind == "signup",
            do: :subscription_already_exists,
            else: :future_cycle_already_paid

        repo.rollback(conflict_reason)
      end

      recent = Orders.recent_pending_for_slot(repo, account_id, target_slot, now)

      if Enum.any?(recent, &(&1.status == "creating")) do
        repo.rollback(:subscription_checkout_pending)
      end

      reusable =
        Enum.find(recent, fn existing ->
          existing.status == "open" and
            non_empty_binary?(existing.checkout_url) and
            existing.country == params.country_cfg.code and
            existing.payment_type == params.payment_type and
            existing.teams_seats == params.seats and
            purchase_snapshot(existing.signup_snapshot) ==
              purchase_snapshot(params.signup_snapshot) and
            existing.locked_amount == params.quote.formatted_amount and
            existing.currency == params.country_cfg.gateway_currency and
            existing.fx_rate == params.quote.fx_rate and
            existing.fee_rate == params.quote.fee_rate and
            existing.markup_rate == params.quote.markup_rate
        end)

      if reusable do
        {:reuse, reusable}
      else
        order =
          Orders.insert_creating_order!(repo, %{
            mch_order_id: Orders.generate_mch_order_id(),
            billing_account_id: account_id,
            product_owner_id: params.product_owner_id,
            kind: params.kind,
            target_slot: target_slot,
            country: params.country_cfg.code,
            payment_type: params.payment_type,
            currency: params.country_cfg.gateway_currency,
            display_currency: params.country_cfg.display_currency,
            teams_seats: params.seats,
            usd_net_minor: params.quote.usd_net_minor,
            locked_amount: params.quote.formatted_amount,
            fx_rate: params.quote.fx_rate,
            fx_source: params.fx.source,
            fee_rate: params.quote.fee_rate,
            markup_rate: params.quote.markup_rate,
            signup_snapshot: params.signup_snapshot,
            inserted_at: now
          })

        {:created, order}
      end
    end)
  end

  defp dispatch_m2square_pay(
         {:reuse, existing},
         _country_cfg,
         _quote,
         _gateway_fields,
         _base_url,
         _redirect_fun,
         _cfg
       ) do
    {:ok, %{"url" => existing.checkout_url, "mch_order_id" => existing.mch_order_id}}
  end

  defp dispatch_m2square_pay(
         {:created, order},
         country_cfg,
         quote,
         gateway_fields,
         base_url,
         redirect_fun,
         cfg
       ) do
    trimmed_base = String.trim_trailing(base_url, "/")

    payload =
      %{
        "amount" => quote.formatted_amount,
        "currency" => country_cfg.gateway_currency,
        "mchOrderId" => order.mch_order_id,
        "callbackUrl" => trimmed_base <> "/v1/billing/m2square/webhook",
        "redirectUrl" => redirect_fun.(order.mch_order_id),
        "dynamic" => "1",
        "noPayPage" => cfg.no_pay_page,
        "productinfo" => "Comma for Teams (#{order.teams_seats} seats, quarterly)"
      }
      |> Map.merge(gateway_fields)

    case cfg.client.pay(payload, cfg) do
      {:ok, %{order_id: provider_order_id, checkout_url: url} = pay_res} ->
        if non_empty_binary?(pay_res[:currency]) and
             pay_res[:currency] != country_cfg.gateway_currency do
          quarantine_m2square_currency_mismatch!(
            billing_repo(),
            order,
            provider_order_id,
            pay_res[:currency]
          )

          {:error, :m2square_pay_rejected}
        else
          case Orders.bind_open_order(billing_repo(), order.mch_order_id, provider_order_id, url) do
            {:ok, bound} ->
              {:ok, %{"url" => bound.checkout_url, "mch_order_id" => bound.mch_order_id}}

            {:error, :provider_order_id_conflict} ->
              Logger.warning(
                "m2square pay provider_order_id conflict: mch_order_id=#{order.mch_order_id} got=#{provider_order_id}"
              )

              {:error, :m2square_pay_rejected}

            {:error, _reason} ->
              {:error, :m2square_pay_rejected}
          end
        end

      {:error, {:rejected, _code, _msg}} ->
        Orders.mark_failed!(billing_repo(), order.mch_order_id)
        {:error, :m2square_pay_rejected}

      {:error, {:uncertain, _reason}} ->
        {:error, :m2square_pay_uncertain}

      {:error, _other} ->
        {:error, :m2square_pay_uncertain}
    end
  end

  defp quarantine_m2square_currency_mismatch!(repo, order, provider_order_id, observed_currency) do
    now = SystemsClock.utc_now()

    repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
        [order.billing_account_id]
      )

      case Orders.lock_by_mch_order_id(repo, order.mch_order_id) do
        {:error, :not_found} ->
          :ok

        {:ok, locked} ->
          if non_empty_binary?(locked.provider_order_id) and
               non_empty_binary?(provider_order_id) and
               locked.provider_order_id != provider_order_id do
            Logger.warning(
              "m2square pay currency-mismatch quarantine provider_order_id mismatch: " <>
                "mch_order_id=#{locked.mch_order_id} expected=#{locked.provider_order_id} got=#{provider_order_id}"
            )

            :ok
          else
            apply_currency_mismatch_in_lock!(
              repo,
              locked,
              provider_order_id,
              observed_currency,
              nil,
              nil,
              nil,
              now
            )
          end
      end
    end)

    :ok
  end

  defp apply_currency_mismatch_in_lock!(
         repo,
         locked,
         provider_order_id,
         observed_currency,
         verified_status,
         item,
         webhook_body,
         now
       ) do
    cond do
      verified_status == "REVERSED" ->
        converge_m2square_reversed(repo, locked, provider_order_id, now)

      locked.status == "paid" ->
        if non_empty_binary?(locked.cycle_id) do
          :ok =
            PaidCycles.revoke_payment_source!(
              repo,
              locked.billing_account_id,
              locked.cycle_id,
              "m2square:" <> locked.mch_order_id,
              %{
                "reason" => "currency_mismatch",
                "observed_currency" => observed_currency
              }
            )
        end

        Orders.mark_conflict_paid!(repo, locked.mch_order_id, %{
          provider_order_id: locked.provider_order_id || provider_order_id,
          real_amount: locked.real_amount,
          mch_fee: locked.mch_fee,
          bank_id: locked.bank_id,
          paid_at: locked.paid_at
        })

        %{status: "conflict_paid", reason: :currency_mismatch}

      locked.status in ["creating", "open", "failed", "quarantined"] ->
        if verified_status == "SUCCESS" do
          Orders.mark_conflict_paid!(repo, locked.mch_order_id, %{
            provider_order_id: locked.provider_order_id || provider_order_id,
            real_amount: decimal_string(item && item["realAmount"]),
            mch_fee: settled_mch_fee(verified_status, item, webhook_body),
            bank_id: (item && item["bankId"]) || (webhook_body && webhook_body["bankId"]),
            paid_at: now
          })

          %{status: "conflict_paid", reason: :currency_mismatch}
        else
          Orders.mark_quarantined!(repo, locked.mch_order_id, provider_order_id)
          %{status: "quarantined", reason: :currency_mismatch}
        end

      locked.status in ["conflict_paid", "reversed"] ->
        %{status: locked.status, idempotent: true}

      true ->
        %{status: locked.status}
    end
  end

  defp handle_m2square_duplicate_webhook(base_id, suffix, body, cfg) do
    repo = billing_repo()

    case Orders.get_by_mch_order_id(repo, base_id) do
      {:error, :not_found} ->
        {:ok, %{ignored: :unknown_order}}

      {:ok, order} ->
        dup_provider_order_id = body["orderId"]

        if not non_empty_binary?(dup_provider_order_id) do
          {:error, :bad_request}
        else
          case cfg.client.verify_status(dup_provider_order_id, cfg) do
            {:error, _reason} ->
              {:error, :upstream_unavailable}

            {:ok, items} ->
              with {:ok, item} <-
                     match_verify_item(items, body["mchOrderId"], dup_provider_order_id),
                   existing_status =
                     find_duplicate_entry_status(order.duplicate_events, dup_provider_order_id),
                   :ok <-
                     check_duplicate_read_lag(
                       existing_status,
                       body["orderStatus"],
                       item["orderStatus"]
                     ) do
                now = SystemsClock.utc_now()
                now_iso = DateTime.to_iso8601(now)
                verified_status = item["orderStatus"]

                repo.transaction(fn ->
                  Ecto.Adapters.SQL.query!(
                    repo,
                    "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
                    [order.billing_account_id]
                  )

                  {:ok, locked} = Orders.lock_by_mch_order_id(repo, base_id)

                  locked_existing_status =
                    find_duplicate_entry_status(locked.duplicate_events, dup_provider_order_id)

                  case check_duplicate_read_lag(
                         locked_existing_status,
                         body["orderStatus"],
                         verified_status
                       ) do
                    :ok ->
                      event_map =
                        %{
                          "mch_order_id" => body["mchOrderId"],
                          "suffix" => suffix,
                          "provider_order_id" => dup_provider_order_id,
                          "order_status" => verified_status,
                          "amount" => decimal_string(item["amount"]),
                          "real_amount" =>
                            settled_duplicate_real_amount(verified_status, item["realAmount"]),
                          "mch_fee" => settled_mch_fee(verified_status, item, body),
                          "currency" => item["currency"] || body["currency"] || locked.currency,
                          "bank_id" => item["bankId"] || body["bankId"],
                          "paid_at" => if(verified_status == "SUCCESS", do: now_iso, else: nil),
                          "reversed_at" =>
                            if(verified_status == "REVERSED", do: now_iso, else: nil),
                          "recorded_at" => now_iso
                        }

                      Orders.upsert_duplicate_event!(repo, base_id, event_map)
                      %{duplicate_recorded: true}

                    {:error, reason} ->
                      repo.rollback(reason)
                  end
                end)
              end
          end
        end
    end
  end

  defp settled_duplicate_real_amount("SUCCESS", raw_real_amount),
    do: decimal_string(raw_real_amount)

  defp settled_duplicate_real_amount("REVERSED", raw_real_amount) do
    case parse_decimal(raw_real_amount) do
      {:ok, dec} ->
        if Decimal.compare(dec, Decimal.new(0)) == :gt,
          do: decimal_string(raw_real_amount),
          else: nil

      :error ->
        nil
    end
  end

  defp settled_duplicate_real_amount(_status, _raw_real_amount), do: nil

  defp settled_mch_fee(verified_status, item, webhook_body) do
    item_fee =
      if verified_status in ["SUCCESS", "REVERSED"],
        do: decimal_string(item && item["mchFee"]),
        else: nil

    webhook_fee =
      if is_map(webhook_body) and webhook_body["orderStatus"] in ["SUCCESS", "REVERSED"],
        do: decimal_string(webhook_body["mchFee"]),
        else: nil

    item_fee || webhook_fee
  end

  defp find_duplicate_entry_status(events, provider_order_id) when is_list(events) do
    case Enum.find(events, &(&1["provider_order_id"] == provider_order_id)) do
      %{"order_status" => status} -> status
      _ -> nil
    end
  end

  defp check_duplicate_read_lag(existing_status, "REVERSED", verified_status)
       when existing_status != "REVERSED" and verified_status != "REVERSED" do
    {:error, :verify_status_lag}
  end

  defp check_duplicate_read_lag(existing_status, "SUCCESS", verified_status)
       when existing_status not in ["SUCCESS", "REVERSED"] and
              verified_status in ["PAYING", "FAILED", nil] do
    {:error, :verify_status_lag}
  end

  defp check_duplicate_read_lag(_existing_status, _webhook_status, _verified_status), do: :ok

  defp handle_m2square_base_webhook(base_id, body, cfg) do
    webhook_order_id = body["orderId"]

    if not non_empty_binary?(webhook_order_id) do
      {:error, :bad_request}
    else
      case Orders.get_by_mch_order_id(billing_repo(), base_id) do
        {:error, :not_found} ->
          Logger.warning("m2square webhook ignored unknown order: mch_order_id=#{base_id}")
          {:ok, %{ignored: :unknown_order}}

        {:ok, order} ->
          if non_empty_binary?(order.provider_order_id) and
               order.provider_order_id != webhook_order_id do
            Logger.warning(
              "m2square webhook provider_order_id mismatch: mch_order_id=#{base_id} " <>
                "expected=#{order.provider_order_id} got=#{webhook_order_id}"
            )

            {:ok, %{ignored: :provider_order_id_mismatch}}
          else
            verify_and_converge_order(order, webhook_order_id, body["orderStatus"], body, cfg)
          end
      end
    end
  end

  defp verify_and_converge_order(
         order,
         webhook_provider_order_id,
         webhook_order_status,
         webhook_body,
         cfg
       ) do
    lookup_order_id = order.provider_order_id || webhook_provider_order_id

    if not non_empty_binary?(lookup_order_id) do
      {:ok, %{ignored: :missing_provider_order_id}}
    else
      case cfg.client.verify_status(lookup_order_id, cfg) do
        {:error, _reason} ->
          {:error, :upstream_unavailable}

        {:ok, items} ->
          with {:ok, item} <- match_verify_item(items, order.mch_order_id, lookup_order_id),
               :ok <-
                 check_verify_read_lag(
                   order.status,
                   webhook_order_status,
                   item["orderStatus"]
                 ) do
            converge_m2square_order(order, lookup_order_id, item, webhook_body)
          end
      end
    end
  end

  defp match_verify_item(items, mch_order_id, provider_order_id) when is_list(items) do
    matches =
      Enum.filter(items, fn
        %{} = item ->
          item["mchOrderId"] == mch_order_id and
            item["orderType"] == "PAYMENT" and
            item["orderId"] == provider_order_id

        _ ->
          false
      end)

    case matches do
      [item] -> {:ok, item}
      _ -> {:error, :verify_status_lag}
    end
  end

  defp match_verify_item(_, _, _), do: {:error, :verify_status_lag}

  # Read-lag guard matrix (Astra #3):
  # Reject early ACK (HTTP 500) whenever a signed webhook reports a progressed state
  # that the upstream verifyStatus replica has not caught up to yet.
  defp check_verify_read_lag(local_status, "REVERSED", verified_status)
       when local_status != "reversed" and verified_status != "REVERSED" do
    {:error, :verify_status_lag}
  end

  defp check_verify_read_lag(local_status, "SUCCESS", verified_status)
       when local_status not in ["paid", "conflict_paid", "reversed"] and
              verified_status in ["PAYING", "FAILED", nil] do
    {:error, :verify_status_lag}
  end

  defp check_verify_read_lag(_local_status, _webhook_status, _verified_status), do: :ok

  defp converge_m2square_order(order, lookup_order_id, item, webhook_body) do
    repo = billing_repo()
    now = SystemsClock.utc_now()
    verified_status = item["orderStatus"]

    tx_result =
      repo.transaction(fn ->
        [[_org_id, pending_stripe, _required]] =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            SELECT product_owner_id, subscription_checkout, teams_subscription_required
            FROM billing_accounts
            WHERE id = $1
            FOR UPDATE
            """,
            [order.billing_account_id]
          ).rows

        {:ok, locked} = Orders.lock_by_mch_order_id(repo, order.mch_order_id)

        provider_mismatch? =
          non_empty_binary?(locked.provider_order_id) and
            (locked.provider_order_id != lookup_order_id or
               (is_map(webhook_body) and webhook_body["orderId"] != locked.provider_order_id))

        if provider_mismatch? do
          Logger.warning(
            "m2square converge provider_order_id mismatch under lock: mch_order_id=#{locked.mch_order_id} " <>
              "expected=#{locked.provider_order_id} lookup=#{lookup_order_id}"
          )

          %{ignored: :provider_order_id_mismatch}
        else
          mismatched_currency =
            [item["currency"], webhook_body && webhook_body["currency"]]
            |> Enum.find(fn c -> non_empty_binary?(c) and c != locked.currency end)

          if mismatched_currency != nil do
            apply_currency_mismatch_in_lock!(
              repo,
              locked,
              lookup_order_id,
              mismatched_currency,
              verified_status,
              item,
              webhook_body,
              now
            )
          else
            case verified_status do
              "SUCCESS" ->
                converge_m2square_success(
                  repo,
                  locked,
                  pending_stripe,
                  lookup_order_id,
                  item,
                  webhook_body,
                  now
                )

              "REVERSED" ->
                converge_m2square_reversed(repo, locked, lookup_order_id, now)

              "FAILED" ->
                if locked.status in ["creating", "open"] do
                  Orders.mark_failed!(repo, locked.mch_order_id, lookup_order_id)
                  %{status: "failed"}
                else
                  %{status: locked.status}
                end

              "PAYING" ->
                if locked.status == "creating" do
                  Orders.mark_open!(repo, locked.mch_order_id, lookup_order_id, nil)
                  %{status: "open"}
                else
                  %{status: locked.status}
                end

              _other ->
                %{status: locked.status}
            end
          end
        end
      end)

    tx_result =
      case tx_result do
        {:ok, %{cft_completed: completion} = result} ->
          capture_completion(completion)
          {:ok, Map.delete(result, :cft_completed)}

        other ->
          other
      end

    case tx_result do
      {:ok, %{notify: notify} = result} when is_map(notify) ->
        maybe_send_m2square_confirmation_email(notify)
        {:ok, Map.delete(result, :notify)}

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_replay_notify(repo, locked) do
    with {:ok, org} <- Orgs.get_org(locked.product_owner_id),
         %DateTime{} = expires_at <- fetch_cycle_period_end(repo, locked.cycle_id) do
      %{
        mch_order_id: locked.mch_order_id,
        org_id: org.id,
        org_name: org.name,
        org_slug: org.slug,
        seats: locked.teams_seats,
        expires_at: expires_at,
        email: locked.signup_snapshot && locked.signup_snapshot["email"]
      }
    else
      _ -> nil
    end
  end

  defp fetch_cycle_period_end(repo, cycle_id) when is_binary(cycle_id) do
    case Ecto.Adapters.SQL.query!(
           repo,
           "SELECT period_end FROM billing_subscription_cycles WHERE id = $1 LIMIT 1",
           [cycle_id]
         ).rows do
      [[%DateTime{} = period_end]] -> period_end
      _ -> nil
    end
  end

  defp fetch_cycle_period_end(_repo, _), do: nil

  defp converge_m2square_success(
         repo,
         %{status: "paid"} = locked,
         _pending_stripe,
         lookup_order_id,
         item,
         webhook_body,
         now
       ) do
    mch_fee = settled_mch_fee(item["orderStatus"], item, webhook_body)

    candidate_bank_ids =
      [item["bankId"], webhook_body && webhook_body["bankId"]]
      |> Enum.filter(&non_empty_binary?/1)
      |> Enum.uniq()

    primary_bank_id = locked.bank_id || List.first(candidate_bank_ids)
    Orders.backfill_paid_metadata!(repo, locked.mch_order_id, mch_fee, primary_bank_id)

    if non_empty_binary?(primary_bank_id) do
      for cand <- candidate_bank_ids, cand != primary_bank_id do
        Orders.upsert_duplicate_event!(repo, locked.mch_order_id, %{
          "provider_order_id" => lookup_order_id <> ":bank:" <> cand,
          "mch_order_id" => locked.mch_order_id,
          "kind" => "different_bank_id_replay",
          "bank_id" => cand,
          "recorded_at" => DateTime.to_iso8601(now)
        })
      end
    end

    base_result = %{
      status: "paid",
      idempotent: true,
      subscription_id: locked.subscription_id,
      cycle_id: locked.cycle_id
    }

    if is_nil(locked.notified_at) do
      case build_replay_notify(repo, locked) do
        %{} = notify -> Map.put(base_result, :notify, notify)
        nil -> base_result
      end
    else
      base_result
    end
  end

  defp converge_m2square_success(
         _repo,
         %{status: status},
         _pending_stripe,
         _lookup_order_id,
         _item,
         _webhook_body,
         _now
       )
       when status in ["conflict_paid", "reversed"] do
    %{status: status, idempotent: true}
  end

  defp converge_m2square_success(
         repo,
         locked,
         pending_stripe,
         lookup_order_id,
         item,
         webhook_body,
         now
       ) do
    settlement_meta = %{
      provider_order_id: lookup_order_id,
      real_amount: decimal_string(item["realAmount"]),
      mch_fee: settled_mch_fee(item["orderStatus"], item, webhook_body),
      bank_id: item["bankId"] || (webhook_body && webhook_body["bankId"]),
      paid_at: now
    }

    cond do
      not amount_and_currency_valid?(locked, item, webhook_body) ->
        Orders.mark_conflict_paid!(repo, locked.mch_order_id, settlement_meta)
        %{status: "conflict_paid", reason: :amount_or_currency_mismatch}

      m2square_channel_or_slot_conflict?(repo, locked, pending_stripe, now) ->
        Orders.mark_conflict_paid!(repo, locked.mch_order_id, settlement_meta)
        %{status: "conflict_paid", reason: :channel_or_slot_conflict}

      true ->
        grant_m2square_seats!(repo, locked, settlement_meta, now)
    end
  end

  defp grant_m2square_seats!(repo, locked, settlement_meta, now) do
    with {:ok, org} <- resolve_m2square_org(locked),
         {:ok, _} <-
           BillingCommerce.issue_bridge_platform_unlimited(%{
             billing_account_id: locked.billing_account_id,
             organization_id: org.id
           }),
         {:ok, package} <-
           BillingCommerce.PackageCatalog.get_package_version(%{
             package_code: TeamsPricing.package(),
             version: TeamsPricing.version()
           }),
         {valid_from, expires_at} = compute_m2square_period(repo, locked.billing_account_id, now),
         {:ok, sub_result} <-
           Subscriptions.create_subscription(%{
             billing_account_id: locked.billing_account_id,
             surface: "bridge",
             product_owner_type: "organization",
             product_owner_id: org.id,
             package_code: TeamsPricing.package(),
             package_version: TeamsPricing.version(),
             source_type: "m2square_term",
             source_id: "m2square_term:" <> locked.billing_account_id,
             source_event_id: "m2square:" <> locked.mch_order_id,
             idempotency_key: "m2square:term:" <> locked.billing_account_id,
             source_metadata: %{"provider" => "m2square"},
             periods: [
               %{
                 cycle_key: locked.mch_order_id,
                 valid_from: valid_from,
                 expires_at: expires_at,
                 source_event_id: "m2square:" <> locked.mch_order_id
               }
             ]
           }),
         {:ok, _} <-
           PaidCycles.record_invoice(
             sub_result.subscription,
             package,
             "m2square:" <> locked.mch_order_id,
             %{
               valid_from: valid_from,
               expires_at: expires_at,
               payment_intent_id: "m2square:" <> locked.mch_order_id,
               fully_refunded: false,
               disputes: %{},
               teams_seats: locked.teams_seats
             },
             now
           ),
         {:ok, cycle_id} <-
           find_cycle_id(repo, sub_result.subscription.id, locked.mch_order_id) do
      Orders.mark_paid!(
        repo,
        locked.mch_order_id,
        Map.merge(settlement_meta, %{
          subscription_id: sub_result.subscription.id,
          cycle_id: cycle_id
        })
      )

      %{
        status: "paid",
        idempotent: false,
        subscription_id: sub_result.subscription.id,
        cycle_id: cycle_id,
        # Only the settlement that grants the seats reaches here, once per order.
        cft_completed:
          if(
            locked.kind == "signup" and
              not (is_map(locked.signup_snapshot) and
                     locked.signup_snapshot["analytics_opt_out"] == true),
            do: %{
              purchase_id: org.id,
              source_id: locked.mch_order_id,
              provider: "m2square",
              seats: locked.teams_seats,
              email: locked.signup_snapshot && locked.signup_snapshot["email"],
              occurred_at: now
            }
          ),
        notify: %{
          mch_order_id: locked.mch_order_id,
          org_id: org.id,
          org_name: org.name,
          org_slug: org.slug,
          seats: locked.teams_seats,
          expires_at: expires_at,
          email: locked.signup_snapshot && locked.signup_snapshot["email"]
        }
      }
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp converge_m2square_reversed(_repo, %{status: "reversed"}, _lookup_order_id, _now) do
    %{status: "reversed", idempotent: true}
  end

  defp converge_m2square_reversed(repo, locked, lookup_order_id, now) do
    if non_empty_binary?(locked.cycle_id) do
      :ok =
        PaidCycles.revoke_payment_source!(
          repo,
          locked.billing_account_id,
          locked.cycle_id,
          "m2square:" <> locked.mch_order_id,
          %{
            "reason" => "m2square_reversed",
            "provider_order_id" => lookup_order_id
          }
        )
    end

    Orders.mark_reversed!(repo, locked.mch_order_id, lookup_order_id, now)
    %{status: "reversed", idempotent: false, cycle_id: locked.cycle_id}
  end

  defp resolve_m2square_org(%{kind: "signup"} = order) do
    provision_from_signup_map(
      order.product_owner_id,
      order.billing_account_id,
      order.signup_snapshot
    )
  end

  defp resolve_m2square_org(%{kind: "renewal"} = order) do
    case Orgs.get_org(order.product_owner_id) do
      {:ok, %Organization{billing_account_id: account_id} = org}
      when account_id == order.billing_account_id ->
        {:ok, org}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :teams_signup_owner_conflict}
    end
  end

  defp provision_from_signup_map(org_id, account, signup) do
    case Orgs.get_org(org_id) do
      {:ok, %Organization{billing_account_id: ^account} = org} ->
        {:ok, org}

      {:error, :not_found} when is_map(signup) ->
        candidates = slug_candidates(signup["org_name"], org_id)

        Enum.reduce_while(candidates, {:error, :teams_slug_exhausted}, fn slug, _acc ->
          case Repo.transaction(fn ->
                 with {:ok, user} <- owner_user(signup),
                      {:ok, org} <-
                        Orgs.create_org(
                          %{
                            name: signup["org_name"],
                            slug: slug,
                            billing_account_id: account
                          },
                          id: org_id
                        ),
                      {:ok, _} <-
                        %OrgMembership{}
                        |> OrgMembership.changeset(%{
                          org_id: org.id,
                          user_id: user.id,
                          role: "owner"
                        })
                        |> Repo.insert() do
                   org
                 else
                   {:error, reason} -> Repo.rollback(reason)
                 end
               end) do
            {:ok, org} ->
              {:halt, {:ok, org}}

            {:error, %Ecto.Changeset{} = cs} ->
              if slug_unique_conflict?(cs) do
                {:cont, {:error, :teams_slug_exhausted}}
              else
                {:halt, {:error, cs}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      _ ->
        {:error, :teams_signup_owner_conflict}
    end
  end

  defp slug_candidates(org_name, org_id) do
    short8 = org_id |> String.replace("-", "") |> String.slice(0, 8)
    base = slugify_org_name(org_name)

    primary =
      if base != "" do
        [base, "#{base}-#{short8}", "team-" <> org_id]
      else
        ["team-" <> org_id]
      end

    random_suffixes =
      for _ <- 1..3 do
        suffix = Base.encode16(SystemsRuntime.Proc.random_bytes(3), case: :lower)
        if base != "", do: "#{base}-#{suffix}", else: "team-#{short8}-#{suffix}"
      end

    Enum.uniq(primary ++ random_suffixes)
  end

  @reserved_org_slugs ~w(
    login signup auth orgs dashboard v1 live ready health locale logout
    dev admin api billing onboarding settings members cli
  )

  defp slugify_org_name(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if byte_size(slug) < 3 or slug in @reserved_org_slugs, do: "", else: slug
  end

  defp slugify_org_name(_), do: ""

  defp slug_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:slug, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp compute_m2square_period(repo, account_id, now) do
    valid_from =
      case Ecto.Adapters.SQL.query!(
             repo,
             """
             SELECT max(c.period_end)
             FROM billing_subscription_cycles c
             CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
             WHERE c.billing_account_id = $1
               AND c.period_start <= $2
               AND c.period_end > $2
               AND p.value->>'state' = 'paid'
               AND p.value->>'teams_seats' IS NOT NULL
               AND (p.value->>'teams_seats')::bigint > 0
             """,
             [account_id, now]
           ).rows do
        [[%DateTime{} = current_end]] -> current_end
        _ -> now
      end

    {valid_from, DateTime.shift(valid_from, month: 3)}
  end

  defp find_cycle_id(repo, subscription_id, cycle_key) do
    case Ecto.Adapters.SQL.query!(
           repo,
           """
           SELECT id
           FROM billing_subscription_cycles
           WHERE subscription_id = $1 AND cycle_key = $2
           LIMIT 1
           """,
           [subscription_id, cycle_key]
         ).rows do
      [[cycle_id]] -> {:ok, cycle_id}
      [] -> {:error, :m2square_cycle_missing}
    end
  end

  defp amount_and_currency_valid?(%{status: "quarantined"}, _item, _webhook_body), do: false

  defp amount_and_currency_valid?(locked, item, webhook_body) do
    currencies_valid? =
      Enum.all?([item["currency"], webhook_body && webhook_body["currency"]], fn
        c when is_binary(c) and c != "" -> c == locked.currency
        _ -> true
      end)

    with true <- currencies_valid?,
         {:ok, expected} <- parse_decimal(locked.locked_amount),
         {:ok, amt_dec} <- parse_decimal(item["amount"]),
         {:ok, real_dec} <- parse_decimal(item["realAmount"]),
         true <- Decimal.equal?(amt_dec, expected),
         true <- Decimal.equal?(real_dec, expected) do
      webhook_amounts_valid?(webhook_body, expected)
    else
      _ -> false
    end
  end

  defp webhook_amounts_valid?(nil, _expected), do: true

  defp webhook_amounts_valid?(webhook_body, expected) when is_map(webhook_body) do
    Enum.all?([webhook_body["amount"], webhook_body["realAmount"]], fn
      nil ->
        true

      "" ->
        true

      val ->
        case parse_decimal(val) do
          {:ok, dec} -> Decimal.equal?(dec, expected)
          _ -> false
        end
    end)
  end

  defp m2square_channel_or_slot_conflict?(repo, locked, pending_stripe, now) do
    base_conflict? =
      has_active_stripe_subscription?(repo, locked.billing_account_id) or
        stripe_checkout_pending?(pending_stripe, now) or
        Orders.paid_slot_exists?(
          repo,
          locked.billing_account_id,
          locked.target_slot,
          locked.mch_order_id
        )

    cond do
      base_conflict? ->
        true

      locked.kind == "signup" ->
        has_any_paid_cycle?(repo, locked.billing_account_id)

      locked.kind == "renewal" ->
        renewal_lock_conflict?(repo, locked, now)

      true ->
        true
    end
  end

  defp renewal_lock_conflict?(repo, locked, now) do
    case BillingCore.TeamsAccess.coverage_in_repo(repo, locked.billing_account_id, now) do
      {:ok, cov} ->
        member_count = Memberships.count_org_members(locked.product_owner_id)
        min_required = max(30, max(member_count, if(cov.active, do: cov.licensed_seats, else: 0)))

        current_target_slot =
          "after:" <> (Orders.prior_paid_cycle_id(repo, locked.billing_account_id) || "none")

        cov.has_active_stripe_subscription or
          (cov.active and cov.provider != "m2square") or
          cov.has_future_paid_cycle or
          locked.teams_seats < min_required or
          locked.target_slot != current_target_slot

      {:error, _} ->
        true
    end
  end

  defp check_stripe_m2square_overlap(repo, account_id, subscription, invoice, paid, event_id) do
    if stripe_invoice_recorded?(repo, account_id, invoice["id"]) do
      :ok
    else
      if has_overlapping_m2square_paid_cycle?(repo, account_id, paid.valid_from, paid.expires_at) do
        conflict_record = %{
          "billing_account_id" => account_id,
          "subscription_id" => subscription["id"],
          "invoice_id" => invoice["id"],
          "payment_intent_id" => paid.payment_intent_id,
          "period_start" => DateTime.to_iso8601(paid.valid_from),
          "period_end" => DateTime.to_iso8601(paid.expires_at),
          "event_id" => event_id,
          "recorded_at" => DateTime.to_iso8601(SystemsClock.utc_now())
        }

        persist_stripe_overlap_conflict!(repo, account_id, conflict_record)
        {:error, {:m2square_term_already_active, conflict_record}}
      else
        :ok
      end
    end
  end

  defp stripe_invoice_recorded?(repo, account_id, invoice_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1
      FROM billing_subscription_cycles c
      WHERE c.billing_account_id = $1
        AND (c.source_metadata->'payment_sources' ? $2)
      LIMIT 1
      """,
      [account_id, invoice_id]
    ).rows != []
  end

  defp has_overlapping_m2square_paid_cycle?(repo, account_id, period_start, period_end) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1
      FROM billing_subscription_cycles c
      JOIN billing_subscriptions s ON s.id = c.subscription_id
      CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
      WHERE c.billing_account_id = $1
        AND s.source_type = 'm2square_term'
        AND c.period_start < $3
        AND c.period_end > $2
        AND p.value->>'state' = 'paid'
        AND p.value->>'teams_seats' IS NOT NULL
        AND (p.value->>'teams_seats')::bigint > 0
      LIMIT 1
      """,
      [account_id, period_start, period_end]
    ).rows != []
  end

  defp persist_stripe_overlap_conflict!(repo, account_id, conflict_record) do
    case Ecto.Adapters.SQL.query!(
           repo,
           """
           SELECT id, source_metadata
           FROM billing_subscriptions
           WHERE billing_account_id = $1
             AND source_type = 'm2square_term'
           ORDER BY updated_at DESC, inserted_at DESC
           LIMIT 1
           FOR UPDATE
           """,
           [account_id]
         ).rows do
      [[sub_id, raw_metadata]] ->
        metadata = BillingCore.Metadata.object(raw_metadata)
        existing = metadata["stripe_overlap_conflicts"] || []

        updated =
          if Enum.any?(existing, &(&1["invoice_id"] == conflict_record["invoice_id"])) do
            existing
          else
            existing ++ [conflict_record]
          end

        Ecto.Adapters.SQL.query!(
          repo,
          """
          UPDATE billing_subscriptions
          SET source_metadata = $2::jsonb,
              updated_at = $3
          WHERE id = $1
          """,
          [sub_id, Map.put(metadata, "stripe_overlap_conflicts", updated), SystemsClock.utc_now()]
        )

        :ok

      [] ->
        :ok
    end
  end

  defp maybe_record_stripe_overlap_audit(org_id, conflict_record) do
    case Orgs.get_org(org_id) do
      {:ok, org} ->
        _ =
          Observability.record_audit(%{
            org_id: org.id,
            actor_type: "system",
            actor_label: "billing_stripe",
            action: "billing.stripe.m2square_overlap_conflict",
            target: "stripe_invoice:" <> (conflict_record["invoice_id"] || "unknown"),
            resource_type: "billing_subscription",
            resource_id: conflict_record["invoice_id"],
            resource_label: conflict_record["subscription_id"],
            result: "denied",
            reason_class: "m2square_term_already_active",
            metadata: conflict_record
          })

        :ok

      _ ->
        :ok
    end
  end

  defp has_active_stripe_subscription?(repo, account_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1 FROM billing_subscriptions
      WHERE billing_account_id = $1
        AND source_type = 'stripe_subscription'
        AND status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused')
      LIMIT 1
      """,
      [account_id]
    ).rows != []
  end

  defp stripe_checkout_pending?(pending, now) when is_map(pending) do
    expires_at = get_in(pending, ["request", "expires_at"]) || 0

    is_integer(expires_at) and expires_at > DateTime.to_unix(now) and
      pending["stage"] != "expired"
  end

  defp stripe_checkout_pending?(_, _), do: false

  defp has_any_paid_cycle?(repo, account_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1
      FROM billing_subscription_cycles c
      CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
      WHERE c.billing_account_id = $1
        AND p.value->>'state' = 'paid'
        AND p.value->>'teams_seats' IS NOT NULL
        AND (p.value->>'teams_seats')::bigint > 0
      LIMIT 1
      """,
      [account_id]
    ).rows != []
  end

  defp maybe_send_m2square_confirmation_email(notify) do
    _ =
      SystemsRuntime.TaskSupervisor.start_child(BridgeForTeams.TaskSupervisor, fn ->
        repo = billing_repo()

        if Orders.claim_notification_send?(repo, notify.mch_order_id, SystemsClock.utc_now()) do
          try do
            recipient = resolve_notification_recipient(notify)

            if TeamsMail.configured?() and non_empty_binary?(recipient) do
              {subject, body} =
                confirmation_email_content(
                  notify.org_name,
                  notify.org_slug,
                  notify.seats,
                  notify.expires_at
                )

              case TeamsMail.send_message(recipient, subject, body) do
                {:ok, _} ->
                  Orders.mark_notified!(repo, notify.mch_order_id, SystemsClock.utc_now())
                  :ok

                {:error, reason} ->
                  Orders.release_notification_claim!(repo, notify.mch_order_id)

                  Logger.warning(
                    "m2square confirmation email failed: mch_order_id=#{notify.mch_order_id} reason=#{inspect(reason)}"
                  )
              end
            else
              Orders.release_notification_claim!(repo, notify.mch_order_id)
            end
          rescue
            error ->
              Orders.release_notification_claim!(repo, notify.mch_order_id)

              Logger.warning(
                "m2square confirmation email crashed: mch_order_id=#{notify.mch_order_id} error=#{inspect(error)}"
              )
          end
        end
      end)

    :ok
  end

  defp resolve_notification_recipient(%{email: email}) when is_binary(email) and email != "" do
    email
  end

  defp resolve_notification_recipient(%{org_id: org_id}) do
    Memberships.first_owner_email(org_id)
  end

  defp verify_webhook_signature(raw_body, sign_header, cfg) do
    case Signing.verify_webhook(raw_body, sign_header, cfg.secret_key) do
      :ok -> :ok
      {:error, _} -> {:error, :unauthorized}
    end
  end

  defp decode_webhook_json(raw_body) do
    case Jason.decode(raw_body, floats: :decimals) do
      {:ok, %{} = body} -> {:ok, body}
      _ -> {:error, :bad_request}
    end
  end

  defp cast_uuid_for_quote(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :quote_expired}
    end
  end

  defp cast_uuid_for_quote(_), do: {:error, :quote_expired}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_teams_signup}
    end
  end

  defp enabled_country_in_cfg(cfg, code) do
    case Config.enabled_country(cfg, code) do
      {:ok, country_cfg} -> {:ok, country_cfg}
      _ -> {:error, :m2square_country_unavailable}
    end
  end

  defp resolve_quoted_country(live_country, %{"countries" => %{} = snap_countries}) do
    with {:ok, %{} = snap_country} <- Map.fetch(snap_countries, live_country.code),
         true <-
           snap_country["currency"] == live_country.gateway_currency and
             snap_country["scale"] == live_country.scale,
         true <-
           is_integer(snap_country["min_seats"]) and is_integer(snap_country["max_seats"]) and
             snap_country["min_seats"] <= snap_country["max_seats"],
         snap_pts when is_list(snap_pts) <- snap_country["payment_types"],
         allowed_pts = Enum.filter(live_country.payment_types, &(&1 in snap_pts)),
         true <- allowed_pts != [] do
      base_id_types =
        if live_country.code == "EC" and "NET_BANKING" not in allowed_pts do
          Enum.filter(live_country.id_types, &(&1 in ["CI", "RUC"]))
        else
          live_country.id_types
        end

      allowed_id_types =
        case snap_country["id_types"] do
          snap_ids when is_list(snap_ids) ->
            Enum.filter(base_id_types, &(&1 in snap_ids))

          _ ->
            base_id_types
        end

      country_for_checkout =
        live_country
        |> Map.put(:payment_types, allowed_pts)
        |> Map.put(:id_types, allowed_id_types)
        |> Map.put(:fee_rate, snap_country["fee_rate"])

      {:ok, snap_country, country_for_checkout}
    else
      _ -> {:error, :m2square_country_unavailable}
    end
  end

  defp resolve_quoted_country(_live_country, _snapshot),
    do: {:error, :m2square_country_unavailable}

  defp validate_stripe_seat_min(raw, required_min) do
    case seat_count(raw) do
      seats when is_integer(seats) and seats >= required_min and seats <= 2_147_483_647 ->
        {:ok, seats}

      seats when is_integer(seats) and seats > 2_147_483_647 ->
        {:error, {:invalid_seats_range, required_min, 2_147_483_647}}

      _ ->
        {:error, {:invalid_seats_min, required_min}}
    end
  end

  defp validate_seat_range(raw, min_seats, max_seats)
       when is_integer(min_seats) and is_integer(max_seats) do
    case seat_count(raw) do
      seats when is_integer(seats) and seats >= min_seats and seats <= max_seats ->
        {:ok, seats}

      _ ->
        {:error, {:invalid_seats_range, min_seats, max_seats}}
    end
  end

  defp validate_seat_range(_raw, _min_seats, _max_seats), do: {:error, :invalid_seats}

  defp m2square_seat_count(raw) do
    case seat_count(raw) do
      seats when is_integer(seats) and seats in 30..48 -> {:ok, seats}
      _ -> {:error, :invalid_seats}
    end
  end

  defp m2square_signup_snapshot(attrs) when is_map(attrs) do
    email = text(attrs["email"]) |> String.downcase()
    org_name = text(attrs["org_name"])
    name = text(attrs["name"])

    if byte_size(email) <= 254 and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email) and
         byte_size(org_name) in 1..200 and byte_size(name) <= 200 do
      {:ok, %{"email" => email, "org_name" => org_name, "name" => name}}
    else
      {:error, :invalid_teams_signup}
    end
  end

  defp validate_payer(country_cfg, attrs) do
    case Payer.validate_and_build_pay_fields(country_cfg, attrs) do
      {:ok, payer} -> {:ok, payer}
      {:error, field_reason} -> {:error, {:payer_invalid, field_reason}}
    end
  end

  defp parse_decimal(%Decimal{} = value), do: {:ok, value}
  defp parse_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = dec, ""} -> {:ok, dec}
      _ -> :error
    end
  end

  defp parse_decimal(_), do: :error

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal_string(v) when is_binary(v), do: v
  defp decimal_string(v) when is_integer(v), do: Integer.to_string(v)
  defp decimal_string(_), do: nil

  defp billing_repo, do: SystemsRuntime.fetch_env!(:billing_commerce, :repo)

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
end
