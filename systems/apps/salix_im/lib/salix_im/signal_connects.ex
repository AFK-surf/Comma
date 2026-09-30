defmodule SalixIM.SignalConnects do
  @moduledoc """
  The Signal IM Connect of one Group: the Signal peers bound to the Group,
  their global reservations, and pending claim codes. Contract:
  `docs/messaging-voice.md`.

  Each Group that uses Signal has one `signal` connect, elected by the
  `ProviderIdentity` reservation `signal:group:<group_id>`. It is the delivery
  connect for every Signal message of the Group.

  A peer is a Signal account (its ACI) for a private chat, or a Signal group
  (`group:<base64url group identifier>`). A binding names the peer and the
  Comma Signal account (`account_id`, a `SalixSignal.Accounts` ID) that talks
  with it. Each binding holds the reservation `signal:peer:<account_id>:<peer>`,
  so one peer on one account routes to exactly one connect. A writer reserves
  before it lists the peer and releases after it removes the peer, so the
  reservation is a complete index. Readers still re-check the connect record.
  A release is an owner-checked CAS tombstone, never a delete, so a delayed
  release cannot remove a reservation that another connect has taken over.

  A peer binds by sending a claim code to the account. `start_claim/5` stores
  only the SHA-256 digest of the code on the connect and reserves
  `signal:claim:<account_id>:<digest>`, so an inbound message finds its claim
  with one read. A claim is single use and expires after 10 minutes. The code
  is returned once and never stored.
  """

  alias SalixIM.{GroupDirectory, ProviderIdentity}
  alias SalixStore.{CasRecord, Ids, Keys}

  @provider "signal"
  @max_bindings 50
  @max_claims 5
  @claim_ttl_ms 600_000
  # A reservation whose holder does not list the peer yet may belong to a
  # binding that is between its reserve and its connect write.
  @stale_grace_ms 60_000
  # 8 characters of a 32-character alphabet without 0, 1, I and O: 40 bits.
  @code_alphabet ~c"23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
  @code_length 8
  @command_prefix "comma connect"

  @doc "Words a sender types before the claim code."
  def command_prefix, do: @command_prefix

  @doc "The lifetime of a claim code, in milliseconds."
  def claim_ttl_ms, do: @claim_ttl_ms

  # ---- connect ----

  @doc "Returns the Group's Signal connect, creating it once. The result is `public/1`."
  def ensure_signal_im_connect(tenant_id, group_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- ensure_record(tenant_id, group_id, 3) do
      {:ok, public(rec)}
    end
  end

  @doc "The Group's current Signal connect as `public/1`, or `{:error, :not_found}`."
  def get_signal_im_connect(tenant_id, group_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, rec} <- current_record(group_id),
         true <- rec["tenant_id"] == tenant_id do
      {:ok, public(rec)}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_record(_tenant_id, _group_id, 0), do: {:error, :signal_connect_unavailable}

  defp ensure_record(tenant_id, group_id, attempts) do
    case current_record(group_id) do
      {:ok, rec} ->
        {:ok, rec}

      {:error, :not_found} ->
        connect_id = Ids.new_connect_id()

        case reserve(
               ProviderIdentity.signal_group_identity(group_id),
               tenant_id,
               group_id,
               connect_id,
               &stale_group_election?/1
             ) do
          :ok ->
            create_record(tenant_id, group_id, connect_id)

          {:error, {:identity_in_use, _holder}} ->
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
      "signal_bindings" => [],
      "signal_claims" => [],
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
            ProviderIdentity.signal_group_identity(group_id),
            connect_id
          )

        other
    end
  end

  defp current_record(group_id) do
    identity = ProviderIdentity.signal_group_identity(group_id)

    with {:ok, election} <- read_reservation(identity),
         {:ok, ^group_id, connect_id} <-
           ProviderIdentity.authority_coordinates(@provider, identity, election),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         true <- signal_record?(rec, group_id, connect_id) and is_nil(rec["deleted_at"]) do
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

  # ---- claims ----

  @doc """
  Starts a claim for the Group on the Signal account `account_id`. Returns
  `{:ok, %{"claim_id", "code", "command", "account_id", "expires_at"}}`. The
  plaintext code appears only in this result. A connect keeps at most 5
  pending claims; a new claim retires expired claims and then the oldest.
  """
  def start_claim(tenant_id, group_id, account_id, created_by, opts \\ []) do
    account_id = trim(account_id)
    now = Keyword.get(opts, :now_ms, now())

    with :ok <- require_present(account_id, "account_id"),
         {:ok, connect} <- ensure_signal_im_connect(tenant_id, group_id) do
      connect_id = connect["connect_id"]
      code = Keyword.get_lazy(opts, :code, &new_code/0)
      digest = digest(code)
      identity = ProviderIdentity.signal_claim_identity(account_id, digest)

      claim = %{
        "claim_id" => "sgc_" <> Ids.new_connect_id(),
        "account_id" => account_id,
        "code_digest" => digest,
        "created_by" => trim(created_by),
        "created_at" => now,
        "expires_at" => now + @claim_ttl_ms
      }

      # A digest collision with a live claim of another connect is refused:
      # the claim is not stale while its holder lists it.
      with :ok <-
             reserve(identity, tenant_id, group_id, connect_id, &stale_claim?(&1, account_id)),
           {:ok, _rec, retired} <- add_claim(group_id, connect_id, claim, now) do
        release_claims(retired, connect_id)

        {:ok,
         %{
           "claim_id" => claim["claim_id"],
           "code" => format_code(code),
           "command" => "#{@command_prefix} #{format_code(code)}",
           "account_id" => account_id,
           "expires_at" => claim["expires_at"]
         }}
      else
        {:error, {:identity_in_use, _holder}} ->
          {:error, :signal_claim_unavailable}

        error ->
          _ = ProviderIdentity.release_provider(@provider, identity, connect_id)
          error
      end
    end
  end

  defp add_claim(group_id, connect_id, claim, now) do
    retired_key = {__MODULE__, :retired, make_ref()}

    result =
      update_live(group_id, connect_id, fn rec ->
        {live, expired} = Enum.split_with(claims(rec), &(integer(&1["expires_at"]) > now))
        overflow = max(length(live) + 1 - @max_claims, 0)
        {oldest, kept} = live |> Enum.sort_by(&integer(&1["created_at"])) |> Enum.split(overflow)
        Process.put(retired_key, expired ++ oldest)
        Map.put(rec, "signal_claims", kept ++ [claim])
      end)

    retired = Process.delete(retired_key) || []

    case result do
      {:ok, rec} -> {:ok, rec, retired}
      other -> other
    end
  end

  @doc "Cancels one pending claim. Returns `public/1` of the connect."
  def cancel_claim(tenant_id, group_id, claim_id) do
    claim_id = trim(claim_id)

    with {:ok, current} <- owned_record(tenant_id, group_id),
         %{} = claim <- Enum.find(claims(current), &(&1["claim_id"] == claim_id)),
         {:ok, rec} <-
           update_live(group_id, current["connect_id"], fn rec ->
             Map.put(
               rec,
               "signal_claims",
               Enum.reject(claims(rec), &(&1["claim_id"] == claim_id))
             )
           end) do
      release_claims([claim], rec["connect_id"])
      {:ok, public(rec)}
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Redeems a claim code that `peer` sent to the Signal account `account_id`
  and binds the peer to the claim's Group.

  `peer` is `%{"kind" => "user" | "group", "peer" => id, "display_name" =>
  name | nil}`. Returns `{:ok, %{"tenant_id", "group_id", "connect_id",
  "binding"}}`, `{:error, :invalid_claim}` for an unknown, expired or used
  code, or `{:error, :signal_peer_in_use}` when another Group holds the peer.
  """
  def redeem_claim(account_id, code, peer, opts \\ []) do
    account_id = trim(account_id)
    now = Keyword.get(opts, :now_ms, now())

    with {:ok, code} <- parse_code(code),
         {:ok, kind, peer_id, name} <- validate_peer(peer),
         digest = digest(code),
         identity = ProviderIdentity.signal_claim_identity(account_id, digest),
         {:ok, reservation} <- read_reservation(identity),
         {:ok, group_id, connect_id} <- coordinates(identity, reservation),
         {:ok, rec} <- live_record(group_id, connect_id),
         %{} = claim <- live_claim(rec, account_id, digest, now) do
      binding = %{
        "binding_id" => "sgb_" <> Ids.new_connect_id(),
        "account_id" => account_id,
        "kind" => kind,
        "peer" => peer_id,
        "display_name" => name,
        "bound_at" => now,
        "bound_by" => "claim:" <> claim["claim_id"]
      }

      # The binding write consumes the claim only if the latest record still
      # holds it unexpired: a cancel, an eviction or another redemption may
      # have removed it since `rec` was read.
      consume = fn latest ->
        if Enum.any?(
             claims(latest),
             &(&1["claim_id"] == claim["claim_id"] and
                 integer(&1["expires_at"]) > now)
           ),
           do: Map.put(latest, "signal_claims", drop_claim(latest, claim)),
           else: {:error, :invalid_claim}
      end

      with {:ok, _bound} = ok <- bind(rec, binding, consume) do
        release_claims([claim], connect_id)
        ok
      end
    else
      {:error, :signal_peer_in_use} = error -> error
      {:error, {:bad_request, _}} = error -> error
      {:error, reason} when reason not in [:not_found, :invalid_record] -> {:error, reason}
      _ -> {:error, :invalid_claim}
    end
  end

  defp live_claim(rec, account_id, digest, now) do
    Enum.find(claims(rec), fn claim ->
      claim["account_id"] == account_id and is_binary(claim["code_digest"]) and
        :crypto.hash_equals(claim["code_digest"], digest) and
        integer(claim["expires_at"]) > now
    end)
  end

  defp drop_claim(rec, claim),
    do: Enum.reject(claims(rec), &(&1["claim_id"] == claim["claim_id"]))

  @doc """
  Binds `peer` on `account_id` to the Group directly, without a claim. Used
  when the Router joins a Signal group at the request of a peer that is
  already bound to the Group. Same results as `redeem_claim/4`.
  """
  def bind_peer(tenant_id, group_id, account_id, peer, bound_by) do
    with {:ok, kind, peer_id, name} <- validate_peer(peer),
         :ok <- require_present(trim(account_id), "account_id"),
         {:ok, connect} <- ensure_signal_im_connect(tenant_id, group_id),
         {:ok, rec} <- live_record(group_id, connect["connect_id"]) do
      binding = %{
        "binding_id" => "sgb_" <> Ids.new_connect_id(),
        "account_id" => trim(account_id),
        "kind" => kind,
        "peer" => peer_id,
        "display_name" => name,
        "bound_at" => now(),
        "bound_by" => trim(bound_by)
      }

      bind(rec, binding, & &1)
    end
  end

  # Reserve the peer, then list it (with `also` applied in the same write).
  # `also` may refuse the write with `{:error, reason}`. A peer already listed
  # on this connect keeps its binding.
  defp bind(rec, binding, also) do
    %{"tenant_id" => tenant_id, "group_id" => group_id, "connect_id" => connect_id} = rec
    %{"account_id" => account_id, "peer" => peer} = binding
    identity = ProviderIdentity.signal_peer_identity(account_id, peer)

    case reserve(identity, tenant_id, group_id, connect_id, &stale_peer?(&1, account_id, peer)) do
      :ok ->
        case add_binding(group_id, connect_id, binding, also) do
          {:ok, rec, entry} ->
            {:ok,
             %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => connect_id,
               "binding" => binding_public(entry),
               "connect" => public(rec)
             }}

          error ->
            if not listed?(rec, account_id, peer),
              do: ProviderIdentity.release_provider(@provider, identity, connect_id)

            error
        end

      {:error, {:identity_in_use, _holder}} ->
        # The claim stays usable: the peer may unbind elsewhere and retry.
        {:error, :signal_peer_in_use}

      other ->
        other
    end
  end

  defp add_binding(group_id, connect_id, binding, also) do
    entry_key = {__MODULE__, :entry, make_ref()}

    result =
      update_live(group_id, connect_id, fn rec ->
        with %{} = rec <- also.(rec) do
          bindings = bindings(rec)

          {existing, others} =
            Enum.split_with(bindings, &same_peer?(&1, binding["account_id"], binding["peer"]))

          cond do
            existing != [] ->
              entry = hd(existing)
              Process.put(entry_key, entry)
              Map.put(rec, "signal_bindings", others ++ [entry])

            length(bindings) >= @max_bindings ->
              {:error, {:bad_request, "a Signal connect holds at most #{@max_bindings} bindings"}}

            true ->
              Process.put(entry_key, binding)
              Map.put(rec, "signal_bindings", bindings ++ [binding])
          end
        end
      end)

    entry = Process.delete(entry_key)

    case result do
      {:ok, rec} -> {:ok, rec, entry}
      other -> other
    end
  end

  @doc """
  Removes one binding and releases its reservation. Returns
  `{:ok, public_connect, removed_binding}`.
  """
  def remove_binding(tenant_id, group_id, binding_id) do
    binding_id = trim(binding_id)

    with {:ok, current} <- owned_record(tenant_id, group_id),
         %{} = binding <- Enum.find(bindings(current), &(&1["binding_id"] == binding_id)),
         {:ok, rec} <-
           update_live(group_id, current["connect_id"], fn rec ->
             Map.put(
               rec,
               "signal_bindings",
               Enum.reject(bindings(rec), &(&1["binding_id"] == binding_id))
             )
           end) do
      # A failed release leaves a reservation whose holder no longer lists
      # the peer; the next binding takes it over as stale.
      _ =
        ProviderIdentity.release_provider(
          @provider,
          ProviderIdentity.signal_peer_identity(binding["account_id"], binding["peer"]),
          rec["connect_id"]
        )

      {:ok, public(rec), binding_public(binding)}
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  # ---- lookup ----

  @doc """
  Resolves the live Signal connect that bound `peer` on `account_id`,
  through the peer reservation. Returns `public/1` of the connect plus
  `"binding"`, or `{:error, :not_found}`.
  """
  def find_signal_connect(account_id, peer) do
    account_id = trim(account_id)
    peer = trim(peer)
    identity = ProviderIdentity.signal_peer_identity(account_id, peer)

    with true <- account_id != "" and peer != "",
         {:ok, reservation} <- read_reservation(identity),
         {:ok, group_id, connect_id} <- coordinates(identity, reservation),
         {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)),
         true <- signal_record?(rec, group_id, connect_id) and routable?(rec),
         %{} = entry <- Enum.find(bindings(rec), &same_peer?(&1, account_id, peer)) do
      {:ok, rec |> public() |> Map.put("binding", binding_public(entry))}
    else
      {:error, reason} when reason not in [:not_found, :invalid_record] -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc "True when `peer` on `account_id` is bound to this live connect record."
  def bound?(connect, account_id, peer) when is_map(connect),
    do: Enum.any?(bindings(connect), &same_peer?(&1, trim(account_id), trim(peer)))

  @doc "The binding of `peer` on this connect record (any account), or nil."
  def binding_for_peer(connect, peer) when is_map(connect) do
    peer = trim(peer)

    case Enum.find(bindings(connect), &(&1["peer"] == peer)) do
      nil -> nil
      entry -> binding_public(entry)
    end
  end

  @doc "Every reservation identity that this connect record lists (for release)."
  def reserved_identities(rec) when is_map(rec) do
    peers =
      for %{"account_id" => account_id, "peer" => peer} <- bindings(rec),
          do: ProviderIdentity.signal_peer_identity(account_id, peer)

    claims =
      for %{"account_id" => account_id, "code_digest" => digest} <- claims(rec),
          do: ProviderIdentity.signal_claim_identity(account_id, digest)

    peers ++ claims
  end

  # ---- codes ----

  @doc """
  Parses a claim command (`comma connect ABCD-EFGH`, any case, spaces or a
  dash inside the code). Returns `{:ok, code}` or `:error`.
  """
  def parse_command(text) when is_binary(text) do
    normalized = text |> String.trim() |> String.downcase()

    case String.split(normalized, ~r/\s+/, parts: 3) do
      ["comma", "connect", code] ->
        case parse_code(code) do
          {:ok, code} -> {:ok, code}
          _ -> {:error, :invalid_claim}
        end

      _ ->
        :error
    end
  end

  def parse_command(_text), do: :error

  defp parse_code(code) when is_binary(code) do
    code = code |> String.upcase() |> String.replace(~r/[\s-]/, "")

    if byte_size(code) == @code_length and
         Enum.all?(String.to_charlist(code), &(&1 in @code_alphabet)),
       do: {:ok, code},
       else: {:error, :invalid_claim}
  end

  defp parse_code(_code), do: {:error, :invalid_claim}

  defp new_code do
    for <<byte <- :crypto.strong_rand_bytes(@code_length)>>, into: "" do
      <<Enum.at(@code_alphabet, rem(byte, length(@code_alphabet)))>>
    end
  end

  defp format_code(code), do: String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)

  # A locator for the claim reservation. The code itself authorizes: it is
  # shown only to the signed-in user who started the claim.
  defp digest(code), do: :crypto.hash(:sha256, code) |> Base.url_encode64(padding: false)

  defp stale_claim?(%{"group_id" => group_id, "connect_id" => connect_id} = holder, account_id)
       when is_binary(group_id) and is_binary(connect_id) do
    identity = holder["identity"]

    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, rec} ->
        cond do
          not is_nil(rec["deleted_at"]) or rec["provider"] != @provider ->
            true

          Enum.any?(
            claims(rec),
            &(ProviderIdentity.signal_claim_identity(account_id, &1["code_digest"]) == identity and
                  integer(&1["expires_at"]) > now())
          ) ->
            false

          true ->
            past_grace?(holder)
        end

      {:error, :not_found} ->
        true

      {:error, _} ->
        false
    end
  end

  defp stale_claim?(_holder, _account_id), do: true

  defp release_claims(claims, connect_id) do
    Enum.each(claims, fn
      %{"account_id" => account_id, "code_digest" => digest} ->
        ProviderIdentity.release_provider(
          @provider,
          ProviderIdentity.signal_claim_identity(account_id, digest),
          connect_id
        )

      _other ->
        :ok
    end)
  end

  # ---- projection ----

  @doc "Credential-free projection of a Signal connect record. No code digests."
  def public(rec) when is_map(rec) do
    now = now()

    rec
    |> Map.take(~w(connect_id tenant_id group_id provider status last_error connected_at
      disabled_at created_at updated_at))
    |> Map.put("bindings", Enum.map(bindings(rec), &binding_public/1))
    |> Map.put(
      "pending_claims",
      for claim <- claims(rec), integer(claim["expires_at"]) > now do
        Map.take(claim, ~w(claim_id account_id created_at expires_at))
      end
    )
  end

  defp binding_public(entry),
    do: Map.take(entry, ~w(binding_id account_id kind peer display_name bound_at bound_by))

  # ---- helpers ----

  defp reserve(identity, tenant_id, group_id, connect_id, stale?),
    do:
      ProviderIdentity.reserve_indexed(
        @provider,
        identity,
        tenant_id,
        group_id,
        connect_id,
        stale?
      )

  defp stale_peer?(
         %{"group_id" => group_id, "connect_id" => connect_id} = holder,
         account_id,
         peer
       )
       when is_binary(group_id) and is_binary(connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, rec} ->
        cond do
          not is_nil(rec["deleted_at"]) or rec["provider"] != @provider -> true
          listed?(rec, account_id, peer) -> false
          true -> past_grace?(holder)
        end

      {:error, :not_found} ->
        true

      {:error, _} ->
        false
    end
  end

  defp stale_peer?(_holder, _account_id, _peer), do: true

  defp listed?(rec, account_id, peer),
    do: Enum.any?(bindings(rec), &same_peer?(&1, account_id, peer))

  defp validate_peer(%{"kind" => kind, "peer" => peer} = attrs) when kind in ["user", "group"] do
    peer = trim(peer)
    name = attrs["display_name"]
    name = if is_binary(name) and String.valid?(name), do: String.slice(String.trim(name), 0, 120)

    cond do
      peer == "" or byte_size(peer) > 128 ->
        {:error, {:bad_request, "peer is required"}}

      kind == "group" and not String.starts_with?(peer, "group:") ->
        {:error, {:bad_request, "a group peer starts with group:"}}

      kind == "user" and String.starts_with?(peer, "group:") ->
        {:error, {:bad_request, "a user peer is an ACI"}}

      true ->
        {:ok, kind, peer, if(name in [nil, ""], do: nil, else: name)}
    end
  end

  defp validate_peer(_peer), do: {:error, {:bad_request, "invalid peer"}}

  # A released reservation is a tombstone (`ProviderIdentity.release_provider/3`)
  # and reads as free.
  defp read_reservation(identity) do
    case CasRecord.get(Keys.ctl_im_provider_identity(@provider, identity)) do
      {:ok, %{"released_at" => released}} when not is_nil(released) -> {:error, :not_found}
      other -> other
    end
  end

  defp coordinates(identity, reservation) do
    case ProviderIdentity.authority_coordinates(@provider, identity, reservation) do
      {:ok, group_id, connect_id} -> {:ok, group_id, connect_id}
      _ -> {:error, :not_found}
    end
  end

  defp live_record(group_id, connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, rec} ->
        if signal_record?(rec, group_id, connect_id) and routable?(rec),
          do: {:ok, rec},
          else: {:error, :not_found}

      other ->
        other
    end
  end

  defp owned_record(tenant_id, group_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, current} <- current_record(group_id),
         true <- current["tenant_id"] == tenant_id do
      {:ok, current}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp routable?(rec),
    do: is_nil(rec["deleted_at"]) and is_nil(rec["disabled_at"]) and rec["status"] == "connected"

  defp update_live(group_id, connect_id, fun) do
    CasRecord.update(
      Keys.ctl_im_connect(group_id, connect_id),
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

  defp signal_record?(rec, group_id, connect_id) do
    rec["provider"] == @provider and rec["group_id"] == group_id and
      rec["connect_id"] == connect_id
  end

  defp bindings(rec),
    do: rec |> Map.get("signal_bindings", []) |> List.wrap() |> Enum.filter(&is_map/1)

  defp claims(rec),
    do: rec |> Map.get("signal_claims", []) |> List.wrap() |> Enum.filter(&is_map/1)

  defp same_peer?(entry, account_id, peer),
    do: entry["account_id"] == account_id and entry["peer"] == peer

  defp past_grace?(reservation),
    do: now() - integer(reservation["updated_at"] || reservation["created_at"]) > @stale_grace_ms

  defp require_present("", field), do: {:error, {:bad_request, "#{field} is required"}}
  defp require_present(_value, _field), do: :ok

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp now, do: System.system_time(:millisecond)
end
