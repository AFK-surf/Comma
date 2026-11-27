defmodule Salix.Bindings.DailyBriefIssues do
  @moduledoc """
  The current state of the GitHub pull requests and issues a daily brief
  names, read with the brief agent's group GitHub connection.

  The first enabled GitHub binding of the group that belongs to no person is
  used. A group without one answers no states; an issue that cannot be read is
  left out. The token never leaves this module and nothing read is stored.
  """

  alias SalixAgent.{OAuthCredentials, OAuthStore}
  alias SalixStore.OAuth.Adapter

  @max_issues 15
  @max_concurrency 8
  @task_timeout_ms 20_000

  @doc """
  `%{agent_id, issues: [%{repo: "owner/name", number: "123"}]}` to
  `{:ok, %{"owner/name#123" => state}}`, a state being "merged", "closed",
  "draft", "open, conflicts with its base", or "open".
  """
  @spec states(map()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def states(%{agent_id: agent_id, issues: issues})
      when is_binary(agent_id) and is_list(issues) do
    issues = issues |> Enum.filter(&valid?/1) |> Enum.uniq() |> Enum.take(@max_issues)

    if issues == [] do
      {:ok, %{}}
    else
      case token(agent_id) do
        {:ok, token} ->
          states =
            issues
            |> SystemsClock.async_stream(
              fn %{repo: repo, number: number} ->
                case state(token, repo, number) do
                  {:ok, state} -> {"#{repo}##{number}", state}
                  :error -> nil
                end
              end,
              max_concurrency: @max_concurrency,
              timeout: @task_timeout_ms,
              on_timeout: :kill_task
            )
            |> Enum.reduce(%{}, fn
              {:ok, {key, state}}, acc -> Map.put(acc, key, state)
              _other, acc -> acc
            end)

          {:ok, states}

        :none ->
          {:ok, %{}}
      end
    end
  end

  def states(_request), do: {:error, :invalid_request}

  # A busy day merges dozens; commits are read for the newest ones only.
  @max_pulls 100
  @max_commit_reads 40

  @doc """
  The pull requests opened by GitHub `login` that were merged or closed from
  `since` to `until` (dates, "2026-11-12"), newest first: `%{repo, number,
  title, state, closed_at, others}`, where `others` are the other logins that wrote its
  commits (an agent may open a pull request with someone's account).
  """
  @spec member_pulls(map()) :: {:ok, [map()]} | {:error, term()}
  def member_pulls(%{agent_id: agent_id, login: login, since: since, until: until})
      when is_binary(agent_id) and is_binary(login) and is_binary(since) and is_binary(until) do
    with true <- login =~ ~r/\A[A-Za-z0-9-]{1,39}\z/ and valid_date?(since) and valid_date?(until),
         {:ok, token} <- token(agent_id),
         query = URI.encode_www_form("author:#{login} is:pr closed:#{since}..#{until}"),
         {:ok, 200, %{"items" => items}} when is_list(items) <-
           get(token, "/search/issues?q=#{query}&sort=updated&order=desc&per_page=#{@max_pulls}") do
      pulls =
        items
        |> Enum.with_index()
        |> SystemsClock.async_stream(
          fn {item, i} -> pull(token, login, item, i < @max_commit_reads) end,
          ordered: true,
          max_concurrency: @max_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, %{} = pull} -> [pull]
          _other -> []
        end)

      {:ok, pulls}
    else
      _none -> {:ok, []}
    end
  end

  def member_pulls(_request), do: {:error, :invalid_request}

  @max_members 200

  @doc """
  The GitHub login of a person in one of `orgs` whose login or profile name
  is one of `names` (case and spaces ignored), when exactly one matches;
  else nil. Reads at most #{@max_members} members per organization.
  """
  @spec member_login(map()) :: {:ok, String.t() | nil} | {:error, term()}
  def member_login(%{agent_id: agent_id, orgs: orgs, names: names})
      when is_binary(agent_id) and is_list(orgs) and is_list(names) do
    wanted = names |> Enum.map(&squash/1) |> Enum.reject(&(&1 == "")) |> MapSet.new()
    orgs = orgs |> Enum.filter(&(is_binary(&1) and &1 =~ ~r/\A[\w.-]{1,39}\z/)) |> Enum.uniq()

    with false <- MapSet.size(wanted) == 0 or orgs == [],
         {:ok, token} <- token(agent_id) do
      matches =
        orgs
        |> Enum.flat_map(&org_logins(token, &1))
        |> Enum.uniq()
        |> SystemsClock.async_stream(
          fn login ->
            if MapSet.member?(wanted, squash(login)) or
                 MapSet.member?(wanted, squash(profile_name(token, login))),
               do: login
          end,
          ordered: true,
          max_concurrency: @max_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, login} when is_binary(login) -> [login]
          _other -> []
        end)

      case matches do
        [login] -> {:ok, login}
        _none_or_many -> {:ok, nil}
      end
    else
      _none -> {:ok, nil}
    end
  end

  def member_login(_request), do: {:error, :invalid_request}

  defp org_logins(token, org) do
    Enum.reduce_while(1..div(@max_members, 100), [], fn page, acc ->
      case get(token, "/orgs/#{org}/members?per_page=100&page=#{page}") do
        {:ok, 200, [_ | _] = members} ->
          logins = for %{"login" => login} <- members, is_binary(login), do: login
          if length(members) < 100, do: {:halt, acc ++ logins}, else: {:cont, acc ++ logins}

        _done ->
          {:halt, acc}
      end
    end)
  end

  defp profile_name(token, login) do
    case get(token, "/users/#{login}") do
      {:ok, 200, %{"name" => name}} when is_binary(name) -> name
      _none -> ""
    end
  end

  defp squash(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/\s+/u, "")

  defp squash(_value), do: ""

  defp valid_date?(day), do: match?({:ok, _}, Date.from_iso8601(day))

  defp pull(token, login, %{"repository_url" => repo_url, "number" => number} = item, read?)
       when is_integer(number) do
    repo = repo_url |> String.split("/repos/", parts: 2) |> List.last()
    others = if read?, do: other_authors(token, login, repo, number), else: []

    %{
      repo: repo,
      number: Integer.to_string(number),
      title: String.slice(item["title"] || "", 0, 200),
      state: if(get_in(item, ["pull_request", "merged_at"]), do: "merged", else: "closed"),
      closed_at: item["closed_at"],
      others: others
    }
  end

  defp pull(_token, _login, _item, _read?), do: nil

  defp other_authors(token, login, repo, number) do
    case get(token, "/repos/#{repo}/pulls/#{number}/commits?per_page=100") do
      {:ok, 200, commits} when is_list(commits) ->
        commits
        |> Enum.map(&get_in(&1, ["author", "login"]))
        |> Enum.reject(&(&1 in [nil, login]))
        |> Enum.uniq()

      _unreadable ->
        []
    end
  end

  defp valid?(%{repo: repo, number: number}) when is_binary(repo) and is_binary(number),
    do: repo =~ ~r{\A[\w.-]+/[\w.-]+\z} and number =~ ~r/\A\d{1,7}\z/

  defp valid?(_issue), do: false

  defp token(agent_id) do
    with {:ok, %{group_id: group_id}} <- OAuthStore.agent_oauth_context(agent_id),
         {:ok, bindings} <- OAuthStore.bindings_for_group(group_id) do
      bindings
      |> Enum.filter(
        &(&1["provider"] == "github" and Map.get(&1, "enabled", true) != false and
            OAuthCredentials.usable_by?(&1, nil))
      )
      |> Enum.find_value(:none, fn binding ->
        entry = %{
          "env_var" => "GITHUB_TOKEN",
          "provider" => "github",
          "alias" => binding["alias"],
          "value" => Adapter.credential_access_token()
        }

        case OAuthCredentials.resolve(agent_id, [entry], acting_for: nil) do
          {:ok, %{"GITHUB_TOKEN" => token}} when is_binary(token) and token != "" -> {:ok, token}
          _unusable -> nil
        end
      end)
    else
      _none -> :none
    end
  end

  defp state(token, repo, number) do
    with {:ok, 200, issue} <- get(token, "/repos/#{repo}/issues/#{number}") do
      case issue do
        %{"pull_request" => %{"merged_at" => merged}} when is_binary(merged) -> {:ok, "merged"}
        %{"state" => "closed"} -> {:ok, "closed"}
        %{"pull_request" => _, "draft" => true} -> {:ok, "draft"}
        %{"pull_request" => _} -> {:ok, pull_state(token, repo, number)}
        _issue -> {:ok, "open"}
      end
    else
      _unreadable -> :error
    end
  end

  # GitHub reports conflicts only on the pull request itself.
  defp pull_state(token, repo, number) do
    case get(token, "/repos/#{repo}/pulls/#{number}") do
      {:ok, 200, %{"mergeable_state" => "dirty"}} -> "open, conflicts with its base"
      _other -> "open"
    end
  end

  defp get(token, path) do
    base = Adapter.endpoint("github", "api_url", "https://api.github.com")

    headers = [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer " <> token}
    ]

    case Req.get(base <> path, headers: headers, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
