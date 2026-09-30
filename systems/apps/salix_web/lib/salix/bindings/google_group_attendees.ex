defmodule Salix.Bindings.GoogleGroupAttendees do
  @moduledoc "Read Google Workspace group membership for enrolled Calendar attendees."

  alias Salix.Control.ComposioSettings
  alias SalixStore.{Composio, Ids}

  @toolkit "google_admin"
  @api "https://admin.googleapis.com/admin/directory/v1/groups/"
  @page_size 200
  @max_pages_per_group 10
  @max_response_bytes 1_000_000

  # An absent Admin connection does not change ordinary Calendar recipients.
  # New meeting revisions can expand groups after the administrator connects it.
  def expand(plan, emails) when is_list(emails) and length(emails) <= 20 do
    with {:ok, access} <- access(plan) do
      case access do
        nil -> {:ok, []}
        _ -> with_session(access, &expand_with_session(access, &1, emails))
      end
    end
  end

  def current_members(_plan, pairs) when length(pairs) > 100,
    do: {:error, :meeting_group_member_check_limit_exceeded}

  def current_members(plan, pairs) when is_list(pairs) do
    with {:ok, access} <- access(plan) do
      case access do
        nil -> {:error, :meeting_group_directory_unavailable}
        _ -> with_session(access, &current_with_session(access, &1, pairs))
      end
    end
  end

  defp access(plan) do
    group_id = plan["group_id"]

    with true <- Ids.valid_group_id?(group_id),
         {:ok, settings} <- ComposioSettings.get(Ids.tenant_id_from_group!(group_id)),
         {:ok, accounts} <-
           Composio.list_connected_accounts_all(settings, group_id, error_mode: :structured) do
      active =
        Enum.filter(accounts, fn account ->
          slug = get_in(account, ["toolkit", "slug"]) || account["toolkit"]

          slug == @toolkit and account["status"] == Composio.active_status() and
            account["user_id"] == group_id and is_binary(account["id"]) and
            account["id"] != ""
        end)

      case active do
        [] -> {:ok, nil}
        [account] -> {:ok, %{settings: settings, group_id: group_id, account_id: account["id"]}}
        _ -> {:error, :meeting_group_directory_ambiguous}
      end
    else
      _ -> {:error, :meeting_group_directory_unavailable}
    end
  rescue
    _ -> {:error, :meeting_group_directory_unavailable}
  end

  defp with_session(access, fun) do
    case Composio.create_proxy_session(
           access.settings,
           access.group_id,
           access.account_id,
           @toolkit,
           error_mode: :structured
         ) do
      {:ok, session_id} ->
        try do
          fun.(session_id)
        after
          _ = Composio.delete_proxy_session(access.settings, session_id)
        end

      {:error, _} ->
        {:error, :meeting_group_directory_unavailable}
    end
  end

  defp expand_with_session(access, session_id, emails) do
    Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, members} ->
      if valid_email?(email) do
        case list_group(access, session_id, email, nil, MapSet.new(), 0) do
          {:ok, found} -> {:cont, {:ok, found ++ members}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, members}}
      end
    end)
  end

  defp list_group(_access, _session_id, _group, _token, _seen, @max_pages_per_group),
    do: {:error, :meeting_group_page_limit_exceeded}

  defp list_group(access, session_id, group_email, token, seen, page_count) do
    params = [query("includeDerivedMembership", true), query("maxResults", @page_size)]
    params = if token, do: params ++ [query("pageToken", token)], else: params

    case request(access, session_id, group_email, "/members", params) do
      {:ok, 404, _} when is_nil(token) ->
        {:ok, []}

      {:ok, 200, data} when is_map(data) ->
        raw = data["members"] || []
        next = data["nextPageToken"]

        cond do
          not is_list(raw) or length(raw) > @page_size ->
            {:error, :meeting_group_invalid_response}

          next not in [nil, ""] and
              (not is_binary(next) or byte_size(next) > 2_048 or MapSet.member?(seen, next)) ->
            {:error, :meeting_group_invalid_response}

          true ->
            members =
              raw
              |> Enum.filter(fn member ->
                is_map(member) and member["type"] == "USER" and
                  member["status"] in [nil, "ACTIVE"] and valid_email?(member["email"])
              end)
              |> Enum.map(fn member ->
                %{
                  "email" => normalize_email(member["email"]),
                  "group_email" => group_email
                }
              end)

            if next in [nil, ""] do
              {:ok, members}
            else
              with {:ok, rest} <-
                     list_group(
                       access,
                       session_id,
                       group_email,
                       next,
                       MapSet.put(seen, next),
                       page_count + 1
                     ),
                   do: {:ok, members ++ rest}
            end
        end

      {:ok, _status, _data} ->
        {:error, :meeting_group_directory_unavailable}

      {:error, _} = error ->
        error
    end
  end

  defp current_with_session(access, session_id, pairs) do
    Enum.reduce_while(pairs, {:ok, MapSet.new(), %{}}, fn {email, group_email},
                                                          {:ok, current, group_cache} ->
      if MapSet.member?(current, email) do
        {:cont, {:ok, current, group_cache}}
      else
        case current_member(access, session_id, email, group_email, group_cache) do
          {:ok, true, cache} -> {:cont, {:ok, MapSet.put(current, email), cache}}
          {:ok, false, cache} -> {:cont, {:ok, current, cache}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, current, _cache} -> {:ok, current}
      error -> error
    end
  end

  defp current_member(access, session_id, email, group_email, group_cache) do
    case Map.fetch(group_cache, group_email) do
      {:ok, members} ->
        {:ok, MapSet.member?(members, email), group_cache}

      :error ->
        case request(
               access,
               session_id,
               group_email,
               "/hasMember/" <> URI.encode(email, &URI.char_unreserved?/1),
               []
             ) do
          {:ok, 200, %{"isMember" => member?}} when is_boolean(member?) ->
            {:ok, member?, group_cache}

          {:ok, 404, _} ->
            {:ok, false, group_cache}

          {:ok, 400, _} ->
            # hasMember rejects cross-domain nested members. A complete current
            # group listing can still verify them with the same Directory access.
            case list_group(access, session_id, group_email, nil, MapSet.new(), 0) do
              {:ok, members} ->
                current_members = MapSet.new(Enum.map(members, & &1["email"]))

                {:ok, MapSet.member?(current_members, email),
                 Map.put(group_cache, group_email, current_members)}

              {:error, _} = error ->
                error
            end

          _ ->
            {:error, :meeting_group_directory_unavailable}
        end
    end
  end

  defp request(access, session_id, group_email, suffix, parameters) do
    body = %{
      "toolkit_slug" => @toolkit,
      "endpoint" => @api <> URI.encode(group_email, &URI.char_unreserved?/1) <> suffix,
      "method" => "GET",
      "parameters" => parameters
    }

    case Composio.proxy_execute(access.settings, session_id, body,
           max_response_bytes: @max_response_bytes,
           error_mode: :structured
         ) do
      {:ok, %{"status" => status, "data" => data}} when is_integer(status) ->
        {:ok, status, data}

      _ ->
        {:error, :meeting_group_directory_unavailable}
    end
  end

  defp query(name, value), do: %{"name" => name, "type" => "query", "value" => to_string(value)}

  defp valid_email?(email) when is_binary(email),
    do: byte_size(email) <= 320 and Regex.match?(~r/^[^@\s]+@[^@\s]+$/, email)

  defp valid_email?(_), do: false
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
