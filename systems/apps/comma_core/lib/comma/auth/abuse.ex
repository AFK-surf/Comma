defmodule Comma.Auth.Abuse do
  @moduledoc "One consumed action challenge admits mailbox delivery or a new OAuth registration."
  alias Comma.Accounts.Email
  alias Comma.Auth.OneTimeCredentials
  alias Comma.Auth.Abuse.{Apple, Play, Turnstile}
  require Logger
  @purpose "abuse"
  @ttl 300
  @difficulty 12

  def check(action, email, platform, proof, context) do
    cond do
      enforced?() ->
        check_required(action, email, platform, proof, context, true)

      not hosted?() ->
        :ok

      not is_nil(proof) ->
        observe(action, platform, fn ->
          if is_map(proof) do
            check_required(action, email, platform, proof, context, false)
          else
            log_outcome(action, platform, nil, false, :invalid_context)
            :ok
          end
        end)

      collect?(platform, context["native_proof"]) ->
        observe(action, platform, fn ->
          check_required(action, email, platform, proof, context, false)
        end)

      true ->
        :ok
    end
  end

  def enforced?, do: hosted?() and config()[:enabled] == true

  def collect?(platform, intent),
    do: hosted?() and platform in ["ios", "android"] and intent == true

  defp hosted?, do: not SystemsRuntime.get_env(:comma_core, :selfhost, false)

  defp check_required(action, email, platform, proof, context, enforce) do
    with true <- action in ["email_login", "registration"],
         {:ok, origin} <- origin(context["api_origin"]) do
      context = Map.put(context, "api_origin", origin)

      if is_map(proof) do
        check_proof(action, email, proof, context, enforce)
      else
        with {:ok, normalized} <- Email.normalize(email),
             {:ok, continuation} <- continuation_id(action, context) do
          saved = %{
            "action" => action,
            "email" => normalized,
            "platform" => platform,
            "api_origin" => origin,
            "continuation_id" => continuation
          }

          method = if not enforce or native_configured?(platform), do: "native", else: "captcha"
          issue(saved, method, context, enforce)
        end
      end
    else
      {:error, :invalid_origin} -> {:error, :auth_abuse_unavailable}
      _ -> {:error, :invalid_abuse_challenge}
    end
  end

  def retire_email(email), do: Apple.delete_for_email(email)
  def config, do: SystemsRuntime.get_env(:comma_core, :auth_abuse, [])

  def peer_limits do
    auth = SystemsRuntime.get_env(:comma_core, :auth, [])

    [
      ip_request_limit: positive(auth[:ip_request_limit], 500),
      ip_request_window_seconds: positive(auth[:ip_request_window_seconds], 900)
    ]
  end

  def proof_input(id, secret), do: "comma-abuse:" <> id <> ":" <> secret

  defp check_proof(action, email, proof, context, enforce) do
    with {:ok, saved} <-
           OneTimeCredentials.consume(@purpose, proof["challenge_id"], proof["challenge_secret"]),
         true <- saved["action"] == action and saved["api_origin"] == context["api_origin"],
         true <- is_nil(email) or normalized_email?(email, saved["email"]),
         {:ok, continuation} <- continuation_id(action, context),
         true <- saved["continuation_id"] == continuation do
      bytes = proof_input(saved["id"], proof["challenge_secret"])

      result = verify(proof, saved, bytes, context)
      accepted = accepted?(result)

      log_outcome(
        action,
        saved["platform"],
        proof["provider"],
        enforce,
        if(accepted, do: :accepted, else: :rejected),
        result
      )

      if accepted or not enforce do
        :ok
      else
        issue(saved, "captcha", context, enforce)
      end
    else
      error ->
        log_outcome(action, nil, proof["provider"], enforce, :invalid_context)

        cond do
          not enforce -> :ok
          error == {:error, :auth_unavailable} -> {:error, :auth_abuse_unavailable}
          true -> {:error, :invalid_abuse_challenge}
        end
    end
  end

  @doc false
  def observe(action, platform, operation) do
    case operation.() do
      {:challenge, _, _} = challenge ->
        challenge

      :ok ->
        :ok

      _ ->
        log_outcome(action, platform, nil, false, :unavailable)
        :ok
    end
  rescue
    _ ->
      log_outcome(action, platform, nil, false, :unavailable)
      :ok
  catch
    :exit, _ ->
      log_outcome(action, platform, nil, false, :unavailable)
      :ok
  end

  defp log_outcome(
         action,
         platform,
         provider,
         enforce,
         verdict,
         stages \\ {:not_checked, :not_checked}
       ) do
    action = enum(action, ["email_login", "registration"])
    platform = enum(platform, ["web", "electron", "ios", "android"])
    provider = enum(provider, ["apple", "play", "turnstile", "unavailable"])
    mode = if enforce, do: "enforce", else: "observe"
    {pow, proof} = stages

    Logger.info(
      "auth_abuse action=#{action} platform=#{platform} provider=#{provider} mode=#{mode} verdict=#{verdict} pow=#{pow} proof=#{proof}"
    )
  end

  defp enum(value, allowed), do: if(value in allowed, do: value, else: "unknown")

  defp verify(%{"provider" => "turnstile", "captcha_token" => token}, saved, _bytes, context),
    do: {:not_checked, proof_stage(Turnstile.verify(token, saved, context))}

  defp verify(%{"provider" => provider} = proof, %{"method" => "native"} = saved, bytes, _context) do
    pow = if pow?(bytes, proof["pow_nonce"]), do: :accepted, else: :rejected

    verified =
      cond do
        provider == "unavailable" ->
          :unavailable

        pow == :rejected ->
          :not_checked

        true ->
          case {saved["platform"], provider} do
            {"ios", "apple"} -> proof_stage(Apple.verify(proof["apple"], bytes, saved["email"]))
            {"android", "play"} -> proof_stage(Play.verify(proof["play_token"], bytes))
            _ -> :rejected
          end
      end

    {pow, verified}
  end

  defp verify(_, _, _, _), do: {:not_checked, :rejected}
  defp proof_stage(:ok), do: :accepted
  defp proof_stage(_), do: :rejected
  defp accepted?({pow, :accepted}) when pow in [:accepted, :not_checked], do: true
  defp accepted?(_), do: false

  defp pow?(bytes, nonce) when is_binary(nonce) and byte_size(nonce) in 1..20 do
    nonce =~ ~r/^[0-9]+$/ and
      Comma.GuestPow.leading_zero_bits(:crypto.hash(:sha256, bytes <> ":" <> nonce)) >=
        @difficulty
  end

  defp pow?(_, _), do: false

  defp issue(saved, method, context, enforce) do
    if method == "captcha" and not Turnstile.configured?() do
      {:error, :auth_abuse_unavailable}
    else
      saved =
        Map.take(saved, ~w(action email platform api_origin continuation_id))
        |> Map.put("method", method)

      peer = context["remote_ip"] || "unknown"

      with {:ok, credential} <-
             OneTimeCredentials.issue(@purpose, saved, @ttl, peer, peer_limits()) do
        challenge = %{
          "id" => credential.id,
          "secret" => credential.secret,
          "expires_at" => credential.expires_at,
          "method" => method,
          "enforce" => enforce,
          "action" => saved["action"],
          "email" => saved["email"]
        }

        challenge =
          case {method, saved["platform"]} do
            {"native", "ios"} ->
              Map.merge(
                challenge,
                non_nil(%{
                  "pow_difficulty" => @difficulty,
                  "apple_environment" => apple_environment()
                })
              )

            {"native", "android"} ->
              Map.merge(
                challenge,
                non_nil(%{
                  "pow_difficulty" => @difficulty,
                  "google_cloud_project_number" => play_project_number()
                })
              )

            {"captcha", _} ->
              Map.put(
                challenge,
                "captcha_url",
                saved["api_origin"] <>
                  "/v1/comma/auth/captcha?" <>
                  URI.encode_query(%{
                    "challenge_id" => credential.id,
                    "action" => saved["action"]
                  })
              )
          end

        {:challenge, if(method == "native", do: :native_proof_required, else: :captcha_required),
         challenge}
      else
        {:error, :auth_not_configured} = error -> error
        {:error, :rate_limited, retry_after} -> {:error, {:rate_limited, retry_after}}
        _ -> {:error, :auth_abuse_unavailable}
      end
    end
  end

  defp non_nil(values), do: Map.reject(values, fn {_key, value} -> is_nil(value) end)

  defp apple_environment do
    value = Apple.environment()
    if value in ["development", "production"], do: value
  end

  defp play_project_number do
    value = Play.project_number()
    if is_binary(value) and value =~ ~r/^[0-9]{1,20}$/, do: value
  end

  defp native_configured?("ios"), do: Apple.configured?()
  defp native_configured?("android"), do: Play.configured?()
  defp native_configured?(_), do: false
  defp normalized_email?(email, expected), do: Email.normalize(email) == {:ok, expected}
  defp continuation_id("email_login", _), do: {:ok, nil}

  defp continuation_id("registration", context) do
    with {:ok, id, _secret} <- OneTimeCredentials.unpack(context["registration_continuation"]),
         do: {:ok, id}
  end

  defp positive(value, _) when is_integer(value) and value > 0, do: value
  defp positive(_, default), do: default

  defp origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when scheme in ["https", "http"] and is_binary(host) and path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(value, "/")}

      _ ->
        {:error, :invalid_origin}
    end
  end

  defp origin(_), do: {:error, :invalid_origin}
end
