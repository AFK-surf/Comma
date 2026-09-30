defmodule SalixAnalytics.EventArchive.Recipients do
  @moduledoc """
  The configured archive recipients: `age1…` public keys and nothing else.

  No private key is ever configured, read, or derivable here — that is the
  whole property the archive rests on. `SalixStore.Age.decrypt/2` exists for
  tooling and tests, but a running node has no identity to hand it.

  Keys are parsed ONCE at load and cached in `:persistent_term`: per-item
  Bech32 decoding would be pure waste on a path that runs at loop frequency.

  ## One bad key does not disable the archive

  A malformed entry used to reject the WHOLE list, so a typo in the second of
  three recipients archived nothing at all — and the node booted healthy,
  because the boot check only logs. The trade there is lopsided: rejecting the
  bad key costs one key-holder the ability to read these events, while
  rejecting the list costs everyone every event, permanently, with no record
  that they existed.

  So a partial parse archives to the usable recipients and keeps the rejects in
  `problems/0`, where `verify_at_boot/0` logs them and
  `SalixAnalytics.event_archive_ready?/0` reports them. Only a config where NO
  recipient parses is a disabled archive, and that one is not cached, so fixing
  the config takes effect without a restart.
  """

  require Logger

  alias SalixStore.Age

  @cache_key {__MODULE__, :recipients}
  @problems_key {__MODULE__, :problems}

  @type recipient :: %{key_id: String.t(), key: binary()}
  @type problem :: {String.t() | nil, term()}

  @doc """
  Load and validate recipients from application config, caching the result.

  Returns `{:ok, []}` when the archive is not configured, which is the
  disabled state — callers treat an empty list as "do not archive".

  Returns `{:ok, usable}` when SOME entries parse, with the rejects available
  from `problems/0`. Returns `{:error, reason}` only when the archive is
  configured and nothing in it is usable.
  """
  @spec load() :: {:ok, [recipient()]} | {:error, term()}
  def load do
    case :persistent_term.get(@cache_key, :miss) do
      :miss -> parse_and_cache(Application.get_env(:salix_analytics, :event_archive, []))
      cached -> {:ok, cached}
    end
  end

  @doc """
  Recipients the last load REJECTED, as `{key_id, reason}`.

  Non-empty means the archive is running with fewer recipients than configured:
  every item written since is unreadable by whoever holds the rejected key.
  """
  @spec problems() :: [problem()]
  def problems, do: :persistent_term.get(@problems_key, [])

  @doc "Recipients, or `[]` if unconfigured or invalid. Never raises."
  @spec get() :: [recipient()]
  def get do
    case load() do
      {:ok, recipients} -> recipients
      {:error, _} -> []
    end
  end

  @doc "Drop the cache. Tests and config reloads only."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@cache_key)
    _ = :persistent_term.erase(@problems_key)
    :ok
  end

  @doc """
  Validate configured recipients and log their fingerprints.

  Called at boot. Public keys are not secret, but they ARE integrity-critical:
  an attacker who swaps one redirects the whole archive to themselves and
  nothing downstream looks wrong. Logging `key_id` with a digest of each key
  makes such a swap visible in the log record.
  """
  @spec verify_at_boot() :: :ok | {:error, term()}
  def verify_at_boot do
    case load() do
      {:ok, []} ->
        Logger.info("event archive disabled: no recipients configured")
        :ok

      {:ok, recipients} ->
        Enum.each(recipients, fn %{key_id: key_id, key: key} ->
          Logger.info("event archive recipient key_id=#{key_id} sha256=#{fingerprint(key)}")
        end)

        case problems() do
          [] ->
            :ok

          rejected ->
            # Not fatal — the archive is running — but every item written from
            # here on is unreadable by the holders of these keys, and that is
            # not something to discover at the point someone needs to read one.
            Logger.error(
              "event archive running with #{length(rejected)} REJECTED recipient(s); " <>
                "items archived now cannot be opened with those keys: #{inspect(rejected)}"
            )

            {:error, {:recipients_rejected, rejected}}
        end

      {:error, reason} = error ->
        Logger.error("event archive recipients invalid: #{inspect(reason)}")
        error
    end
  end

  @doc "Short SHA-256 fingerprint of a raw public key, for logs and diagnostics."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp parse_and_cache(config) do
    enabled? = Keyword.get(config, :enabled, false)
    configured = Keyword.get(config, :recipients, [])

    cond do
      not enabled? or configured == [] ->
        :persistent_term.put(@cache_key, [])
        :persistent_term.put(@problems_key, [])
        {:ok, []}

      true ->
        {usable, rejected} = parse_all(configured)
        :persistent_term.put(@problems_key, rejected)
        announce(rejected)

        if usable == [] do
          # Deliberately NOT cached: a fixed config should take effect on the
          # next call without a restart, and caching [] here would silently
          # disable archiving for the life of the node.
          {:error, {:no_usable_recipients, rejected}}
        else
          :persistent_term.put(@cache_key, usable)
          {:ok, usable}
        end
    end
  end

  defp announce([]), do: :ok

  defp announce(rejected) do
    :telemetry.execute(
      [:salix_analytics, :event_archive, :recipient_rejected],
      %{count: length(rejected)},
      %{key_ids: Enum.map(rejected, &elem(&1, 0))}
    )

    :ok
  rescue
    _exception -> :ok
  end

  # Splits rather than halting. A rejected entry costs its key-holder these
  # events; rejecting the list costs everyone every event.
  defp parse_all(configured) do
    {usable, rejected} =
      Enum.reduce(configured, {[], []}, fn entry, {usable, rejected} ->
        case parse_one(entry) do
          {:ok, recipient} -> {[recipient | usable], rejected}
          {:error, problem} -> {usable, [problem | rejected]}
        end
      end)

    {Enum.reverse(usable), Enum.reverse(rejected)}
  end

  defp parse_one(entry) do
    key_id = value(entry, :key_id)
    public = value(entry, :public_key)

    cond do
      is_nil(key_id) or key_id == "" ->
        {:error, {nil, :missing_key_id}}

      is_nil(public) or public == "" ->
        {:error, {to_string(key_id), :missing_public_key}}

      true ->
        case Age.parse_recipient(public) do
          {:ok, key} -> {:ok, %{key_id: to_string(key_id), key: key}}
          {:error, reason} -> {:error, {to_string(key_id), {:invalid_public_key, reason}}}
        end
    end
  end

  defp value(entry, key) when is_map(entry), do: entry[key] || entry[to_string(key)]
  defp value(entry, key) when is_list(entry), do: Keyword.get(entry, key)
  defp value(_entry, _key), do: nil
end
