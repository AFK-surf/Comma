defmodule Comma.Auth.Abuse.Apple do
  @moduledoc false
  import Ecto.Query
  alias Comma.Auth.Abuse.{AppleKey, AppleVerifier}
  alias Comma.Repo

  def configured?,
    do:
      config()[:app_id] not in [nil, ""] and
        config()[:environment] in ["development", "production"]

  def environment, do: config()[:environment]

  def verify(%{"key_id" => key_id} = proof, proof_bytes, email)
      when is_binary(key_id) and byte_size(key_id) in 1..128 do
    with true <- configured?(),
         {:ok, target} <- Comma.AuthChallenges.email_fingerprint(email) do
      case {Repo.get(AppleKey, key_id), proof} do
        {key, %{"attestation" => attestation}} when is_binary(attestation) ->
          enroll(key_id, key, target, attestation, proof_bytes)

        {%AppleKey{} = key, %{"assertion" => assertion}} when is_binary(assertion) ->
          with true <- matches?(key, target),
               {:ok, next} <-
                 AppleVerifier.assert_proof(
                   assertion,
                   proof_bytes,
                   key.public_key,
                   key.counter,
                   key.app_id
                 ),
               {1, _} <-
                 Repo.update_all(
                   from(k in AppleKey,
                     where:
                       k.key_id == ^key_id and k.counter == ^key.counter and
                         k.email_fingerprint == ^target and k.app_id == ^key.app_id and
                         k.environment == ^key.environment
                   ),
                   set: [counter: next]
                 ) do
            :ok
          else
            _ -> {:error, :native_proof_rejected}
          end

        _ ->
          {:error, :native_proof_rejected}
      end
    else
      _ -> {:error, :native_proof_rejected}
    end
  rescue
    _ -> {:error, :native_proof_rejected}
  catch
    :exit, _ -> {:error, :native_proof_rejected}
  end

  def verify(_, _, _), do: {:error, :native_proof_rejected}

  def delete_for_email(email) do
    with {:ok, target} <- Comma.AuthChallenges.email_fingerprint(email) do
      Repo.delete_all(from(k in AppleKey, where: k.email_fingerprint == ^target))
      :ok
    end
  end

  defp enroll(key_id, existing, target, attestation, proof_bytes) do
    with true <- is_nil(existing) or matches?(existing, target),
         {:ok, verified} <-
           AppleVerifier.attest(
             attestation,
             key_id,
             proof_bytes,
             config()[:app_id],
             String.to_existing_atom(config()[:environment]),
             config()[:verifier_options] || []
           ) do
      Repo.insert_all(
        AppleKey,
        [
          %{
            key_id: key_id,
            email_fingerprint: target,
            app_id: config()[:app_id],
            environment: config()[:environment],
            public_key: verified.public_key,
            counter: 0,
            inserted_at: SystemsClock.timestamp(:utc_datetime_usec)
          }
        ],
        on_conflict: :nothing
      )

      key = Repo.get!(AppleKey, key_id)

      if matches?(key, target) and key.public_key == verified.public_key,
        do: :ok,
        else: {:error, :native_proof_rejected}
    else
      _ -> {:error, :native_proof_rejected}
    end
  end

  defp matches?(key, target),
    do:
      key.email_fingerprint == target and key.app_id == config()[:app_id] and
        key.environment == config()[:environment]

  defp config, do: SystemsRuntime.get_env(:comma_core, :auth_abuse, [])[:apple] || []
end
