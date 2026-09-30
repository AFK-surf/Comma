defmodule Comma.AuthChallengeStore.Memory do
  @moduledoc "In-memory auth challenge and abuse-control store for dev/test."

  @behaviour Comma.AuthChallengeStore

  @table __MODULE__
  @lock {__MODULE__, :lock}

  @impl true
  def reserve_attempt(%{"id" => id} = challenge, ttl_seconds, opts) do
    transaction(fn ->
      now = now_ms()
      peer_key = google_attempt_peer_window_key(Map.fetch!(opts, :ip_fingerprint))

      cond do
        window_count(peer_key, now) >= Map.fetch!(opts, :ip_request_limit) ->
          {:error, :rate_limited, retry_after(peer_key, now)}

        lookup(challenge_key(id), now) != nil ->
          {:error, :challenge_collision}

        true ->
          increment_window(peer_key, Map.fetch!(opts, :ip_request_window_seconds), now)
          put(challenge_key(id), challenge, seconds_from_now(now, ttl_seconds))
          :ok
      end
    end)
  end

  @impl true
  def verify(id, code_hash, max_attempts) when is_binary(id) and is_binary(code_hash) do
    transaction(fn ->
      now = now_ms()

      case lookup(challenge_key(id), now) do
        %{} = challenge ->
          if challenge["code_hash"] == code_hash do
            :ets.delete(@table, challenge_key(id))
            {:ok, challenge}
          else
            attempts = (challenge["attempts"] || 0) + 1

            if attempts >= max_attempts do
              :ets.delete(@table, challenge_key(id))
              {:error, :too_many_attempts}
            else
              update_value(challenge_key(id), Map.put(challenge, "attempts", attempts))
              {:error, :invalid_code}
            end
          end

        nil ->
          {:error, :not_found}

        _invalid ->
          {:error, :invalid_challenge}
      end
    end)
  end

  @impl true
  def reserve(
        %{"id" => id, "email_fingerprint" => email_fingerprint} = challenge,
        ttl_seconds,
        opts
      ) do
    transaction(fn ->
      now = now_ms()

      cond do
        retry_after(circuit_key(), now) > 0 ->
          {:error, :provider_unavailable, retry_after(circuit_key(), now)}

        retry_after(cooldown_key(email_fingerprint), now) > 0 ->
          {:error, :rate_limited, retry_after(cooldown_key(email_fingerprint), now)}

        window_count(email_window_key(email_fingerprint), now) >=
            Map.fetch!(opts, :email_request_limit) ->
          {:error, :rate_limited, retry_after(email_window_key(email_fingerprint), now)}

        window_count(ip_window_key(Map.fetch!(opts, :ip_fingerprint)), now) >=
            Map.fetch!(opts, :ip_request_limit) ->
          {:error, :rate_limited,
           retry_after(ip_window_key(Map.fetch!(opts, :ip_fingerprint)), now)}

        lookup(challenge_key(id), now) != nil ->
          {:error, :challenge_collision}

        true ->
          increment_window(
            email_window_key(email_fingerprint),
            Map.fetch!(opts, :email_request_window_seconds),
            now
          )

          increment_window(
            ip_window_key(Map.fetch!(opts, :ip_fingerprint)),
            Map.fetch!(opts, :ip_request_window_seconds),
            now
          )

          put(
            cooldown_key(email_fingerprint),
            true,
            seconds_from_now(now, opts.resend_cooldown_seconds)
          )

          put(challenge_key(id), challenge, seconds_from_now(now, ttl_seconds))
          :ok
      end
    end)
  end

  @impl true
  def verify(id, code_hash, max_attempts, opts) when is_binary(id) and is_binary(code_hash) do
    transaction(fn ->
      now = now_ms()

      case lookup(challenge_key(id), now) do
        %{"email_fingerprint" => email_fingerprint} = challenge ->
          failure_key = verification_window_key(email_fingerprint)
          failure_count = window_count(failure_key, now)

          cond do
            failure_count >= Map.fetch!(opts, :verification_failure_limit) ->
              {:error, :rate_limited, retry_after(failure_key, now)}

            challenge["code_hash"] == code_hash ->
              :ets.delete(@table, challenge_key(id))
              :ets.delete(@table, failure_key)
              {:ok, challenge}

            true ->
              attempts = (challenge["attempts"] || 0) + 1

              failures =
                increment_window(
                  failure_key,
                  Map.fetch!(opts, :verification_failure_window_seconds),
                  now
                )

              if attempts >= max_attempts do
                :ets.delete(@table, challenge_key(id))
              else
                update_value(challenge_key(id), Map.put(challenge, "attempts", attempts))
              end

              cond do
                failures >= Map.fetch!(opts, :verification_failure_limit) ->
                  {:error, :rate_limited, retry_after(failure_key, now)}

                attempts >= max_attempts ->
                  {:error, :too_many_attempts}

                true ->
                  {:error, :invalid_code}
              end
          end

        nil ->
          {:error, :not_found}

        _invalid ->
          {:error, :invalid_challenge}
      end
    end)
  end

  @impl true
  def record_delivery(:ok, _opts) do
    transaction(fn ->
      :ets.delete(@table, delivery_failure_key())
      :ets.delete(@table, circuit_key())
      :ok
    end)
  end

  def record_delivery(:error, opts) do
    transaction(fn ->
      now = now_ms()

      if retry_after(circuit_key(), now) > 0 do
        {:ok, :circuit_open}
      else
        failures =
          increment_window(
            delivery_failure_key(),
            Map.fetch!(opts, :provider_failure_window_seconds),
            now
          )

        if failures >= Map.fetch!(opts, :provider_failure_threshold) do
          put(
            circuit_key(),
            true,
            seconds_from_now(now, Map.fetch!(opts, :provider_circuit_open_seconds))
          )

          {:ok, :circuit_open}
        else
          :ok
        end
      end
    end)
  end

  @impl true
  def delete(id) when is_binary(id) do
    transaction(fn ->
      :ets.delete(@table, challenge_key(id))
      :ok
    end)
  end

  def reset! do
    ensure!()
    :ets.delete_all_objects(@table)
  end

  defp transaction(fun) do
    ensure!()
    :global.trans({@lock, self()}, fun)
  end

  defp ensure! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end

  defp lookup(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      [{^key, _value, _expires_at}] ->
        :ets.delete(@table, key)
        nil

      [] ->
        nil
    end
  end

  defp put(key, value, expires_at), do: :ets.insert(@table, {key, value, expires_at})

  defp update_value(key, value) do
    case :ets.lookup(@table, key) do
      [{^key, _old_value, expires_at}] -> put(key, value, expires_at)
      [] -> false
    end
  end

  defp increment_window(key, window_seconds, now) do
    case :ets.lookup(@table, key) do
      [{^key, count, expires_at}] when expires_at > now ->
        put(key, count + 1, expires_at)
        count + 1

      _expired_or_missing ->
        put(key, 1, seconds_from_now(now, window_seconds))
        1
    end
  end

  defp window_count(key, now) do
    case lookup(key, now) do
      count when is_integer(count) -> count
      _other -> 0
    end
  end

  defp retry_after(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, _value, expires_at}] when expires_at > now ->
        max(div(expires_at - now + 999, 1_000), 1)

      [{^key, _value, _expires_at}] ->
        :ets.delete(@table, key)
        0

      [] ->
        0
    end
  end

  defp challenge_key(id), do: {:challenge, id}
  defp cooldown_key(fingerprint), do: {:request_cooldown, fingerprint}
  defp email_window_key(fingerprint), do: {:request_email, fingerprint}
  defp ip_window_key(fingerprint), do: {:request_ip, fingerprint}
  defp verification_window_key(fingerprint), do: {:verify_email, fingerprint}
  defp google_attempt_peer_window_key(fingerprint), do: {:google_attempt_peer, fingerprint}
  defp delivery_failure_key, do: :delivery_failures
  defp circuit_key, do: :delivery_circuit
  defp seconds_from_now(now, seconds), do: now + seconds * 1_000
  defp now_ms, do: System.monotonic_time(:millisecond)
end
