defmodule SalixIM.VoiceConnects do
  @moduledoc """
  The voice IM Connect of one Group: verified caller numbers, their global
  reservations, and caller PINs. Contract: `docs/messaging-voice.md`.

  Each Group that uses voice has one `voice` connect. It is the delivery
  connect for every call of the Group, and it lists the caller numbers that
  may reach the Group through a carrier line. The single connect is elected
  by the `ProviderIdentity` reservation `voice:group:<group_id>`.

  Each bound number holds the reservation `voice:<carrier>:<line>:<e164>`, so
  one caller number on one line routes to exactly one connect. A writer
  reserves the number before it lists it on the connect and releases the
  reservation after it removes the number, so the reservation is a complete
  index. Readers still re-check the connect record: a reservation whose
  holder no longer lists the number never routes a call, and another Group
  may take it over after a short grace period for an in-flight binding.

  Number verification (an SMS code) belongs to the caller of
  `confirm_voice_number/5`; this module takes an already verified number.
  PINs are stored only as salted PBKDF2-SHA256 hashes. `public/1` never
  returns a hash.
  """

  alias SalixIM.{GroupDirectory, ProviderIdentity}
  alias SalixStore.{CasRecord, Ids, Keys}

  @provider "voice"
  @carriers ~w(twilio)
  @e164 ~r/\A\+[1-9]\d{6,14}\z/
  @pin ~r/\A\d{4,8}\z/
  @max_numbers 20
  # A reservation whose holder does not list the number yet may belong to a
  # binding that is between its reserve and its connect write.
  @stale_grace_ms 60_000
  @pbkdf2_iterations 100_000
  @default_pin_max_failures 5
  @default_pin_lockout_seconds 900

  # ---- connect ----

  @doc "Returns the Group's voice connect, creating it once. The result is `public/1`."
  def ensure_voice_im_connect(tenant_id, group_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- ensure_record(tenant_id, group_id, 3) do
      {:ok, public(rec)}
    end
  end

  @doc "The Group's current voice connect as `public/1`, or `{:error, :not_found}`."
  def get_voice_im_connect(tenant_id, group_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- current_record(group_id),
         true <- rec["tenant_id"] == tenant_id do
      {:ok, public(rec)}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_record(_tenant_id, _group_id, 0), do: {:error, :voice_connect_unavailable}

  defp ensure_record(tenant_id, group_id, attempts) do
    case current_record(group_id) do
      {:ok, rec} ->
        {:ok, rec}

      {:error, :not_found} ->
        connect_id = Ids.new_connect_id()

        case ProviderIdentity.reserve_voice(
               ProviderIdentity.voice_group_identity(group_id),
               tenant_id,
               group_id,
               connect_id,
               &stale_group_election?/1
             ) do
          :ok ->
            create_record(tenant_id, group_id, connect_id)

          {:error, {:voice_identity_in_use, _holder}} ->
            # Another writer won the election and is writing its connect.
            Process.sleep(50)
            ensure_record(tenant_id, group_id, attempts - 1)

          other ->
            other
        end

      other ->
        other
    end
  end

  defp create_record(tenant_id, group_id, connect_id) do
    now = now()

    rec = %{
      "connect_id" => connect_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => @provider,
      "status" => "connected",
      "last_error" => "",
      "voice_numbers" => [],
      "connected_at" => now,
      "created_at" => now,
      "updated_at" => now
    }

    case CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec) do
      {:ok, rec} ->
        {:ok, rec}

      other ->
        _ =
          ProviderIdentity.release_provider(
            @provider,
            ProviderIdentity.voice_group_identity(group_id),
            connect_id
          )

        other
    end
  end

  # The elected connect of the Group, if its record is live.
  defp current_record(group_id) do
    with {:ok, election} <-
           CasRecord.get(
             Keys.ctl_im_provider_identity(
               @provider,
               ProviderIdentity.voice_group_identity(group_id)
             )
           ),
         {:ok, ^group_id, connect_id} <-
           ProviderIdentity.authority_coordinates(
             @provider,
             ProviderIdentity.voice_group_identity(group_id),
             election
           ),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         true <- voice_record?(rec, group_id, connect_id) and is_nil(rec["deleted_at"]) do
      {:ok, rec}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp stale_group_election?(%{"group_id" => group_id, "connect_id" => connect_id} = election)
       when is_binary(group_id) and is_binary(connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, rec} -> not is_nil(rec["deleted_at"]) or rec["provider"] != @provider
      {:error, :not_found} -> past_grace?(election)
      {:error, _} -> false
    end
  end

  defp stale_group_election?(_election), do: true

  # ---- numbers ----

  @doc """
  Checks, before verification starts, that `e164` on `line` is free or
  already bound to this Group. Returns `:ok`,
  `{:error, :voice_number_in_use}` or `{:error, {:bad_request, message}}`.
  """
  def check_voice_number_available(tenant_id, group_id, carrier, line, e164) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, carrier, line, e164} <- validate_number(carrier, line, e164) do
      identity = ProviderIdentity.voice_number_identity(carrier, line, e164)

      case CasRecord.get(Keys.ctl_im_provider_identity(@provider, identity)) do
        {:error, :not_found} ->
          :ok

        {:ok, %{"group_id" => ^group_id}} ->
          :ok

        {:ok, holder} ->
          if stale_number_reservation?(holder, carrier, line, e164),
            do: :ok,
            else: {:error, :voice_number_in_use}

        other ->
          other
      end
    end
  end

  @doc """
  Binds a verified caller number to the Group's voice connect. Reserves the
  number first; a number held by another Group is
  `{:error, :voice_number_in_use}`. Rebinding keeps the number's PIN.
  """
  def confirm_voice_number(tenant_id, group_id, carrier, line, e164) do
    with {:ok, carrier, line, e164} <- validate_number(carrier, line, e164),
         {:ok, connect} <- ensure_voice_im_connect(tenant_id, group_id) do
      connect_id = connect["connect_id"]
      identity = ProviderIdentity.voice_number_identity(carrier, line, e164)

      case ProviderIdentity.reserve_voice(
             identity,
             tenant_id,
             group_id,
             connect_id,
             &stale_number_reservation?(&1, carrier, line, e164)
           ) do
        :ok ->
          case add_number(group_id, connect_id, carrier, line, e164) do
            {:ok, rec} ->
              {:ok, public(rec)}

            error ->
              _ = ProviderIdentity.release_provider(@provider, identity, connect_id)
              error
          end

        {:error, {:voice_identity_in_use, _holder}} ->
          {:error, :voice_number_in_use}

        other ->
          other
      end
    end
  end

  defp add_number(group_id, connect_id, carrier, line, e164) do
    update_live(group_id, connect_id, fn rec ->
      numbers = numbers(rec)
      {existing, others} = Enum.split_with(numbers, &same_number?(&1, carrier, line, e164))

      if existing == [] and length(numbers) >= @max_numbers do
        {:error, {:bad_request, "a voice connect holds at most #{@max_numbers} numbers"}}
      else
        entry =
          existing
          |> List.first(%{
            "e164" => e164,
            "carrier" => carrier,
            "line" => line,
            "pin_failures" => 0,
            "pin_locked_until" => nil
          })
          |> Map.put("verified_at", now())

        Map.put(rec, "voice_numbers", others ++ [entry])
      end
    end)
  end

  @doc """
  Removes every binding of `e164` (on any line, or only on `opts[:line]`)
  from the Group's voice connect and releases their reservations.
  """
  def remove_voice_number(tenant_id, group_id, e164, opts \\ []) do
    e164 = trim(e164)

    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, current} <- current_record(group_id),
         true <- current["tenant_id"] == tenant_id,
         removed = Enum.filter(numbers(current), &removes?(&1, e164, opts[:line])),
         false <- removed == [],
         {:ok, rec} <-
           update_live(group_id, current["connect_id"], fn rec ->
             Map.put(
               rec,
               "voice_numbers",
               Enum.reject(numbers(rec), &removes?(&1, e164, opts[:line]))
             )
           end) do
      # A failed release leaves a reservation whose holder no longer lists the
      # number; the next binding takes it over as stale.
      Enum.each(removed, fn entry ->
        ProviderIdentity.release_provider(
          @provider,
          ProviderIdentity.voice_number_identity(entry["carrier"], entry["line"], entry["e164"]),
          rec["connect_id"]
        )
      end)

      {:ok, public(rec)}
    else
      true -> {:error, :not_found}
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp removes?(entry, e164, nil), do: entry["e164"] == e164
  defp removes?(entry, e164, line), do: entry["e164"] == e164 and entry["line"] == trim(line)

  # A reservation is stale when its holder is gone, deleted, or does not list
  # the number after the in-flight grace period.
  defp stale_number_reservation?(
         %{"group_id" => group_id, "connect_id" => connect_id} = holder,
         carrier,
         line,
         e164
       )
       when is_binary(group_id) and is_binary(connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, rec} ->
        cond do
          not is_nil(rec["deleted_at"]) or rec["provider"] != @provider -> true
          Enum.any?(numbers(rec), &same_number?(&1, carrier, line, e164)) -> false
          true -> past_grace?(holder)
        end

      {:error, :not_found} ->
        true

      {:error, _} ->
        false
    end
  end

  defp stale_number_reservation?(_holder, _carrier, _line, _e164), do: true

  # ---- lookup ----

  @doc """
  Resolves the live voice connect that bound `e164` on `line`, through the
  number reservation. Returns `public/1` of the connect plus `"number"`, the
  public projection of the matched binding, or `{:error, :not_found}`.
  """
  def find_voice_connect(carrier, line, e164) do
    with {:ok, carrier, line, e164} <- validate_number(carrier, line, e164),
         identity = ProviderIdentity.voice_number_identity(carrier, line, e164),
         {:ok, reservation} <- CasRecord.get(Keys.ctl_im_provider_identity(@provider, identity)),
         {:ok, group_id, connect_id} <-
           ProviderIdentity.authority_coordinates(@provider, identity, reservation),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         true <- voice_record?(rec, group_id, connect_id) and routable?(rec),
         %{} = entry <- Enum.find(numbers(rec), &same_number?(&1, carrier, line, e164)) do
      {:ok, rec |> public() |> Map.put("number", number_public(entry))}
    else
      {:error, {:bad_request, _}} = error -> error
      {:error, reason} when reason not in [:not_found, :invalid_record] -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp routable?(rec),
    do: is_nil(rec["deleted_at"]) and is_nil(rec["disabled_at"]) and rec["status"] == "connected"

  # ---- PIN ----

  @doc """
  Sets (or with `nil`/`""` clears) the PIN of every binding of `e164`. A PIN
  is 4 to 8 digits. Setting a PIN clears its failure count and lockout.
  """
  def set_voice_number_pin(tenant_id, group_id, e164, pin) do
    e164 = trim(e164)
    pin = trim(pin)

    with :ok <- validate_pin_format(pin),
         {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, current} <- current_record(group_id),
         true <- current["tenant_id"] == tenant_id,
         true <- Enum.any?(numbers(current), &(&1["e164"] == e164)) do
      pin_hash = if pin == "", do: nil, else: hash_pin(pin)

      update_live(group_id, current["connect_id"], fn rec ->
        Map.put(
          rec,
          "voice_numbers",
          Enum.map(numbers(rec), fn
            %{"e164" => ^e164} = entry ->
              entry
              |> Map.put("pin_hash", pin_hash)
              |> Map.put("pin_failures", 0)
              |> Map.put("pin_locked_until", nil)

            entry ->
              entry
          end)
        )
      end)
      |> case do
        {:ok, rec} -> {:ok, public(rec)}
        other -> other
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp validate_pin_format(""), do: :ok

  defp validate_pin_format(pin) do
    if Regex.match?(@pin, pin),
      do: :ok,
      else: {:error, {:bad_request, "pin must be 4 to 8 digits"}}
  end

  @doc """
  Checks a caller PIN for one binding and records the outcome.

  Returns `:ok`, `{:error, {:invalid_pin, remaining_attempts}}`,
  `{:error, {:locked, locked_until_ms}}`, `{:error, :pin_not_configured}` or
  `{:error, :not_found}`. The failure that reaches `:max_failures` (default
  5) locks the binding for `:lockout_seconds` (default 900); success clears
  the failure count.
  """
  def verify_voice_pin(group_id, connect_id, carrier, line, e164, pin, opts \\ []) do
    max_failures = positive(opts[:max_failures], @default_pin_max_failures)
    lockout_ms = positive(opts[:lockout_seconds], @default_pin_lockout_seconds) * 1_000
    now = Keyword.get(opts, :now_ms, now())

    with {:ok, carrier, line, e164} <- validate_number(carrier, line, e164),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, trim(connect_id))),
         true <- voice_record?(rec, group_id, trim(connect_id)) and is_nil(rec["deleted_at"]),
         %{} = entry <- Enum.find(numbers(rec), &same_number?(&1, carrier, line, e164)) do
      cond do
        not is_binary(entry["pin_hash"]) ->
          {:error, :pin_not_configured}

        locked?(entry, now) ->
          {:error, {:locked, entry["pin_locked_until"]}}

        true ->
          record_pin_attempt(
            rec,
            carrier,
            line,
            e164,
            entry["pin_hash"],
            pin_matches?(entry["pin_hash"], trim(pin)),
            max_failures,
            lockout_ms,
            now
          )
      end
    else
      {:error, {:bad_request, _}} = error -> error
      {:error, reason} when reason != :not_found -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  # The outcome is recorded against the hash that was checked; a PIN changed
  # meanwhile makes this attempt count for nothing. The CAS function may run
  # more than once; the outcome of the committed run is the last one stored.
  defp record_pin_attempt(rec, carrier, line, e164, hash, match?, max_failures, lockout_ms, now) do
    outcome_key = {__MODULE__, :pin_outcome, make_ref()}
    Process.put(outcome_key, {:error, :not_found})

    result =
      update_live(rec["group_id"], rec["connect_id"], fn current ->
        Process.put(outcome_key, {:error, :not_found})

        numbers =
          Enum.map(numbers(current), fn entry ->
            if same_number?(entry, carrier, line, e164) and entry["pin_hash"] == hash do
              {outcome, entry} = pin_attempt(entry, match?, max_failures, lockout_ms, now)
              Process.put(outcome_key, outcome)
              entry
            else
              entry
            end
          end)

        Map.put(current, "voice_numbers", numbers)
      end)

    outcome = Process.delete(outcome_key)

    case result do
      {:ok, _rec} -> outcome
      other -> other
    end
  end

  defp pin_attempt(entry, match?, max_failures, lockout_ms, now) do
    failures = integer(entry["pin_failures"]) + 1

    cond do
      locked?(entry, now) ->
        {{:error, {:locked, entry["pin_locked_until"]}}, entry}

      match? ->
        {:ok, entry |> Map.put("pin_failures", 0) |> Map.put("pin_locked_until", nil)}

      failures >= max_failures ->
        until = now + lockout_ms

        {{:error, {:locked, until}},
         entry |> Map.put("pin_failures", 0) |> Map.put("pin_locked_until", until)}

      true ->
        {{:error, {:invalid_pin, max_failures - failures}},
         Map.put(entry, "pin_failures", failures)}
    end
  end

  defp locked?(entry, now), do: integer(entry["pin_locked_until"]) > now

  @doc false
  def hash_pin(pin) do
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, pin, salt, @pbkdf2_iterations, 32)

    Enum.join(
      [
        "pbkdf2_sha256",
        Integer.to_string(@pbkdf2_iterations),
        Base.url_encode64(salt, padding: false),
        Base.url_encode64(digest, padding: false)
      ],
      "$"
    )
  end

  defp pin_matches?(hash, pin) when is_binary(pin) and pin != "" do
    with ["pbkdf2_sha256", iterations, salt, digest] <- String.split(hash, "$"),
         {iterations, ""} when iterations > 0 and iterations <= 10_000_000 <-
           Integer.parse(iterations),
         {:ok, salt} <- Base.url_decode64(salt, padding: false),
         {:ok, digest} <- Base.url_decode64(digest, padding: false) do
      candidate = :crypto.pbkdf2_hmac(:sha256, pin, salt, iterations, byte_size(digest))
      :crypto.hash_equals(candidate, digest)
    else
      _ -> false
    end
  end

  defp pin_matches?(_hash, _pin), do: false

  # ---- projection ----

  @doc "Credential-free projection of a voice connect record."
  def public(rec) when is_map(rec) do
    rec
    |> Map.take(~w(connect_id tenant_id group_id provider status last_error connected_at
      disabled_at created_at updated_at))
    |> Map.put("numbers", Enum.map(numbers(rec), &number_public/1))
  end

  defp number_public(entry) do
    now = now()

    %{
      "e164" => entry["e164"],
      "carrier" => entry["carrier"],
      "line" => entry["line"],
      "verified_at" => entry["verified_at"],
      "pin_configured" => is_binary(entry["pin_hash"]),
      "pin_failures" => integer(entry["pin_failures"]),
      "pin_locked_until" => if(locked?(entry, now), do: entry["pin_locked_until"])
    }
  end

  # ---- helpers ----

  defp validate_number(carrier, line, e164) do
    carrier = trim(carrier)
    line = trim(line)
    e164 = trim(e164)

    cond do
      carrier not in @carriers -> {:error, {:bad_request, "unsupported voice carrier"}}
      not Regex.match?(@e164, line) -> {:error, {:bad_request, "line must be an E.164 number"}}
      not Regex.match?(@e164, e164) -> {:error, {:bad_request, "number must be an E.164 number"}}
      true -> {:ok, carrier, line, e164}
    end
  end

  defp update_live(group_id, connect_id, fun) do
    key = Keys.ctl_im_connect(group_id, connect_id)

    CasRecord.update(
      key,
      fn
        %{"deleted_at" => deleted} when not is_nil(deleted) ->
          {:error, :not_found}

        %{"provider" => @provider} = rec ->
          case fun.(rec) do
            %{} = next -> Map.put(next, "updated_at", now())
            other -> other
          end

        _other ->
          {:error, :not_found}
      end,
      create: false
    )
  end

  defp voice_record?(rec, group_id, connect_id) do
    rec["provider"] == @provider and rec["group_id"] == group_id and
      rec["connect_id"] == connect_id
  end

  defp numbers(rec) do
    rec
    |> Map.get("voice_numbers", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp same_number?(entry, carrier, line, e164) do
    entry["carrier"] == carrier and entry["line"] == line and entry["e164"] == e164
  end

  defp past_grace?(reservation),
    do: now() - integer(reservation["updated_at"] || reservation["created_at"]) > @stale_grace_ms

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp now, do: System.system_time(:millisecond)
end
