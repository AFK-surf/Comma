defmodule CommaCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    repo_children =
      if Application.get_env(:comma_core, :start_repo, false) do
        [Comma.Repo] ++ oban_children() ++ schema_readiness_children()
      else
        []
      end

    children =
      repo_children ++
        auth_redis_children() ++
        oauth_idp_rate_limit_children() ++
        task_share_rate_limit_children() ++
        google_oidc_children() ++ profile_avatar_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: CommaCore.Supervisor)
  end

  defp oban_children do
    if Application.get_env(:comma_core, :start_oban, true) do
      :ok = Comma.ObanTelemetry.attach()

      [{Comma.ObanBootstrap, Application.fetch_env!(:comma_core, Oban)}] ++ backlog_sampler_children()
    else
      []
    end
  end

  defp backlog_sampler_children do
    if Application.get_env(:comma_core, :start_oban_backlog_sampler, true) do
      [Comma.ObanBacklogSampler]
    else
      []
    end
  end

  defp schema_readiness_children do
    if Application.get_env(:comma_core, :start_schema_readiness, true) do
      [Comma.SchemaReadiness]
    else
      []
    end
  end

  defp auth_redis_children do
    config = Application.get_env(:comma_core, :auth, [])

    if Keyword.get(config, :challenge_store, Comma.AuthChallengeStore.Redis) ==
         Comma.AuthChallengeStore.Redis do
      [Comma.AuthChallengeStore.Redis]
    else
      []
    end
  end

  # The IdP limiter runs wherever its Redis URL is configured (runtime.exs
  # wires it for comma_product pods); other subsystems' pods carry no extra
  # Redis connection.
  defp oauth_idp_rate_limit_children do
    if Comma.OauthIdp.RateLimit.configured?() do
      [Comma.OauthIdp.RateLimit]
    else
      []
    end
  end

  # Public Task Share reads use their own buckets on the same deployment Redis.
  defp task_share_rate_limit_children do
    if Comma.TaskShares.RateLimit.configured?() do
      [Comma.TaskShares.RateLimit]
    else
      []
    end
  end

  defp google_oidc_children do
    config = Application.get_env(:comma_core, :google_auth, [])

    if config[:adapter] == Comma.Auth.GoogleAdapter.Oidcc and configured_client?(config) do
      [
        {Oidcc.ProviderConfiguration.Worker,
         %{
           issuer: config[:issuer] || "https://accounts.google.com",
           name: Comma.Auth.GoogleAdapter.Oidcc.Provider,
           backoff_type: :random_exponential
         }},
        {Comma.Auth.GoogleAdapter.Oidcc.JwksRefreshGate,
         cooldown_ms: config[:jwks_refresh_cooldown_ms] || 30_000}
      ]
    else
      []
    end
  end

  defp configured_client?(config) do
    Enum.any?([config[:web_client_id], config[:electron_client_id]], fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp profile_avatar_children do
    config = Application.get_env(:comma_core, :profile_avatar, [])

    if Comma.ProfileAvatar.Storage.configured?() and
         config[:adapter] == Comma.ProfileAvatar.Storage.GCS do
      [Comma.ProfileAvatar.Storage.GCS.child_spec()]
    else
      []
    end
  end
end
