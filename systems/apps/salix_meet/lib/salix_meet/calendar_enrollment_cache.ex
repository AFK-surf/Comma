defmodule SalixMeet.CalendarEnrollmentCache do
  @moduledoc false

  alias SalixStore.{Crypto, Ids, Keys, S3}

  @version 5
  @source_activation_proof %{"status" => "ready", "version" => 1}
  @write_attempts 3

  @spec fingerprint(map()) :: String.t()
  def fingerprint(entry) do
    entry
    |> canonical_entry()
    |> Jason.encode!()
    |> Crypto.hex()
  end

  @spec load(map(), map() | nil) ::
          {:ok, %{group: map(), identity: map(), at: non_neg_integer()}}
          | {:error, term()}
  def load(entry, expected_identity \\ nil) do
    key = key(entry)

    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, document} when is_map(document) <- Jason.decode(body),
         {:ok, cached} <- validate(document, entry, expected_identity) do
      {:ok, cached}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_enrollment_cache}
    end
  end

  @spec put(map(), map(), map(), non_neg_integer()) :: :ok | {:error, term()}
  def put(entry, identity, group, now_ms) do
    document = %{
      "version" => @version,
      "connect_id" => trim(entry["connect_id"]),
      "fingerprint" => fingerprint(entry),
      "identity" => normalized_identity(identity),
      "group" => persistable_group(group),
      "source_activation" => @source_activation_proof,
      "resolved_at_ms" => now_ms
    }

    with {:ok, _cached} <- validate(document, entry, identity) do
      encoded = Jason.encode!(document)
      put_cas(key(entry), encoded, @write_attempts)
    end
  end

  @spec delete(map()) :: :ok | {:error, term()}
  def delete(entry), do: S3.delete(key(entry))

  @doc false
  @spec sanitize_group(map()) :: map()
  def sanitize_group(group), do: persistable_group(group)

  @spec identity_matches?(map(), map()) :: boolean()
  def identity_matches?(cached, identity) do
    is_map(cached) and normalized_identity(cached[:identity]) == normalized_identity(identity)
  end

  defp validate(document, entry, expected_identity) do
    identity = normalized_identity(document["identity"])
    group = document["group"]
    expected = expected_identity && normalized_identity(expected_identity)

    valid? =
      document["version"] == @version and
        document["connect_id"] == trim(entry["connect_id"]) and
        document["fingerprint"] == fingerprint(entry) and
        document["source_activation"] == @source_activation_proof and
        valid_identity?(identity) and
        (is_nil(expected) or identity == expected) and
        valid_group?(group, identity) and
        is_integer(document["resolved_at_ms"]) and document["resolved_at_ms"] >= 0

    if valid? do
      {:ok, %{group: group, identity: identity, at: document["resolved_at_ms"]}}
    else
      {:error, :invalid_calendar_enrollment_cache}
    end
  end

  defp valid_identity?(identity) do
    Enum.all?(["connect_id", "tenant_id", "group_id", "provider"], &(trim(identity[&1]) != "")) and
      identity["provider"] in ["slack", "feishu"]
  end

  defp valid_group?(group, identity) when is_map(group) do
    calendars = group["calendars"]

    group["connect_id"] == identity["connect_id"] and group["provider"] == identity["provider"] and
      group["tenant_id"] == identity["tenant_id"] and
      group["group_id"] == identity["group_id"] and valid_target?(group) and
      Ids.valid_calendar_id?(group["calendar_id"]) and is_list(calendars) and calendars != [] and
      Enum.all?(calendars, &valid_calendar?/1)
  end

  defp valid_group?(_group, _identity), do: false

  defp valid_target?(%{"provider" => "slack", "mode" => mode} = group)
       when mode in ["join", "prepare"],
       do: trim(group["channel_id"]) != ""

  defp valid_target?(%{"provider" => "feishu", "mode" => "notify"} = group) do
    trim(group["chat_id"]) != "" and valid_calendar?(group["create_calendar"]) and
      valid_mentions?(group["mentions"])
  end

  defp valid_target?(_group), do: false

  defp valid_mentions?(%{"mode" => mode, "users" => []}) when mode in ["none", "all"], do: true

  defp valid_mentions?(%{"mode" => "users", "users" => users}) when is_list(users) do
    length(users) in 1..50 and
      Enum.all?(users, fn user ->
        is_map(user) and trim(user["user_id"]) != "" and trim(user["name"]) != ""
      end)
  end

  defp valid_mentions?(_mentions), do: false

  defp valid_calendar?(calendar) when is_map(calendar),
    do:
      trim(calendar["account_id"]) != "" and trim(calendar["calendar_id"]) != "" and
        Ids.valid_calendar_source_id?(calendar["source_id"])

  defp valid_calendar?(_calendar), do: false

  defp normalized_identity(identity) when is_map(identity) do
    %{
      "connect_id" => trim(identity["connect_id"] || identity[:connect_id]),
      "tenant_id" => trim(identity["tenant_id"] || identity[:tenant_id]),
      "group_id" => trim(identity["group_id"] || identity[:group_id]),
      "provider" => trim(identity["provider"] || identity[:provider] || "slack")
    }
  end

  defp normalized_identity(_identity),
    do: %{"connect_id" => "", "tenant_id" => "", "group_id" => "", "provider" => ""}

  defp persistable_group(group) when is_map(group) do
    provider = trim(group["provider"] || "slack")

    base =
      %{
        "tenant_id" => trim(group["tenant_id"]),
        "group_id" => trim(group["group_id"]),
        "connect_id" => trim(group["connect_id"]),
        "provider" => provider,
        "mode" => trim(group["mode"] || if(provider == "slack", do: "join", else: "")),
        "workspace_id" => trim(group["workspace_id"]),
        "channel_id" => trim(group["channel_id"]),
        "calendars" => Enum.map(List.wrap(group["calendars"]), &persistable_calendar/1)
      }
      |> put_nonblank("calendar_id", group["calendar_id"])
      |> put_writeback(group)
      |> Map.merge(
        Map.take(
          group,
          ~w(preparation_lead_minutes research_enabled series personal_preparation settings_revision)
        )
      )

    if base["provider"] == "feishu" do
      base
      |> Map.put("chat_id", trim(group["chat_id"]))
      |> Map.put("create_calendar", persistable_create_calendar(group["create_calendar"]))
      |> Map.put("mentions", persistable_mentions(group["mentions"]))
    else
      base
    end
  end

  defp persistable_group(_group), do: %{}

  defp persistable_calendar(calendar) when is_map(calendar) do
    %{
      "account_id" => trim(calendar["account_id"]),
      "calendar_id" => trim(calendar["calendar_id"])
    }
    |> put_nonblank("source_id", calendar["source_id"])
  end

  defp persistable_calendar(_calendar), do: %{}

  defp persistable_create_calendar(calendar) when is_map(calendar) do
    calendar
    |> persistable_calendar()
    |> Map.put("name", trim(calendar["name"]))
  end

  defp persistable_create_calendar(_calendar), do: %{}

  defp persistable_mentions(%{"mode" => mode, "users" => users}) do
    %{
      "mode" => trim(mode),
      "users" =>
        Enum.map(List.wrap(users), fn user ->
          %{"user_id" => trim(user["user_id"]), "name" => trim(user["name"])}
        end)
    }
  end

  defp persistable_mentions(_mentions), do: %{}

  defp put_nonblank(map, key, value) do
    case trim(value) do
      "" -> map
      value -> Map.put(map, key, value)
    end
  end

  defp put_writeback(map, %{"calendar_writeback" => true}),
    do: Map.put(map, "calendar_writeback", true)

  defp put_writeback(map, _source), do: map

  defp canonical_entry(entry) do
    base = %{
      "connect_id" => trim(entry["connect_id"]),
      "calendars" =>
        entry["calendars"]
        |> List.wrap()
        |> Enum.map(&normalize/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
    }

    base =
      base
      |> put_writeback(entry)
      |> Map.merge(
        Map.take(
          entry,
          ~w(channel_id preparation_lead_minutes research_enabled series personal_preparation settings_revision)
        )
      )

    base = if entry["mode"] == "prepare", do: Map.put(base, "mode", "prepare"), else: base

    base =
      if is_list(entry["calendar_selections"]) do
        Map.put(
          base,
          "calendar_selections",
          entry["calendar_selections"]
          |> Enum.map(&Map.take(&1, ~w(account_id calendar_id)))
          |> Enum.sort_by(&{&1["account_id"], &1["calendar_id"]})
        )
      else
        base
      end

    if trim(entry["mode"]) == "notify" do
      base
      |> Map.put("mode", "notify")
      |> Map.put("chat_id", trim(entry["chat_id"]))
      |> Map.put("create_calendar", normalize(entry["create_calendar"]))
      |> Map.put("mentions", persistable_mentions(entry["mentions"]))
    else
      Map.put(base, "channel", entry["channel"] |> normalize() |> String.trim_leading("#"))
    end
  end

  defp key(entry) do
    Keys.ctl_meet_calendar_enrollment(trim(entry["connect_id"]), fingerprint(entry))
  end

  defp put_cas(_key, _encoded, 0), do: {:error, :calendar_enrollment_cache_conflict}

  defp put_cas(key, encoded, attempts_left) do
    case S3.get(key) do
      {:ok, %{etag: etag}} ->
        finish_put(key, encoded, [if_match: etag], attempts_left)

      {:error, :not_found} ->
        finish_put(key, encoded, [if_none_match: "*"], attempts_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_put(key, encoded, opts, attempts_left) do
    case S3.put(key, encoded, opts) do
      {:ok, _} ->
        :ok

      {:error, :precondition_failed} ->
        put_cas(key, encoded, attempts_left - 1)

      {:error, {:ambiguous, _}} = error ->
        case S3.get(key) do
          {:ok, %{body: ^encoded}} -> :ok
          {:ok, _} -> put_cas(key, encoded, attempts_left - 1)
          _ -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize(value), do: value |> trim() |> String.downcase()
  defp trim(value), do: value |> to_string() |> String.trim()
end
