defmodule CommaWeb.LinearIntegration do
  @moduledoc """
  Comma product orchestration for Linear agent installations and members.

  A person connects Linear from their Workspace. They authorize as themselves
  (`actor=user`), which tells Comma their Linear user and organization. When
  that organization has no active installation of Comma, the same flow goes
  on to an `actor=app` authorization that installs Comma there, held by the
  Workspace. Linear then pushes `AgentSessionEvent` webhooks here. A `created`
  event opens a chat with the Router in the Workspace linked to the session's
  creator through `CommaWeb.LinearAgentSession`; `prompted` events append to
  that chat; `OAuthApp revoked` retires the installation.
  """

  require Logger

  alias Comma.LinearInstallations
  alias CommaWeb.{LinearAgent, LinearAgentSession}
  alias SalixStore.Keys

  @doc """
  The Workspace's member link and installation. Linear Tasks run where and on
  what the Workspace's defaults say; `workers` stays an empty list for
  desktop apps already shipped, which read it.
  """
  def state(user, session, workspace_id) do
    with {:ok, workspace, %{installation: installation, member: member}} <-
           LinearInstallations.get(user, session, workspace_id) do
      {:ok,
       %{
         "configured" => LinearAgent.configured?(),
         "installation" => LinearInstallations.public_installation(installation, workspace),
         "member" => LinearInstallations.public_member(member),
         "completion_state_policies" => Comma.Data.LinearMember.policies(),
         "workers" => [],
         "workspace_id" => workspace["id"],
         "workspace_name" => workspace["name"]
       }}
    end
  end

  # ---- connect ----

  @doc "Starts a connect: the person authorizes as themselves in Linear first."
  def start_connect(user, session, workspace_id, environment \\ nil) do
    environment = return_environment(environment)

    with :ok <- require_configured(),
         {:ok, _workspace, attempt, url} <-
           start_attempt(user, session, workspace_id, "link", environment, %{}) do
      {:ok,
       %{
         "authorization_url" => url,
         "expires_at" => DateTime.to_iso8601(attempt.expires_at)
       }}
    end
  end

  # The environment prefix lets the callback choose the right app scheme even
  # when the attempt is gone; the random part is the OAuth state.
  defp start_attempt(user, session, workspace_id, kind, environment, carried) do
    state = environment <> "." <> new_token()
    verifier = new_token()

    attrs =
      Map.merge(carried, %{
        "kind" => kind,
        "state" => state,
        "pkce_verifier" => verifier,
        "environment" => environment
      })

    with {:ok, workspace, attempt} <-
           LinearInstallations.start_attempt(user, session, workspace_id, attrs),
         {:ok, url} <- authorization_url(kind, state, code_challenge(verifier)) do
      {:ok, workspace, attempt, url}
    else
      {:error, message} when is_binary(message) -> {:error, :linear_agent_unavailable}
      other -> other
    end
  end

  defp authorization_url("install", state, challenge),
    do: LinearAgent.authorization_url(state, challenge)

  defp authorization_url(_link, state, challenge),
    do: LinearAgent.user_authorization_url(state, challenge)

  @doc """
  Completes one authorization. A `link` answers `linked` when the
  organization already has Comma installed, or `install` with the
  `authorization_url` of the app installation to go on to. An `install`
  answers `installed`.
  """
  def complete_connect(code, state) do
    with :ok <- require_configured(),
         true <- is_binary(code) and code != "",
         {:ok, %{attempt: attempt, user: user, workspace: workspace}} <-
           LinearInstallations.take_attempt(state) do
      case attempt.kind do
        "install" -> complete_install(code, attempt, user, workspace)
        _link -> complete_link(code, attempt, user, workspace)
      end
    else
      false -> {:error, :invalid_linear_install_attempt}
      {:error, _reason} = error -> error
    end
  end

  # The person's own token is revoked as soon as their identity is read: Comma
  # acts in Linear as the installed app, and the link only needs to know who
  # they are there. Linear may report that revocation as an `OAuthApp revoked`
  # webhook for the organization; `route/1` checks the app's own token first.
  defp complete_link(code, attempt, user, workspace) do
    with {:ok, %{"tokens" => tokens, "account" => account}} <-
           LinearAgent.exchange_user_code(code, attempt.pkce_verifier),
         _ = LinearAgent.revoke(tokens),
         {:ok, organization_id} <- required(get_in(account, ["metadata", "workspace_id"])),
         {:ok, linear_user_id} <- required(get_in(account, ["metadata", "viewer_id"])) do
      linear_user = %{
        "id" => linear_user_id,
        "name" => get_in(account, ["metadata", "viewer_name"]),
        "email" => get_in(account, ["metadata", "viewer_email"])
      }

      case LinearInstallations.get_by_organization(organization_id) do
        {:ok, %{revoked_at: nil} = installation} ->
          with {:ok, member} <-
                 LinearInstallations.link_member(installation, workspace, user, linear_user) do
            {:ok, result("linked", attempt, workspace, member)}
          end

        _absent_or_revoked ->
          carried = %{
            "linear_organization_id" => organization_id,
            "linear_user_id" => linear_user["id"],
            "linear_user_name" => linear_user["name"],
            "linear_user_email" => linear_user["email"]
          }

          with {:ok, _workspace, _attempt, url} <-
                 start_attempt(
                   user,
                   %{},
                   workspace["id"],
                   "install",
                   return_environment(attempt.environment),
                   carried
                 ) do
            {:ok,
             %{
               "outcome" => "install",
               "authorization_url" => url,
               "workspace_id" => workspace["id"],
               "environment" => attempt.environment
             }}
          end
      end
    else
      {:error, message} when is_binary(message) -> {:error, :linear_provider_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp complete_install(code, attempt, user, workspace) do
    with {:ok, %{"tokens" => tokens, "account" => account}} <-
           LinearAgent.exchange_code(code, attempt.pkce_verifier),
         {:ok, organization_id} <- required(get_in(account, ["metadata", "workspace_id"])),
         {:ok, app_user_id} <- required(get_in(account, ["metadata", "viewer_id"])),
         connection_id <- "conn-" <> new_token(),
         record <- connection_record(connection_id, workspace, tokens, account),
         :ok <- same_organization(attempt, organization_id, record),
         {:ok, installation} <-
           install_or_join(workspace, user, record, %{
             "organization_id" => organization_id,
             "organization_name" => get_in(account, ["metadata", "workspace_name"]),
             "organization_url_key" => get_in(account, ["metadata", "url_key"]),
             "app_user_id" => app_user_id,
             "connection_id" => connection_id
           }),
         {:ok, member} <-
           LinearInstallations.link_member(installation, workspace, user, %{
             "id" => attempt.linear_user_id,
             "name" => attempt.linear_user_name,
             "email" => attempt.linear_user_email
           }) do
      {:ok, result("installed", attempt, workspace, member)}
    else
      {:error, message} when is_binary(message) -> {:error, :linear_provider_unavailable}
      {:error, _reason} = error -> error
    end
  end

  # The install screen let the person pick an organization other than the one
  # they linked as a user; their identity there is unknown. An organization
  # nobody holds loses the stray installation again; one another Workspace
  # holds keeps it, since revoking the token just issued would remove Comma
  # there for everyone.
  defp same_organization(%{linear_organization_id: expected}, organization_id, _record)
       when expected in [nil, organization_id],
       do: :ok

  defp same_organization(_attempt, organization_id, record) do
    case LinearInstallations.get_by_organization(organization_id) do
      {:ok, %{revoked_at: nil}} -> :ok
      _nobody -> _ = LinearAgent.revoke(record)
    end

    {:error, :linear_organization_mismatch}
  end

  # Two people may start connecting to the same organization before either
  # installed it. The one whose installation lands second joins it as a
  # member; the holder stays. The token just issued is for the same app
  # installation, so it is only left unused, never revoked.
  defp install_or_join(workspace, user, record, attrs) do
    case LinearInstallations.get_by_organization(attrs["organization_id"]) do
      {:ok, %{revoked_at: nil} = installation} ->
        {:ok, installation}

      _absent_or_revoked ->
        with :ok <- SalixStore.OAuth.put(record["connection_id"], record) do
          install(workspace, user, attrs)
        end
    end
  end

  defp result(outcome, attempt, workspace, member) do
    %{
      "outcome" => outcome,
      "workspace_id" => workspace["id"],
      "environment" => attempt.environment,
      "installation" => LinearInstallations.public_installation(member.installation, workspace),
      "member" => LinearInstallations.public_member(member)
    }
  end

  defp install(workspace, user, attrs) do
    case LinearInstallations.install(workspace, user, attrs) do
      {:ok, installation, previous} ->
        # Installing the organization again: its app installation is the one
        # just authorized, so the old token is only forgotten here. Revoking
        # it could uninstall Comma from that organization.
        if previous && previous.connection_id != attrs["connection_id"],
          do: forget_connection(previous.connection_id)

        {:ok, installation}

      {:error, _reason} = error ->
        retire_connection(attrs["connection_id"])
        error
    end
  end

  @doc """
  `member` (the default) removes the Workspace's link; the installation stays
  for its other members. `organization` removes the installation the
  Workspace holds, with every link, and revokes its token.
  """
  def disconnect(user, session, workspace_id, scope \\ "member")

  def disconnect(user, session, workspace_id, "organization") do
    with {:ok, _workspace, installation} <-
           LinearInstallations.uninstall(user, session, workspace_id) do
      if installation, do: retire_connection(installation.connection_id)
      {:ok, %{"disconnected" => not is_nil(installation)}}
    end
  end

  def disconnect(user, session, workspace_id, _member) do
    with {:ok, _workspace, member} <- LinearInstallations.unlink(user, session, workspace_id) do
      {:ok, %{"disconnected" => not is_nil(member)}}
    end
  end

  def update_settings(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, _workspace, %{member: %{} = _member}} <-
           LinearInstallations.get(user, session, workspace_id),
         {:ok, member} <-
           LinearInstallations.update_settings(user, session, workspace_id, attrs) do
      {:ok, LinearInstallations.public_member(member)}
    else
      {:ok, _workspace, %{member: nil}} -> {:error, :not_found}
      other -> other
    end
  end

  # ---- webhooks ----

  @doc """
  Authenticates and routes one Linear webhook. Returns `:ok` once the event is
  accepted; the caller answers Linear within its 5-second budget.
  """
  def handle_webhook(raw_body, signature_headers, payload) when is_map(payload) do
    cond do
      not LinearAgent.configured?() ->
        {:error, :linear_agent_unavailable}

      not LinearAgent.verify_signature(raw_body, signature_headers) ->
        {:error, :unauthorized}

      not LinearAgent.fresh_timestamp?(payload) ->
        {:error, :unauthorized}

      true ->
        route(payload)
    end
  end

  def handle_webhook(_raw_body, _signature_headers, _payload), do: {:error, :unauthorized}

  # A session goes to the Workspace of the Linear user who created it. A
  # creator without a link is told so in the session; nothing starts.
  defp route(%{"type" => "AgentSessionEvent", "action" => "created"} = payload) do
    with {:ok, installation} <- installation_for(payload) do
      case LinearInstallations.get_member(installation, creator_id(payload)) do
        {:ok, member} ->
          LinearAgentSession.start_async(member, payload)

        {:error, :not_found} ->
          LinearAgentSession.refuse_unknown_user_async(installation, payload)
      end
    end
  end

  defp route(%{"type" => "AgentSessionEvent", "action" => "prompted"} = payload) do
    with {:ok, installation} <- installation_for(payload),
         session_id when is_binary(session_id) <- get_in(payload, ["agentSession", "id"]) do
      case LinearInstallations.get_agent_session(session_id) do
        {:ok, %{installation_id: installation_id} = agent_session}
        when installation_id == installation.id ->
          LinearAgentSession.prompt(agent_session, payload)

        {:ok, _other_installation} ->
          Logger.warning("Linear prompt for a session of another installation ignored")
          :ok

        {:error, :not_found} ->
          LinearAgentSession.prompt_when_bridged_async(installation, session_id, payload)
      end
    else
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  # An issue closed, deleted or taken away from Comma in Linear ends the Task
  # still running for it. Other issue changes are not Comma's concern.
  defp route(%{"type" => "Issue", "action" => action} = payload)
       when action in ["update", "remove"] do
    with {:ok, installation} <- installation_for(payload),
         {:ok, reason} <- LinearAgentSession.issue_ended_reason(installation, payload) do
      LinearAgentSession.end_issue_async(installation, get_in(payload, ["data", "id"]), reason)
    else
      _ -> :ok
    end
  end

  # A person revoking their own authorization and the organization removing
  # the app can arrive as the same event, so the installation retires only
  # once its own token no longer works. Checked after the answer to Linear.
  defp route(%{"type" => "OAuthApp", "action" => "revoked", "organizationId" => organization_id})
       when is_binary(organization_id) do
    case LinearInstallations.get_by_organization(organization_id) do
      {:ok, %{revoked_at: nil} = installation} ->
        LinearAgentSession.run_async(fn -> retire_when_revoked(installation) end)

      _absent_or_retired ->
        :ok
    end
  end

  defp route(_payload), do: :ok

  @revoked_check_attempts 3
  @revoked_check_retry_ms 2_000

  # Only a token Linear itself refuses retires the installation. Linear being
  # unreachable, or answering 5xx, is checked again a few times and then left
  # alone: a wrong retirement would refuse every member's sessions until
  # someone connects again, while a missed one only delays the next refusal.
  @doc false
  def retire_when_revoked(installation, attempt \\ 1) do
    case LinearAgent.graphql(installation, "query { viewer { id } }") do
      {:ok, _data} ->
        Logger.info("Linear revoked webhook for a live installation ignored",
          organization_id: installation.organization_id
        )

        :ok

      {:error, reason} = error ->
        cond do
          token_refused?(reason) ->
            _ = LinearInstallations.mark_revoked(installation.organization_id)
            :ok

          attempt < @revoked_check_attempts ->
            SystemsClock.sleep(revoked_check_retry_ms())
            retire_when_revoked(installation, attempt + 1)

          true ->
            Logger.warning("Linear revoked webhook left unresolved; installation kept",
              organization_id: installation.organization_id,
              reason: inspect(error)
            )

            :ok
        end
    end
  end

  defp token_refused?({:http, status}) when status in [401, 403], do: true
  defp token_refused?(:reauthorization_required), do: true

  defp token_refused?({:graphql, messages}) when is_list(messages),
    do: Enum.any?(messages, &(String.downcase(to_string(&1)) =~ "authentication"))

  defp token_refused?(_reason), do: false

  defp revoked_check_retry_ms,
    do:
      SystemsRuntime.get_env(:comma_web, :linear_revoked_check_retry_ms, @revoked_check_retry_ms)

  defp creator_id(payload) do
    case get_in(payload, ["agentSession", "creatorId"]) do
      id when is_binary(id) and id != "" -> id
      _ -> get_in(payload, ["agentSession", "creator", "id"])
    end
  end

  defp installation_for(%{"organizationId" => organization_id} = payload)
       when is_binary(organization_id) do
    case LinearInstallations.get_by_organization(organization_id) do
      {:ok, installation} ->
        cond do
          not LinearInstallations.active?(installation) ->
            {:error, :ignored}

          is_binary(payload["appUserId"]) and payload["appUserId"] != installation.app_user_id ->
            Logger.warning("Linear webhook for another app user ignored",
              organization_id: organization_id
            )

            {:error, :ignored}

          true ->
            {:ok, installation}
        end

      {:error, :not_found} ->
        {:error, :ignored}
    end
  end

  defp installation_for(_payload), do: {:error, :ignored}

  @doc "The app environment a callback returns to, read from the state prefix."
  def callback_environment(state) when is_binary(state),
    do: state |> String.split(".", parts: 2) |> hd() |> return_environment()

  def callback_environment(_state), do: "prod"

  @return_environments ~w(dev staging prod)
  defp return_environment(value) when value in @return_environments, do: value
  defp return_environment(_value), do: "prod"

  # ---- internals ----

  defp require_configured,
    do: if(LinearAgent.configured?(), do: :ok, else: {:error, :linear_agent_unavailable})

  defp required(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value), do: {:error, :linear_provider_unavailable}

  defp connection_record(connection_id, workspace, tokens, account) do
    now = SystemsClock.system_time(:millisecond)

    tokens
    |> Map.merge(%{
      "connection_id" => connection_id,
      "tenant" => workspace["salix_tenant_id"],
      "provider" => "linear",
      "provider_account_id" => account["provider_account_id"] || "",
      "provider_account_name" => account["provider_account_name"] || "",
      "metadata" => Map.drop(account, ["provider_account_id", "provider_account_name"]),
      "status" => "active",
      "created_at" => now,
      "updated_at" => now
    })
  end

  # Best effort: the installation row is already gone or repointed, so a
  # failure here leaves an unreferenced token record, never a dangling binding.
  defp retire_connection(connection_id) when is_binary(connection_id) and connection_id != "" do
    case SalixStore.OAuth.get(connection_id) do
      {:ok, record} ->
        _ = LinearAgent.revoke(record)
        _ = SalixStore.S3.delete(Keys.oauth_connection(connection_id))
        :ok

      _ ->
        :ok
    end
  end

  defp retire_connection(_connection_id), do: :ok

  defp forget_connection(connection_id) when is_binary(connection_id) and connection_id != "" do
    _ = SalixStore.S3.delete(Keys.oauth_connection(connection_id))
    :ok
  end

  defp forget_connection(_connection_id), do: :ok

  defp code_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp new_token, do: SystemsRuntime.Proc.random_bytes(24) |> Base.url_encode64(padding: false)
end
