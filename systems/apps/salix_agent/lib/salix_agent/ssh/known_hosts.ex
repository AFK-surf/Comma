defmodule SalixAgent.SSH.KnownHosts do
  @moduledoc """
  The Group's trust-on-first-use SSH host key database.

  One JSON record per Group at `SalixStore.Keys.ctl_group_ssh_known_hosts/1`,
  changed only by compare-and-swap (`SalixStore.CasRecord`). Entries are keyed
  like OpenSSH `known_hosts` names: the normalized host as the Agent typed it
  (`host` for port 22, `[host]:port` otherwise), never the resolved address.

  `check/5` runs during key exchange, before user authentication:

    * no entry → record the presented key; accept only after the write is
      durable. Two first connections that race converge on the first write,
      and a connection that presented a different key is rejected.
    * matching entry → accept.
    * different key → reject with both fingerprints.
    * store unavailable → reject (fail closed).

  Each host keeps one key. The connection pins the host key algorithm to the
  stored key type (`pinned_algorithms/1`), so a server offering several key
  types cannot cause a false mismatch. `remove/3` deletes an entry so the next
  connection trusts the host again.
  """

  alias SalixStore.{CasRecord, Keys}

  @max_hosts 512

  @type entry :: %{String.t() => term()}

  @doc "The known_hosts name for a host and port."
  @spec name(String.t(), pos_integer()) :: String.t()
  def name(host, 22), do: normalize_host(host)
  def name(host, port), do: "[#{normalize_host(host)}]:#{port}"

  @doc "Lower-case, trailing-dot-free host; IP literals in canonical form."
  @spec normalize_host(String.t()) :: String.t()
  def normalize_host(host) do
    host = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> to_string(:inet.ntoa(address))
      {:error, _} -> host
    end
  end

  @doc "All entries, sorted by name."
  @spec list(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(group_id) do
    with {:ok, record} <- read(group_id) do
      {:ok, record |> hosts() |> Map.values() |> Enum.sort_by(& &1["name"])}
    end
  end

  @doc "The stored entry for a host, if any."
  @spec get(String.t(), String.t(), pos_integer()) :: {:ok, entry() | nil} | {:error, term()}
  def get(group_id, host, port) do
    with {:ok, record} <- read(group_id), do: {:ok, Map.get(hosts(record), name(host, port))}
  end

  @doc """
  Check a presented host key, trusting it on first use.

  Returns `{:ok, :known | :trusted_on_first_use, entry}` or
  `{:error, {:host_key_mismatch, stored_entry, presented}}` or another
  `{:error, reason}`; `presented` carries the key type and fingerprint.
  """
  @spec check(String.t(), String.t(), pos_integer(), tuple(), String.t() | nil) ::
          {:ok, :known | :trusted_on_first_use, entry()} | {:error, term()}
  def check(group_id, host, port, key, agent_id) do
    name = name(host, port)
    presented = describe(key)

    with {:ok, record} <- read(group_id) do
      case Map.get(hosts(record), name) do
        nil -> trust(group_id, name, host, port, presented, agent_id)
        stored -> compare(stored, presented, :known)
      end
    end
  end

  @doc "Remove the entry for a host. Returns the removed entry, or nil."
  @spec remove(String.t(), String.t(), pos_integer()) :: {:ok, entry() | nil} | {:error, term()}
  def remove(group_id, host, port) do
    name = name(host, port)
    key = Keys.ctl_group_ssh_known_hosts(group_id)

    with {:ok, current} <- read(group_id) do
      case Map.get(hosts(current), name) do
        nil ->
          {:ok, nil}

        _entry ->
          result =
            CasRecord.update(
              key,
              fn
                nil -> {:unchanged, empty()}
                record -> Map.put(record, "hosts", Map.delete(hosts(record), name))
              end,
              create: false
            )

          case result do
            {:ok, _} -> {:ok, Map.get(hosts(current), name)}
            {:error, :not_found} -> {:ok, nil}
            {:error, reason} -> {:error, {:known_hosts_unavailable, reason}}
          end
      end
    end
  end

  @doc """
  Host key algorithms a connection to this entry may negotiate: only the
  stored key's type. `nil` for an unknown host (OTP defaults apply).
  """
  @spec pinned_algorithms(entry() | nil) :: [atom()] | nil
  def pinned_algorithms(nil), do: nil
  def pinned_algorithms(%{"key_type" => "ssh-rsa"}), do: [:"rsa-sha2-512", :"rsa-sha2-256"]

  def pinned_algorithms(%{"key_type" => type}) when is_binary(type) do
    [String.to_existing_atom(type)]
  rescue
    ArgumentError -> nil
  end

  def pinned_algorithms(_entry), do: nil

  @doc "Key type, base64 blob and fingerprint of a public key."
  @spec describe(tuple()) :: %{String.t() => String.t()}
  def describe(key) do
    [type, blob | _] =
      [{key, []}] |> :ssh_file.encode(:openssh_key) |> String.trim() |> String.split(" ")

    %{
      "key_type" => type,
      "public_key" => blob,
      "fingerprint" => SalixAgent.SSH.Identity.fingerprint(key)
    }
  end

  defp trust(group_id, name, host, port, presented, agent_id) do
    entry =
      presented
      |> Map.merge(%{
        "name" => name,
        "host" => normalize_host(host),
        "port" => port,
        "first_seen_at" =>
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        "first_seen_by_agent_id" => agent_id
      })

    result =
      CasRecord.update(Keys.ctl_group_ssh_known_hosts(group_id), fn current ->
        record = current || empty()
        hosts = hosts(record)

        cond do
          Map.has_key?(hosts, name) -> {:unchanged, record}
          map_size(hosts) >= @max_hosts -> {:error, :known_hosts_full}
          true -> Map.put(record, "hosts", Map.put(hosts, name, entry))
        end
      end)

    case result do
      {:ok, record} ->
        case Map.get(hosts(record), name) do
          ^entry -> {:ok, :trusted_on_first_use, entry}
          stored when is_map(stored) -> compare(stored, presented, :known)
          nil -> {:error, {:known_hosts_unavailable, :entry_missing}}
        end

      {:error, :known_hosts_full} ->
        {:error, {:known_hosts_full, @max_hosts}}

      {:error, reason} ->
        {:error, {:known_hosts_unavailable, reason}}
    end
  end

  defp compare(stored, presented, status) do
    if stored["key_type"] == presented["key_type"] and
         stored["public_key"] == presented["public_key"],
       do: {:ok, status, stored},
       else: {:error, {:host_key_mismatch, stored, presented}}
  end

  defp read(group_id) do
    case CasRecord.get(Keys.ctl_group_ssh_known_hosts(group_id)) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:ok, empty()}
      {:error, reason} -> {:error, {:known_hosts_unavailable, reason}}
    end
  end

  defp empty, do: %{"version" => 1, "hosts" => %{}}

  defp hosts(%{"hosts" => hosts}) when is_map(hosts), do: hosts
  defp hosts(_record), do: %{}
end
