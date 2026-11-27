defmodule Comma.Analytics.Export do
  @moduledoc false
  import Ecto.Query
  alias Comma.Accounts.User
  alias Comma.{Analytics, Repo}
  require Logger

  @page_size 100
  @user_fields [:id, :email, :kind, :status, :locale, :created_at, :updated_at]

  # Bound the entire DB + HTTP attempt, including a peer that never ends a body.
  defdelegate attempt(fun), to: ProductAnalytics

  # The existing User primary key bounds both the scan and each restart page.
  def page(after_id \\ "") do
    users =
      Repo.all(
        from(u in User,
          where: u.id > ^after_id,
          order_by: u.id,
          limit: @page_size,
          select: struct(u, @user_fields)
        )
      )

    eligible = Enum.filter(users, &eligible?/1)
    plans = plans(eligible)
    events = Enum.flat_map(eligible, &profile_events(&1, plans))

    with :ok <- deliver(events) do
      {:ok, if(length(users) == @page_size, do: List.last(users).id, else: nil)}
    end
  end

  def entries([]), do: :ok

  def entries(entries) do
    group_ids =
      entries |> Enum.map(&Map.get(&1, :group_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    workspaces =
      Repo.all(
        from(w in Comma.Data.Workspace,
          where: w.salix_group_id in ^group_ids and w.kind == "standard"
        )
      )
      |> Map.new(&{&1.salix_group_id, &1})

    entries =
      Enum.flat_map(entries, fn entry ->
        case Map.get(entry, :group_id) do
          nil ->
            [entry]

          group_id ->
            case workspaces[group_id] do
              nil ->
                []

              workspace ->
                [
                  %{
                    entry
                    | user_id: workspace.owner_user_id,
                      properties: Map.put(entry.properties, "workspace_id", workspace.id)
                  }
                ]
            end
        end
      end)

    ids = entries |> Enum.map(& &1.user_id) |> Enum.uniq()

    users =
      Repo.all(from(u in User, where: u.id in ^ids, select: struct(u, @user_fields)))
      |> Map.new(&{&1.id, &1})

    plans =
      entries
      |> Enum.filter(&(&1.event in [:profile, :registration]))
      |> Enum.flat_map(&List.wrap(users[&1.user_id]))
      |> Enum.filter(&eligible?/1)
      |> plans()

    events =
      Enum.flat_map(entries, fn entry ->
        case users[entry.user_id] do
          %User{} = user ->
            cond do
              not eligible?(user) -> []
              entry.event == :profile -> profile_events(user, plans)
              entry.event == :registration -> registration_events(user, entry, plans)
              user.status != "active" -> []
              true -> [activity_event(user, entry)]
            end

          nil ->
            []
        end
      end)

    deliver(events)
  end

  defp eligible?(user) do
    user.kind == "registered" and
      user.id not in Analytics.excluded_user_ids(Analytics.config()[:excluded_user_ids])
  end

  # A redeemed code's subscription keeps its status after its last period: it
  # counts only while one of its periods is still open.
  @active_subscription_sql """
  SELECT DISTINCT ON (s.billing_account_id)
    s.billing_account_id, s.package_code, s.source_type, s.inserted_at, s.id
  FROM billing_subscriptions s
  WHERE s.billing_account_id = ANY($1)
    AND s.status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused')
    AND (
      s.source_type <> 'internal_subscription'
      OR EXISTS (
        SELECT 1 FROM billing_subscription_cycles c
        WHERE c.subscription_id = s.id AND c.period_end > $2
      )
    )
  ORDER BY s.billing_account_id, s.inserted_at DESC, s.id DESC
  """

  # The `plan` and `plan_source` of each User: the active subscription of the
  # Workspace they own, as the billing summary names it. A User who owns more
  # than one subscribed Workspace gets the newest subscription, so the
  # properties do not change between refreshes. Two indexed reads for a batch
  # of at most one page. A failed read sets neither property, so a profile
  # never claims `free` for a plan it could not read, and logs a warning.
  defp plans([]), do: %{}

  defp plans(users) do
    owners =
      Repo.all(
        from(w in Comma.Data.Workspace,
          where:
            w.owner_user_id in ^Enum.map(users, & &1.id) and w.kind == "standard" and
              w.status != "deleted" and not is_nil(w.billing_owner_id),
          select: {w.billing_owner_id, w.owner_user_id}
        )
      )
      |> Map.new()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(BillingCore.Repo, @active_subscription_sql, [
        Map.keys(owners),
        SystemsClock.utc_now()
      ])

    subscribed =
      rows
      |> Enum.group_by(fn [account | _] -> owners[account] end)
      |> Map.new(fn {owner, owned} ->
        [_account, package_code, source_type, _inserted_at, _id] =
          Enum.max_by(owned, fn [_, _, _, %DateTime{} = inserted_at, id] ->
            {DateTime.to_unix(inserted_at, :microsecond), id}
          end)

        {owner, %{"plan" => package_code, "plan_source" => plan_source(source_type)}}
      end)

    Map.new(users, &{&1.id, subscribed[&1.id] || %{"plan" => "free", "plan_source" => "none"}})
  rescue
    error ->
      Logger.warning("analytics plan read failed: #{inspect(error.__struct__)}")
      %{}
  catch
    kind, _reason ->
      Logger.warning("analytics plan read failed: #{kind}")
      %{}
  end

  defp plan_source("stripe_subscription"), do: "stripe"
  defp plan_source("apple_subscription"), do: "apple"
  defp plan_source("google_subscription"), do: "google"
  # A redeemed code's subscription (`BillingCommerce.RedeemCodes`).
  defp plan_source("internal_subscription"), do: "redeem"
  defp plan_source(_source_type), do: "other"

  defp profile_events(user, plans) do
    observed_at = SystemsClock.utc_now()

    [
      envelope(
        user.id,
        "$identify",
        "profile:#{user.id}:#{DateTime.to_iso8601(observed_at)}",
        observed_at,
        %{
          "$set" =>
            Map.merge(
              %{
                "email" => user.email,
                "created_at" => DateTime.to_iso8601(user.created_at),
                "user_kind" => user.kind,
                "locale" => user.locale,
                "account_status" => user.status,
                "is_internal" => Analytics.internal_user?(user.email)
              },
              Map.get(plans, user.id, %{})
            )
        }
      )
    ]
  end

  defp registration_events(user, entry, plans) do
    profile_events(user, plans) ++
      [
        envelope(
          user.id,
          "comma_user_registered",
          user.id,
          user.created_at,
          Map.merge(entry.properties, %{
            "user_kind" => "registered",
            "source" => "account_created",
            "is_internal" => Analytics.internal_user?(user.email)
          })
        )
      ]
  end

  defp activity_event(user, entry) do
    envelope(
      user.id,
      entry.event,
      entry.source_id,
      entry.occurred_at,
      Map.merge(entry.properties, %{
        "user_kind" => user.kind,
        "is_internal" => Analytics.internal_user?(user.email)
      })
    )
  end

  defp envelope(user_id, event, source_id, time, properties) do
    %{
      event: event,
      distinct_id: user_id,
      uuid: event_uuid(event, user_id, source_id),
      timestamp: DateTime.to_iso8601(time),
      properties:
        Map.merge(properties, %{
          "producer" => "comma_server",
          "environment" => Analytics.config()[:environment],
          "schema_version" => 1,
          "$geoip_disable" => true
        })
    }
  end

  # A deterministic UUID is a retry/deduplication key, never an authenticity check.
  # Its only authority is the existing source record's identity.
  defp event_uuid(event, user_id, source_id),
    do: ProductAnalytics.event_uuid({"comma.analytics.v1", event, user_id, source_id})

  defp deliver([]), do: :ok

  defp deliver(events) do
    if Analytics.configured?(),
      do: Comma.Analytics.PostHog.send_batch(events),
      else: {:error, :rejected}
  end
end
