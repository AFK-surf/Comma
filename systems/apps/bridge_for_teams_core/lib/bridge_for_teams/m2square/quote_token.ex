defmodule BridgeForTeams.M2square.QuoteToken do
  @moduledoc """
  Stateless HMAC-SHA256 signed 1-hour payment quote & seat-range window token.

  Reads its signing secret strictly from `:bridge_for_teams_core, :quote_signing_secret`
  (zero dependency on `BridgeForTeamsWeb`).
  """

  alias BridgeForTeams.M2square.{Config, Pricing}

  @token_version 1
  @ttl_seconds 3_600
  @min_secret_bytes 32
  @kdf_domain "bft.teams.quote_token.v1"

  @doc "Quote window lifetime in seconds (1 hour)."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Samples a single shared entry clock (`entry_now`) and monotonic FX deadline
  (`required_until_ms = now_ms + 3_600_000`) BEFORE reading any FX rate, loads
  available M2square countries against that shared deadline, and signs a 1-hour
  `QuoteToken` anchored at `entry_now`.

  Options:
    * `:min_m2_seats` — minimum payable M2square seats to lock into the snapshot
      (defaults to `Pricing.min_seats()` = 30; renewals pass `max(30, member_count, licensed_seats)`).
  """
  @spec prepare_payment_window(String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             token: String.t(),
             issued_at: integer(),
             expires_at: integer(),
             ttl_seconds: non_neg_integer(),
             countries: [map()],
             snapshot: map()
           }}
          | {:error, term()}
  def prepare_payment_window(scope, stripe_min_seats, opts \\ [])
      when is_binary(scope) and is_integer(stripe_min_seats) and stripe_min_seats >= 1 and
             is_list(opts) do
    entry_now = SystemsClock.utc_now()
    required_until_ms = SystemsClock.monotonic_time(:millisecond) + @ttl_seconds * 1_000
    countries = Config.available_countries(required_until_ms: required_until_ms)
    min_m2_seats = Keyword.get(opts, :min_m2_seats, Pricing.min_seats())

    effective_countries =
      Enum.flat_map(countries, fn c ->
        case Pricing.apply_min_seats_floor(c, min_m2_seats) do
          {:ok, updated} -> [updated]
          :ineligible -> []
        end
      end)

    with {:ok, issued} <- issue(scope, stripe_min_seats, effective_countries, entry_now) do
      remaining_ttl =
        max(0, issued.expires_at - DateTime.to_unix(SystemsClock.utc_now(), :second))

      {:ok,
       %{
         token: issued.token,
         issued_at: issued.issued_at,
         expires_at: issued.expires_at,
         ttl_seconds: remaining_ttl,
         countries: effective_countries,
         snapshot: issued.snapshot
       }}
    end
  end

  @doc """
  Issues a signed 1-hour quote token for `scope` (`"signup:<uuid>"` or `"renew:<org_id>"`).
  """
  @spec issue(String.t(), pos_integer(), [map()], DateTime.t()) ::
          {:ok,
           %{
             token: String.t(),
             issued_at: integer(),
             expires_at: integer(),
             ttl_seconds: pos_integer(),
             snapshot: map()
           }}
          | {:error, :quote_signing_unconfigured}
  def issue(scope, stripe_min_seats, countries, %DateTime{} = now \\ SystemsClock.utc_now())
      when is_binary(scope) and scope != "" and is_integer(stripe_min_seats) and
             stripe_min_seats >= 1 and is_list(countries) do
    with {:ok, key} <- signing_key() do
      issued_at = DateTime.to_unix(now, :second)
      expires_at = issued_at + @ttl_seconds

      countries_map =
        Enum.reduce(countries, %{}, fn c, acc ->
          code = c["code"]

          if is_binary(code) and code != "" do
            Map.put(acc, code, %{
              "currency" => c["currency"],
              "display_currency" => c["display_currency"],
              "scale" => c["scale"],
              "min_seats" => c["min_seats"],
              "max_seats" => c["max_seats"],
              "sample_min_amount" => c["sample_min_amount"],
              "fee_rate" => c["fee_rate"],
              "fx_rate" => c["fx_rate"],
              "fx_source" => c["fx_source"],
              "markup_rate" => c["markup_rate"],
              "payment_types" => c["payment_types"],
              "id_types" => c["id_types"]
            })
          else
            acc
          end
        end)

      snapshot = %{
        "v" => @token_version,
        "scope" => scope,
        "issued_at" => issued_at,
        "expires_at" => expires_at,
        "stripe_min_seats" => stripe_min_seats,
        "countries" => countries_map
      }

      encoded_payload = snapshot |> Jason.encode!() |> Base.url_encode64(padding: false)
      encoded_sig = sign_payload(key, encoded_payload)

      {:ok,
       %{
         token: encoded_payload <> "." <> encoded_sig,
         issued_at: issued_at,
         expires_at: expires_at,
         ttl_seconds: @ttl_seconds,
         snapshot: snapshot
       }}
    end
  end

  @doc """
  Verifies a signed quote token against `expected_scope` and `now`.

  Returns `{:ok, snapshot}` when valid and `now_unix < expires_at`,
  `{:error, :quote_expired}` when `now_unix >= expires_at`,
  `{:error, :quote_signing_unconfigured}` if the signing secret is missing,
  or `{:error, :invalid_quote_token}` for malformed, tampered, or wrong-scope tokens.
  """
  @spec verify(term(), term(), DateTime.t()) ::
          {:ok, map()}
          | {:error, :quote_expired | :invalid_quote_token | :quote_signing_unconfigured}
  def verify(token, expected_scope, now \\ SystemsClock.utc_now())

  def verify(token, expected_scope, %DateTime{} = now)
      when is_binary(token) and is_binary(expected_scope) and expected_scope != "" do
    with {:ok, key} <- signing_key(),
         [encoded_payload, encoded_sig] <- String.split(token, ".", parts: 2),
         true <- encoded_payload != "" and encoded_sig != "",
         expected_sig = sign_payload(key, encoded_payload),
         true <- Plug.Crypto.secure_compare(encoded_sig, expected_sig),
         {:ok, raw_json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, snapshot} <- Jason.decode(raw_json),
         :ok <- validate_snapshot(snapshot, expected_scope) do
      if unexpired?(snapshot, now) do
        {:ok, snapshot}
      else
        {:error, :quote_expired}
      end
    else
      {:error, :quote_signing_unconfigured} = err -> err
      _ -> {:error, :invalid_quote_token}
    end
  end

  def verify(_token, _expected_scope, _now), do: {:error, :invalid_quote_token}

  @doc "Returns `true` iff `snapshot` has not reached its `expires_at` unix second."
  @spec unexpired?(term(), DateTime.t()) :: boolean()
  def unexpired?(snapshot, now \\ SystemsClock.utc_now())

  def unexpired?(%{"expires_at" => expires_at}, %DateTime{} = now)
      when is_integer(expires_at) do
    DateTime.to_unix(now, :second) < expires_at
  end

  def unexpired?(_, _now), do: false

  @doc """
  Purely reconstructs the ordered country view list from a verified `snapshot`
  using `Config.country_order/0` and static `Config.catalog/0` metadata
  (`name_en`, `name_zh`), with zero live FX or S3 calls.
  """
  @spec countries_for_view(map()) :: [map()]
  def countries_for_view(%{"countries" => %{} = countries_map}) do
    catalog_by_code = Map.new(Config.catalog(), &{&1.code, &1})

    Enum.flat_map(Config.country_order(), fn code ->
      case {Map.fetch(countries_map, code), Map.fetch(catalog_by_code, code)} do
        {{:ok, %{} = snap}, {:ok, meta}} ->
          [
            snap
            |> Map.put("code", code)
            |> Map.put("name_en", meta.name_en)
            |> Map.put("name_zh", meta.name_zh)
          ]

        _ ->
          []
      end
    end)
  end

  def countries_for_view(_), do: []

  defp signing_key do
    case SystemsRuntime.get_env(:bridge_for_teams_core, :quote_signing_secret) do
      secret when is_binary(secret) and byte_size(secret) >= @min_secret_bytes ->
        {:ok, :crypto.mac(:hmac, :sha256, secret, @kdf_domain)}

      _ ->
        {:error, :quote_signing_unconfigured}
    end
  end

  defp sign_payload(key, encoded_payload) do
    :crypto.mac(:hmac, :sha256, key, encoded_payload)
    |> Base.url_encode64(padding: false)
  end

  defp validate_snapshot(
         %{
           "v" => @token_version,
           "scope" => scope,
           "issued_at" => issued_at,
           "expires_at" => expires_at,
           "stripe_min_seats" => stripe_min_seats,
           "countries" => %{} = _countries
         },
         expected_scope
       )
       when scope == expected_scope and is_integer(issued_at) and is_integer(expires_at) and
              expires_at > issued_at and is_integer(stripe_min_seats) and stripe_min_seats >= 1 do
    :ok
  end

  defp validate_snapshot(_, _), do: :error
end
