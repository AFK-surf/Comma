defmodule CommaWeb.RecommendationComposioMemberSource do
  @moduledoc false

  alias CommaWeb.RecommendationMemberRead

  @slack "https://slack.com/api"
  @gmail "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar "https://www.googleapis.com/calendar/v3/calendars/primary"
  @drive "https://www.googleapis.com/drive/v3"
  @graph "https://graph.microsoft.com/v1.0"

  # Confirmation reads only the account's own identity. It never fetches mail,
  # messages, events, or files before the owner approves this exact account.
  def identify(workspace, toolkit, id)
      when toolkit in ~w(slack gmail googlecalendar googledrive outlook) and is_binary(id) do
    with {:ok, settings} <- settings().get(workspace["salix_tenant_id"]),
         {:ok, identity} <-
           with_proxy(
             settings,
             workspace,
             id,
             toolkit,
             RecommendationMemberRead.deadline(),
             &identity(toolkit, &1)
           ) do
      {:ok, identity}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  def identify(_workspace, _toolkit, _id), do: {:error, :member_source_unsupported}

  defp identity("slack", request) do
    case request.("GET", @slack <> "/auth.test", []) do
      {:ok, %{"bot_id" => bot_id}} when is_binary(bot_id) and bot_id != "" ->
        {:error, :member_account_not_personal}

      {:ok, %{"ok" => true, "user_id" => user, "team_id" => team} = auth}
      when is_binary(user) and is_binary(team) ->
        if Regex.match?(~r/^[UW][A-Z0-9]+$/, user) and
             Regex.match?(~r/^T[A-Z0-9]+$/, team) do
          {:ok,
           %{
             "subject" => %{"provider_user_id" => user, "provider_workspace_id" => team},
             "display" => display(auth["user"], user) <> " · " <> display(auth["team"], team)
           }}
        else
          {:error, :member_identity_or_source_unavailable}
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :member_identity_or_source_unavailable}
    end
  end

  defp identity("gmail", request) do
    with {:ok, %{"emailAddress" => email}} <- request.("GET", @gmail <> "/profile", []),
         true <- is_binary(email) and email != "" do
      {:ok, %{"subject" => %{"provider_mailbox" => email}, "display" => display(email, email)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp identity("googlecalendar", request) do
    with {:ok, %{"id" => calendar}} <- request.("GET", @calendar, []),
         true <- is_binary(calendar) and calendar != "" do
      {:ok,
       %{
         "subject" => %{"provider_calendar_id" => calendar},
         "display" => display(calendar, calendar)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp identity("outlook", request) do
    with {:ok, %{"id" => id} = me} <-
           request.("GET", @graph <> "/me?$select=id,mail,userPrincipalName", []),
         true <- is_binary(id) and id != "" do
      mailbox =
        if is_binary(me["mail"]) and me["mail"] != "",
          do: me["mail"],
          else: me["userPrincipalName"]

      {:ok, %{"subject" => %{"provider_user_id" => id}, "display" => display(mailbox, id)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp identity("googledrive", request) do
    with {:ok, %{"user" => %{"permissionId" => id} = user}} <-
           request.("GET", @drive <> "/about?fields=user", []),
         true <- is_binary(id) and id != "" do
      label = user["emailAddress"] || user["displayName"]
      {:ok, %{"subject" => %{"provider_user_id" => id}, "display" => display(label, id)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp display(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      label -> String.slice(label, 0, 120)
    end
  end

  defp display(_, fallback), do: fallback

  def read(workspace, user_id, source, now, deadline \\ RecommendationMemberRead.deadline())

  def read(
        workspace,
        user_id,
        %{"kind" => "composio", "toolkit" => toolkit} = source,
        now,
        deadline
      )
      when toolkit in ~w(slack gmail googlecalendar googledrive outlook) do
    id = source["connectionId"]

    with %{"connection_id" => ^id} = consent <-
           Comma.MemberSourceConsents.binding(workspace["id"], user_id, toolkit),
         true <- workspace["owner_user_id"] == user_id and is_binary(id) and id != "",
         {:ok, settings} <- settings().get(workspace["salix_tenant_id"]),
         {:ok, data, identity} <-
           with_proxy(
             settings,
             workspace,
             id,
             toolkit,
             deadline,
             &provider_read(toolkit, &1, now)
           ),
         ^consent <- Comma.MemberSourceConsents.binding(workspace["id"], user_id, toolkit) do
      subject =
        Map.merge(identity, Map.merge(consent, %{"user_id" => user_id, "toolkit" => toolkit}))

      {:ok, data, subject}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  def read(_workspace, _user_id, _source, _now, _deadline),
    do: {:error, :member_source_unsupported}

  # Read only an id from an exact, previously collected member item. The
  # proxy is pinned to that account and Graph enforces current resource ACL.
  def preview_outlook(workspace, account_id, provider_user_id, kind, resource_id, href)
      when kind in ~w(message event) and is_binary(resource_id) and
             byte_size(resource_id) in 1..512 do
    with {:ok, settings} <- settings().get(workspace["salix_tenant_id"]),
         {:ok, data} <-
           with_proxy(
             settings,
             workspace,
             account_id,
             "outlook",
             RecommendationMemberRead.deadline(),
             fn request ->
               {path, fields} =
                 if kind == "message",
                   do: {"messages/", "id,webLink,subject,bodyPreview,from,receivedDateTime"},
                   else: {"events/", "id,webLink,subject,bodyPreview,start,end,isCancelled"}

               endpoint =
                 @graph <>
                   "/me/" <>
                   path <>
                   URI.encode(resource_id, &URI.char_unreserved?/1) <> "?$select=" <> fields

               with {:ok, %{"id" => ^provider_user_id}} <-
                      request.("GET", @graph <> "/me?$select=id", []),
                    {:ok, %{"id" => ^resource_id, "webLink" => ^href} = data} <-
                      request.("GET", endpoint, []),
                    true <- kind != "event" or data["isCancelled"] != true do
                 {:ok, data}
               else
                 _ -> {:error, :member_identity_or_source_unavailable}
               end
             end,
             true
           ) do
      {:ok, data}
    else
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  def preview_outlook(_, _, _, _, _, _), do: {:error, :member_source_unsupported}

  defp provider_read("slack", request, now),
    do: CommaWeb.RecommendationSlackMemberSource.read(request, now)

  defp provider_read("outlook", request, now),
    do: CommaWeb.RecommendationOutlookMemberSource.read(request, now)

  defp provider_read(toolkit, request, now),
    do: CommaWeb.RecommendationGoogleMemberSource.read(toolkit, request, now)

  # Display checks local consent, not the external provider. Provider-side
  # revocation is observed during collection; Comma disconnect removes consent.
  def current_subject?(workspace, user_id, source, subject) when is_map(subject) do
    workspace["owner_user_id"] == user_id and
      source["toolkit"] == subject["toolkit"] and
      source["connectionId"] == subject["connection_id"] and
      subject["user_id"] == user_id and
      Comma.MemberSourceConsents.binding(workspace["id"], user_id, subject["toolkit"]) ==
        Map.take(subject, ~w(connection_id consent_revision))
  end

  def current_subject?(_, _, _, _), do: false

  defp valid_account?(account, workspace, toolkit, id) do
    account["id"] == id and account["user_id"] == workspace["default_group_id"] and
      get_in(account, ["toolkit", "slug"]) == toolkit and account["status"] == "ACTIVE"
  end

  # Composio keeps the member's credential and carries one account-pinned
  # session. Every request is the provider's official versioned API, so no
  # Composio tool slug, argument name or reshaped response is a dependency.
  # The account check and the session start are independent; no provider read
  # runs before the account is verified. Each request ends by the read
  # deadline, and cleanup does not spend it.
  defp with_proxy(settings, workspace, id, toolkit, deadline, read, verify_after? \\ false) do
    [account, session] =
      RecommendationMemberRead.map(
        [
          fn -> client().get_connected_account(settings, id) end,
          fn ->
            client().create_proxy_session(settings, workspace["default_group_id"], id, toolkit,
              error_mode: :structured
            )
          end
        ],
        &RecommendationMemberRead.request(deadline, &1),
        2
      )

    case session do
      {:ok, session} ->
        try do
          with {:ok, account} <- account,
               true <- valid_account?(account, workspace, toolkit, id) do
            result =
              read.(fn method, endpoint, opts ->
                RecommendationMemberRead.request(deadline, fn ->
                  proxy(settings, session, toolkit, method, endpoint, opts)
                end)
              end)

            if verify_after? do
              with {:ok, ^account} <-
                     RecommendationMemberRead.request(deadline, fn ->
                       client().get_connected_account(settings, id)
                     end) do
                result
              else
                _ -> {:error, :member_identity_or_source_unavailable}
              end
            else
              result
            end
          else
            {:error, _} = error -> error
            _ -> {:error, :member_identity_or_source_unavailable}
          end
        after
          SystemsRuntime.Task.start(fn -> client().delete_proxy_session(settings, session) end)
        end

      {:error, _} = error ->
        with {:ok, _account} <- account, do: error

      _ ->
        {:error, :member_identity_or_source_unavailable}
    end
  end

  defp proxy(settings, session, toolkit, method, endpoint, opts) do
    case client().proxy_execute(
           settings,
           session,
           opts
           |> Keyword.take([:parameters])
           |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
           |> Map.merge(%{"toolkit_slug" => toolkit, "endpoint" => endpoint, "method" => method}),
           error_mode: :structured,
           max_response_bytes: Keyword.get(opts, :max_bytes, 512_000)
         ) do
      {:ok, %{"status" => 200, "data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{"status" => status}} when is_integer(status) ->
        {:error, {:member_provider_http, status}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :member_provider_failed}
    end
  end

  defp client, do: SystemsRuntime.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp settings,
    do: SystemsRuntime.get_env(:salix_web, :composio_settings_mod, Salix.Control.ComposioSettings)
end
