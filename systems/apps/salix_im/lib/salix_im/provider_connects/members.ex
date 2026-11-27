defmodule SalixIM.ProviderConnects.Members do
  @moduledoc """
  Whose people a Slack, Feishu or Lark connect's people are: the connect's
  **member scope** and its **member grants**, two values on the connect record
  (`SalixIM.ProviderConnects`). A connect says that the bot may talk in a
  workspace or tenant; its member scope is an admin's separate statement about
  the people there.

    * `"organization"`: the workspace's or tenant's own members are the
      organization's people (`SalixIM.ProviderAccounts.app_member/2` decides
      who is a member, on every call).
    * `"external"`: the people there are not the organization's, except those
      an admin granted by name (`"member_grants"`).

  A record without the field is `"organization"`, for Slack, Feishu and Lark
  alike. A new connect writes the field.

  A grant is `%{"subject", "name", "email", "expires_at", "granted_by",
  "granted_at"}`: the provider user id, the name and email the provider gave
  for it when it was granted, and an expiry in unix milliseconds or nil. A
  connect has at most 100 grants. An expired grant does not count, and the
  next write drops it.

  `CommaWeb.Stations` reads both for station tools in a Comma for Teams
  Project (owner decision, Jinfei Yang, 2026-11-14; `docs/architecture/DOMAIN_CONCEPTS.md`).
  """

  alias SalixIM.GroupDirectory
  alias SalixIM.IFC.People
  alias SalixStore.{CasRecord, Keys}

  @providers ~w(slack feishu lark)
  @scopes ~w(organization external)
  @grants_max 100
  @grant_days [1, 7, 30]
  @day_ms 86_400_000

  @doc "The member scope values."
  def scopes, do: @scopes

  @doc "The connect's member scope: its value, else `\"organization\"`."
  @spec member_scope(map()) :: String.t()
  def member_scope(%{"member_scope" => scope}) when scope in @scopes, do: scope
  def member_scope(_rec), do: "organization"

  @doc "The member scope a new connect writes: `attrs[\"member_scope\"]` when valid."
  @spec initial_scope(map()) :: String.t()
  def initial_scope(%{"member_scope" => scope}) when scope in @scopes, do: scope
  def initial_scope(_attrs), do: "organization"

  @doc "The connect's grants that have not expired."
  @spec member_grants(map()) :: [map()]
  def member_grants(rec) when is_map(rec), do: live(rec["member_grants"], now())
  def member_grants(_rec), do: []

  @doc "The live grant of `subject` on the connect, or nil."
  @spec member_grant(map(), String.t()) :: map() | nil
  def member_grant(rec, subject) when is_binary(subject) and subject != "",
    do: Enum.find(member_grants(rec), &(&1["subject"] == subject))

  def member_grant(_rec, _subject), do: nil

  @doc "Sets the connect's member scope. Returns the connect's public shape."
  def set_scope(tenant_id, group_id, connect_id, scope) when scope in @scopes do
    write(tenant_id, group_id, connect_id, fn rec, _now ->
      {:ok, Map.put(rec, "member_scope", scope)}
    end)
  end

  def set_scope(_tenant_id, _group_id, _connect_id, _scope), do: {:error, :invalid_member_scope}

  @doc """
  Grants `subject` the people's access on the connect for `expires_in_days`
  (1, 7 or 30) or without expiry (nil). The provider names the person now;
  a person it cannot read is not granted. A grant for a subject replaces that
  subject's earlier grant.
  """
  def grant(tenant_id, group_id, connect_id, subject, expires_in_days, granted_by \\ nil)

  def grant(tenant_id, group_id, connect_id, subject, expires_in_days, granted_by)
      when is_binary(subject) and (is_nil(expires_in_days) or expires_in_days in @grant_days) do
    subject = String.trim(subject)

    with true <- subject != "" and byte_size(subject) <= 128,
         {:ok, connect} <- connect(tenant_id, group_id, connect_id),
         {:ok, person} <- person(connect, subject) do
      write(tenant_id, group_id, connect_id, fn rec, now ->
        grants = Enum.reject(live(rec["member_grants"], now), &(&1["subject"] == subject))

        if length(grants) >= @grants_max do
          {:error, :too_many_member_grants}
        else
          grant = %{
            "subject" => subject,
            "name" => person["name"],
            "email" => person["email"],
            "expires_at" => if(expires_in_days, do: now + expires_in_days * @day_ms),
            "granted_by" => text(granted_by),
            "granted_at" => now
          }

          {:ok, Map.put(rec, "member_grants", grants ++ [grant])}
        end
      end)
    else
      false -> {:error, :invalid_member_grant}
      {:error, _reason} = error -> error
    end
  end

  def grant(_tenant_id, _group_id, _connect_id, _subject, _days, _granted_by),
    do: {:error, :invalid_member_grant}

  @doc "Removes `subject`'s grant from the connect (no grant is no change)."
  def revoke(tenant_id, group_id, connect_id, subject) when is_binary(subject) do
    write(tenant_id, group_id, connect_id, fn rec, now ->
      {:ok,
       Map.put(
         rec,
         "member_grants",
         Enum.reject(live(rec["member_grants"], now), &(&1["subject"] == subject))
       )}
    end)
  end

  def revoke(_tenant_id, _group_id, _connect_id, _subject), do: {:error, :invalid_member_grant}

  @doc """
  Up to 20 people of the connect whose name or email matches `query`, or the
  one person a provider user id names, for the grant picker
  (`SalixIM.IFC.People.find/4`). `"complete"` is false when the bounded search
  could not read the whole directory.
  """
  def people(tenant_id, group_id, connect_id, query) do
    with {:ok, _connect} <- connect(tenant_id, group_id, connect_id),
         {:ok, people, complete?} <- People.find(tenant_id, group_id, connect_id, query) do
      {:ok,
       %{
         "people" =>
           Enum.map(
             people,
             &%{"subject" => &1["id"], "name" => &1["name"], "email" => &1["email"]}
           ),
         "complete" => complete?
       }}
    end
  end

  # ---------------------------------------------------------------------------

  defp write(tenant_id, group_id, connect_id, change) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, _connect} <- connect(tenant_id, group_id, connect_id) do
      key = Keys.ctl_im_connect(group_id, connect_id)

      result =
        CasRecord.update(
          key,
          fn rec ->
            now = now()

            case change.(rec, now) do
              {:ok, next} ->
                next
                |> Map.update("member_grants", [], &live(&1, now))
                |> Map.put("updated_at", now)

              {:error, _reason} = error ->
                error
            end
          end,
          create: false
        )

      case result do
        {:ok, rec} -> {:ok, SalixIM.ProviderConnects.connect_public(rec)}
        other -> other
      end
    end
  end

  defp connect(tenant_id, group_id, connect_id) when is_binary(connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, String.trim(connect_id))) do
      {:ok, %{"tenant_id" => ^tenant_id, "provider" => provider} = rec}
      when provider in @providers ->
        if rec["deleted_at"], do: {:error, :not_found}, else: {:ok, rec}

      {:ok, %{"tenant_id" => ^tenant_id} = rec} ->
        if rec["deleted_at"], do: {:error, :not_found}, else: {:error, :unsupported_provider}

      {:ok, _other_tenant} ->
        {:error, :not_found}

      other ->
        other
    end
  end

  defp connect(_tenant_id, _group_id, _connect_id), do: {:error, :not_found}

  defp person(connect, subject) do
    case People.describe(connect, [subject]) do
      %{^subject => %{} = person} -> {:ok, person}
      _unknown -> {:error, :person_not_found}
    end
  end

  defp live(grants, now) when is_list(grants) do
    Enum.filter(grants, fn
      %{"subject" => subject, "expires_at" => nil} when is_binary(subject) ->
        true

      %{"subject" => subject, "expires_at" => at} when is_binary(subject) ->
        is_integer(at) and at > now

      _invalid ->
        false
    end)
  end

  defp live(_grants, _now), do: []

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp now, do: SystemsClock.system_time(:millisecond)
end
