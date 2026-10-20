defmodule CommaWeb.LinearAgent do
  @moduledoc """
  Deployment configuration and Linear API client for Comma as a Linear agent.

  The Linear OAuth application that represents Comma is configured once per
  deployment under `:comma_web, :linear_agent`. Installation tokens live in
  the Salix OAuth connection store and refresh through the existing Linear
  OAuth adapter. GraphQL calls follow the Linear Agent Interaction API:
  <https://linear.app/developers/agent-interaction>.
  """

  alias SalixStore.OAuth.Adapter
  alias SalixStore.OAuth.Adapters.Linear, as: LinearOAuth

  @scopes ~w(read write app:assignable app:mentionable)
  @timestamp_window_ms 5 * 60_000
  @graphql_default "https://api.linear.app/graphql"
  @activity_types ~w(thought action elicitation response error)

  # ---- configuration ----

  def configured? do
    config = config()

    config[:enabled] == true and
      Enum.all?([:client_id, :client_secret, :webhook_secret, :public_base_url], fn key ->
        nonblank?(config[key])
      end)
  end

  def scopes, do: @scopes

  def webhook_url, do: public_base_url() <> "/v1/comma/integrations/linear/webhook"

  def redirect_url, do: public_base_url() <> "/v1/comma/integrations/linear/connect/callback"

  defp public_base_url, do: config()[:public_base_url] |> to_string() |> String.trim_trailing("/")

  defp app,
    do: %{"client_id" => config()[:client_id], "client_secret" => config()[:client_secret]}

  # ---- OAuth (actor=app) ----

  def authorization_url(state, code_challenge) do
    LinearOAuth.authorization_url(app(), %{
      "redirect_uri" => redirect_url(),
      "state" => state,
      "scopes" => @scopes,
      "code_challenge" => code_challenge,
      "actor" => "app"
    })
  end

  def exchange_code(code, code_verifier) do
    LinearOAuth.exchange_code(
      app(),
      %{"redirect_uri" => redirect_url(), "code_verifier" => code_verifier, "actor" => "app"},
      code
    )
  end

  # ---- OAuth (actor=user): who the person is in Linear ----

  @user_scopes ~w(read)

  @doc "The authorization that tells Comma the person's Linear user and organization."
  def user_authorization_url(state, code_challenge) do
    LinearOAuth.authorization_url(app(), %{
      "redirect_uri" => redirect_url(),
      "state" => state,
      "scopes" => @user_scopes,
      "code_challenge" => code_challenge
    })
  end

  def exchange_user_code(code, code_verifier) do
    LinearOAuth.exchange_code(
      app(),
      %{"redirect_uri" => redirect_url(), "code_verifier" => code_verifier},
      code
    )
  end

  def refresh(record), do: LinearOAuth.refresh(app(), record)

  def revoke(record), do: LinearOAuth.revoke(app(), record)

  @doc "A bearer token for the installation, refreshed through storage CAS when stale."
  def access_token(%{connection_id: connection_id}) when is_binary(connection_id) do
    SalixStore.OAuth.valid_token(connection_id, &refresh/1)
  end

  def access_token(_installation), do: {:error, :linear_connection_missing}

  # ---- webhook authentication ----

  @doc """
  Verifies the `Linear-Signature` header: a hex HMAC-SHA256 of the raw request
  body with the application's webhook signing secret.
  """
  def verify_signature(raw_body, [presented]) when is_binary(raw_body) and is_binary(presented) do
    secret = config()[:webhook_secret]

    if nonblank?(secret) do
      expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(expected, String.downcase(String.trim(presented)))
    else
      false
    end
  end

  def verify_signature(_raw_body, _headers), do: false

  @doc "Whether the payload's `webhookTimestamp` (ms) lies inside the replay window."
  def fresh_timestamp?(%{"webhookTimestamp" => sent}) when is_integer(sent) do
    abs(SystemsClock.system_time(:millisecond) - sent) <= @timestamp_window_ms
  end

  def fresh_timestamp?(_payload), do: false

  # ---- GraphQL ----

  @doc """
  Runs one GraphQL operation as the installation. Returns the `data` map, or
  `{:error, {:http, status}}`, `{:error, {:graphql, messages}}`, or
  `{:error, {:transport, message}}` when the outcome is unknown.
  """
  def graphql(installation, query, variables \\ %{})

  def graphql(installation, query, variables) when is_map(installation) do
    with {:ok, token} <- access_token(installation) do
      graphql_with_token(token, query, variables)
    end
  end

  def graphql_with_token(token, query, variables) when is_binary(token) do
    case Adapter.post_json(
           graphql_url(),
           %{"query" => query, "variables" => variables},
           "linear graphql",
           auth: {:bearer, token}
         ) do
      {:ok, 200, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:graphql, Enum.map(errors, &(&1["message"] || inspect(&1)))}}

      {:ok, 200, %{"data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, 200, _body} ->
        {:error, {:graphql, ["response without data"]}}

      {:ok, status, _body} ->
        {:error, {:http, status}}

      {:error, message} ->
        {:error, {:transport, message}}
    end
  end

  @doc "Posts one agent activity. `content` carries `type` and the type's fields."
  def create_activity(installation, agent_session_id, %{"type" => type} = content, opts \\ [])
      when type in @activity_types do
    input =
      %{"agentSessionId" => agent_session_id, "content" => content}
      |> maybe_put("ephemeral", Keyword.get(opts, :ephemeral))
      |> maybe_put("signal", Keyword.get(opts, :signal))
      |> maybe_put("signalMetadata", Keyword.get(opts, :signal_metadata))

    query = """
    mutation AgentActivityCreate($input: AgentActivityCreateInput!) {
      agentActivityCreate(input: $input) { success agentActivity { id } }
    }
    """

    case graphql(installation, query, %{"input" => input}) do
      {:ok, %{"agentActivityCreate" => %{"success" => true} = result}} ->
        {:ok, get_in(result, ["agentActivity", "id"])}

      {:ok, _data} ->
        {:error, {:graphql, ["agentActivityCreate was not successful"]}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Updates an agent session, for example its `externalUrls`."
  def update_session(installation, agent_session_id, input) when is_map(input) do
    query = """
    mutation AgentSessionUpdate($id: String!, $input: AgentSessionUpdateInput!) {
      agentSessionUpdate(id: $id, input: $input) { success }
    }
    """

    case graphql(installation, query, %{"id" => agent_session_id, "input" => input}) do
      {:ok, %{"agentSessionUpdate" => %{"success" => true}}} -> :ok
      {:ok, _data} -> {:error, {:graphql, ["agentSessionUpdate was not successful"]}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Adds links to an agent session, such as a pull request, keeping the ones it has."
  def add_session_urls(installation, agent_session_id, urls) when is_list(urls) do
    update_session(installation, agent_session_id, %{"addedExternalUrls" => urls})
  end

  @doc "An issue's team and the type of its workflow state (`unstarted`, `started`, `completed`, ...)."
  def issue_state(installation, issue_id) when is_binary(issue_id) do
    query = """
    query IssueState($id: String!) {
      issue(id: $id) { id team { id } state { id type } }
    }
    """

    case graphql(installation, query, %{"id" => issue_id}) do
      {:ok, %{"issue" => %{"team" => %{"id" => team_id}, "state" => state}}}
      when is_binary(team_id) ->
        {:ok, %{"team_id" => team_id, "state_id" => state["id"], "state_type" => state["type"]}}

      {:ok, _data} ->
        {:error, {:graphql, ["issue state missing"]}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "A team's workflow states as `%{id, name, type, position}` maps."
  def team_states(installation, team_id) when is_binary(team_id) do
    query = """
    query TeamStates($id: String!) {
      team(id: $id) { states { nodes { id name type position } } }
    }
    """

    case graphql(installation, query, %{"id" => team_id}) do
      {:ok, %{"team" => %{"states" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, Enum.map(nodes, &Map.take(&1, ~w(id name type position)))}

      {:ok, _data} ->
        {:error, {:graphql, ["team states missing"]}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Moves an issue to a workflow state."
  def update_issue_state(installation, issue_id, state_id)
      when is_binary(issue_id) and is_binary(state_id) do
    query = """
    mutation IssueState($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) { success }
    }
    """

    case graphql(installation, query, %{"id" => issue_id, "input" => %{"stateId" => state_id}}) do
      {:ok, %{"issueUpdate" => %{"success" => true}}} -> :ok
      {:ok, _data} -> {:error, {:graphql, ["issueUpdate was not successful"]}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Lists the activities of an agent session, oldest first, as `%{type, body}` maps."
  def list_activities(installation, agent_session_id) do
    query = """
    query AgentSessionActivities($id: String!) {
      agentSession(id: $id) {
        activities(first: 250) {
          nodes {
            id
            content {
              __typename
              ... on AgentActivityThoughtContent { body }
              ... on AgentActivityResponseContent { body }
              ... on AgentActivityErrorContent { body }
              ... on AgentActivityElicitationContent { body }
              ... on AgentActivityPromptContent { body }
              ... on AgentActivityActionContent { action parameter result }
            }
          }
        }
      }
    }
    """

    case graphql(installation, query, %{"id" => agent_session_id}) do
      {:ok, %{"agentSession" => %{"activities" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, Enum.map(nodes, &activity_view/1)}

      {:ok, _data} ->
        {:error, {:graphql, ["agentSession activities missing"]}}

      {:error, _reason} = error ->
        error
    end
  end

  defp activity_view(%{"id" => id, "content" => %{"__typename" => typename} = content}) do
    type =
      typename
      |> String.replace_prefix("AgentActivity", "")
      |> String.replace_suffix("Content", "")
      |> String.downcase()

    %{"id" => id, "type" => type, "body" => content["body"], "action" => content["action"]}
  end

  defp activity_view(node), do: %{"id" => node["id"], "type" => "unknown", "body" => nil}

  # ---- internals ----

  defp graphql_url, do: Adapter.endpoint("linear", "api_url", @graphql_default)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: SystemsRuntime.get_env(:comma_web, :linear_agent, [])
end
