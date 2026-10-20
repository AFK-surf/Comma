defmodule Comma.Analytics.Export do
  @moduledoc false
  import Ecto.Query
  alias Comma.Accounts.User
  alias Comma.{Analytics, Repo}

  @page_size 100
  @user_fields [:id, :email, :kind, :status, :locale, :created_at, :updated_at]

  # Bound the entire DB + HTTP attempt, including a peer that never ends a body.
  def attempt(fun) do
    task = SystemsRuntime.Task.async(fn -> safely(fun) end)

    case SystemsRuntime.Task.yield(task, 15_000) || SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :retryable}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :retryable}
  catch
    _, _ -> {:error, :retryable}
  end

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

    events = users |> Enum.filter(&eligible?/1) |> Enum.flat_map(&profile_events/1)

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

    events =
      Enum.flat_map(entries, fn entry ->
        case users[entry.user_id] do
          %User{} = user ->
            cond do
              not eligible?(user) -> []
              entry.event == :profile -> profile_events(user)
              entry.event == :registration -> profile_events(user) ++ [registration_event(user)]
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

  defp profile_events(user) do
    observed_at = SystemsClock.utc_now()

    [
      envelope(
        user.id,
        "$identify",
        "profile:#{user.id}:#{DateTime.to_iso8601(observed_at)}",
        observed_at,
        %{
          "$set" => %{
            "email" => user.email,
            "created_at" => DateTime.to_iso8601(user.created_at),
            "user_kind" => user.kind,
            "locale" => user.locale,
            "account_status" => user.status,
            "is_internal" => Analytics.internal_user?(user.email)
          }
        }
      )
    ]
  end

  defp registration_event(user) do
    envelope(user.id, "comma_user_registered", user.id, user.created_at, %{
      "user_kind" => "registered",
      "source" => "account_created",
      "is_internal" => Analytics.internal_user?(user.email)
    })
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
  defp event_uuid(event, user_id, source_id) do
    <<a::32, b::16, c::12, d::62, _::bitstring>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({"comma.analytics.v1", event, user_id, source_id})
      )

    Ecto.UUID.load!(<<a::32, b::16, 8::4, c::12, 2::2, d::62>>)
  end

  defp deliver([]), do: :ok

  defp deliver(events) do
    if Analytics.configured?(),
      do: Comma.Analytics.PostHog.send_batch(events),
      else: {:error, :rejected}
  end
end
