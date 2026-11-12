defmodule SalixIM.IFC.People do
  @moduledoc """
  The people of one connect, by name and email, for the Data policy page
  (`SalixIM.IFC.Admin`): an operator finds a person by name or email instead of
  pasting a provider user id, and every id the page shows comes with the name
  and email it stands for.

  Feishu and Lark ask the directory: an email or an open_id directly, a name
  as `feishu.lookup_users` does (`Directory.lookup/4`): in the stored copy of
  the app's Contacts data range (`DirectorySnapshot`), and when nobody there
  matches, by a bounded walk of the data range. Slack asks the workspace
  directory: an email or a user id directly, a name in at most
  `@slack_pages` pages of `users.list`.
  Every read is bounded; a person who cannot be read keeps their id alone.
  """

  alias SalixIM.Provider.{Feishu, Lark}
  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects

  @results 20
  @described 50
  @slack_pages 5
  @slack_page_size 200
  @concurrency 8
  @timeout_ms 5_000

  @doc "Up to #{@results} people of the connect whose name, email or id matches `query`."
  @spec search(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def search(tenant_id, group_id, connect_id, query) when is_binary(query) do
    query = String.trim(query)

    with true <- query != "" and String.length(query) <= 100,
         {:ok, connect} <- connect(tenant_id, group_id, connect_id),
         {:ok, people} <- find(connect, query) do
      {:ok, people |> Enum.uniq_by(& &1["id"]) |> Enum.take(@results)}
    else
      false -> {:error, :invalid_query}
      {:error, _} = error -> error
    end
  end

  def search(_tenant_id, _group_id, _connect_id, _query), do: {:error, :invalid_query}

  @doc """
  Name and email for each of up to #{@described} ids of the connect, by id,
  read from the provider. An id that cannot be read is left out.
  """
  @spec describe(map(), [String.t()]) :: %{String.t() => map()}
  def describe(connect, ids) when is_map(connect) and is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@described)
    |> SystemsClock.async_stream(&{&1, person(connect, &1)},
      max_concurrency: @concurrency,
      timeout: @timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, %{} = person}}, acc -> Map.put(acc, id, person)
      _missing, acc -> acc
    end)
  end

  def describe(_connect, _ids), do: %{}

  @doc false
  def connect(tenant_id, group_id, connect_id) when is_binary(connect_id) do
    case ProviderConnects.get_active_connect_by_id(group_id, connect_id) do
      {:ok, %{"tenant_id" => ^tenant_id} = connect} -> {:ok, connect}
      _ -> {:error, :connect_not_found}
    end
  end

  def connect(_tenant_id, _group_id, _connect_id), do: {:error, :connect_not_found}

  # ---------------------------------------------------------------------------

  defp find(%{"provider" => provider} = connect, query) when provider in ["feishu", "lark"] do
    cond do
      email?(query) -> {:ok, lark_by_email(connect, query)}
      String.starts_with?(query, "ou_") -> {:ok, List.wrap(lark_person(connect, query))}
      true -> lark_by_name(connect, query)
    end
  end

  defp find(%{"provider" => "slack"} = connect, query) do
    cond do
      email?(query) -> {:ok, List.wrap(slack_by_email(connect, query))}
      Regex.match?(~r/^[UW][A-Z0-9]+$/, query) -> {:ok, List.wrap(slack_person(connect, query))}
      true -> {:ok, slack_by_name(connect, query, nil, @slack_pages, [])}
    end
  end

  defp find(_connect, _query), do: {:ok, []}

  defp person(%{"provider" => provider} = connect, id) when provider in ["feishu", "lark"],
    do: lark_person(connect, id)

  defp person(%{"provider" => "slack"} = connect, id), do: slack_person(connect, id)
  defp person(_connect, _id), do: nil

  defp lark_person(connect, open_id) do
    case im(connect).call(nil, connect, connect["provider"] <> ".get_user", %{
           "user_id" => open_id
         }) do
      {:ok, %{"user" => %{} = user}} ->
        entry(open_id, user["name"], user["email"] || user["enterprise_email"])

      _ ->
        nil
    end
  end

  # Feishu's keyword user search needs a user token, so a name is matched
  # against the stored copy of the app's Contacts data range, or on a miss
  # against the data range walked within a request budget. No match in a walk
  # that failed or stopped early is not "nobody": the page says the directory
  # could not be read in full.
  defp lark_by_name(connect, query) do
    directory = if connect["provider"] == "lark", do: Lark.Directory, else: Feishu.Directory
    result = directory.lookup(connect, [], query, @results)

    people =
      for %{"open_id" => "ou_" <> _ = open_id} = user <- result["users"],
          do: entry(open_id, user["name"], user["email"] || user["enterprise_email"])

    if people == [] and result["directory"]["complete"] != true,
      do: {:error, :directory_incomplete},
      else: {:ok, people}
  end

  # The directory names an open_id for an email; the person's name comes from
  # a read of that id.
  defp lark_by_email(connect, email) do
    api = if connect["provider"] == "lark", do: Lark.API, else: Feishu.API

    case api.post(connect, "/contact/v3/users/batch_get_id?user_id_type=open_id", %{
           "emails" => [email]
         }) do
      {:ok, %{"user_list" => users}} ->
        for %{"user_id" => "ou_" <> _ = open_id} <- users,
            do: lark_person(connect, open_id) || entry(open_id, nil, email)

      _ ->
        []
    end
  end

  defp slack_person(connect, user_id) do
    case SlackAPI.user_info(SlackAPI.installation(connect), user_id) do
      %{"id" => ^user_id} = user -> slack_entry(user)
      _ -> nil
    end
  rescue
    _error in [SlackAPI.Error, ArgumentError] -> nil
  end

  defp slack_by_email(connect, email) do
    case SlackAPI.request_form(SlackAPI.installation(connect), "users.lookupByEmail",
           email: email
         ) do
      %{"user" => %{"id" => _} = user} -> slack_entry(user)
      _ -> nil
    end
  rescue
    _error in [SlackAPI.Error, ArgumentError] -> nil
  end

  defp slack_by_name(_connect, _query, _cursor, 0, found), do: found

  defp slack_by_name(connect, query, cursor, pages_left, found) do
    fields = [limit: @slack_page_size] ++ if(cursor, do: [cursor: cursor], else: [])
    page = SlackAPI.request_form(SlackAPI.installation(connect), "users.list", fields)
    needle = String.downcase(query)

    found =
      found ++
        (page["members"]
         |> List.wrap()
         |> Enum.reject(
           &(&1["deleted"] == true or &1["is_bot"] == true or &1["id"] == "USLACKBOT")
         )
         |> Enum.map(&slack_entry/1)
         |> Enum.filter(fn person ->
           Enum.any?([person["name"], person["email"]], fn value ->
             is_binary(value) and String.contains?(String.downcase(value), needle)
           end)
         end))

    next = get_in(page, ["response_metadata", "next_cursor"])

    if length(found) >= @results or next in [nil, ""],
      do: found,
      else: slack_by_name(connect, query, next, pages_left - 1, found)
  rescue
    _error in [SlackAPI.Error, ArgumentError] -> found
  end

  defp slack_entry(user) do
    profile = user["profile"] || %{}

    entry(
      user["id"],
      Enum.find(
        [profile["real_name"], user["real_name"], profile["display_name"], user["name"]],
        &(is_binary(&1) and String.trim(&1) != "")
      ),
      profile["email"]
    )
  end

  defp entry(id, name, email) do
    %{"id" => id, "name" => present(name), "email" => present(email)}
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil

  defp email?(value), do: Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, value)

  defp im(%{"provider" => "lark"}), do: Lark
  defp im(%{"provider" => "feishu"}), do: Feishu
end
