defmodule SalixStore.BrowserStorage do
  @moduledoc "Encrypted website storage owned by a Group. Active browsers retain Runtime Session ownership."
  import Ecto.Query
  alias SalixStore.{Repo, Crypto, BrowserBindings}
  @max_bytes 1_048_576

  defmodule Row do
    use Ecto.Schema
    @primary_key false
    schema "group_browser_storage" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:ciphertext, :string, redact: true)
      field(:saved_at, :utc_datetime_usec)
      field(:deleted, :boolean, default: false)
    end
  end

  def empty, do: %{"cookies" => [], "origins" => %{}}

  def query(owner),
    do: from(r in Row, where: r.tenant_id == ^owner.tenant_id and r.group_id == ^owner.group_id)

  # Call inside the binding transaction. This lock serializes Group admission
  # and deletion even before the Group's first storage row exists.
  def lock!(owner) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["browser_group:" <> owner.tenant_id <> ":" <> owner.group_id],
      log: false
    )
  end

  def admit!(owner) do
    lock!(owner)

    case Repo.one(query(owner), log: false) do
      %Row{deleted: true} -> Repo.rollback(:browser_group_deleted)
      nil -> Repo.insert!(struct(Row, Map.take(owner, [:tenant_id, :group_id])), log: false)
      _ -> :ok
    end

    if active?(owner), do: Repo.rollback(:browser_shared_profile_in_use)
  end

  defp active?(owner) do
    Repo.exists?(
      from(r in BrowserBindings.Row,
        where:
          r.tenant_id == ^owner.tenant_id and r.group_id == ^owner.group_id and
            r.status != "closed"
      ),
      log: false
    )
  end

  def load(owner) do
    case Repo.one(query(owner), log: false) do
      %Row{deleted: true} -> {:error, :browser_group_deleted}
      %Row{ciphertext: cipher} when is_binary(cipher) -> decrypt(owner, cipher)
      _ -> {:ok, empty()}
    end
  rescue
    _ -> {:error, :browser_storage_unavailable}
  end

  def saved_at(owner), do: Repo.one(from(r in query(owner), select: r.saved_at), log: false)

  def save(row, patch, saved_at) do
    Repo.transaction(fn ->
      current = Repo.one(from(r in BrowserBindings.query(row), lock: "FOR UPDATE"), log: false)

      unless not is_nil(current) and current.pending == row.pending and
               current.updated_at == row.updated_at and
               current.provider_id == row.provider_id and is_binary(current.provider_id) and
               current.status == "ready" and current.options["shared_storage"] == true,
             do: Repo.rollback(:browser_operation_superseded)

      # Two exporters can overlap after a distribution failure. The SQL save
      # time rejects an older snapshot after another exporter commits.
      if saved_at(row) != saved_at, do: Repo.rollback(:browser_operation_superseded)

      snapshot =
        case load(row) do
          {:ok, previous} ->
            merge_and_evict(previous, patch)

          {:error, reason} ->
            Repo.rollback(reason)
        end

      cipher =
        case encrypt(row, snapshot) do
          {:ok, cipher} -> cipher
          {:error, reason} -> Repo.rollback(reason)
        end

      case Repo.update_all(
             from(r in query(row), where: not r.deleted),
             [set: [ciphertext: cipher, saved_at: DateTime.utc_now()]],
             log: false
           ) do
        {1, _} -> :saved
        _ -> Repo.rollback(:browser_storage_unavailable)
      end
    end)
  rescue
    _ -> {:error, :browser_storage_unavailable}
  end

  def checkpoint_result(row, error) do
    Repo.update_all(
      from(r in BrowserBindings.query(row),
        where:
          r.provider_id == ^row.provider_id and r.updated_at == ^row.updated_at and
            is_nil(r.pending) and r.status == "ready"
      ),
      [set: [storage_error: error]],
      log: false
    )
  end

  def clear_idle(owner) do
    Repo.transaction(fn ->
      lock!(owner)
      if active?(owner), do: Repo.rollback(:browser_shared_profile_in_use)
      clear!(owner)
      :ok
    end)
  end

  # The caller holds binding admission until provider deletion is confirmed.
  def clear!(owner),
    do: Repo.update_all(query(owner), [set: [ciphertext: nil, saved_at: nil]], log: false)

  def delete_group(tenant_id, group_id, delete \\ fn -> :ok end) do
    Repo.transaction(fn ->
      owner = %{tenant_id: tenant_id, group_id: group_id}
      lock!(owner)
      if active?(owner), do: Repo.rollback(:browser_shared_profile_in_use)

      case delete.() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      Repo.insert!(%Row{tenant_id: tenant_id, group_id: group_id, deleted: true},
        on_conflict: {:replace, [:ciphertext, :saved_at, :deleted]},
        conflict_target: [:tenant_id, :group_id],
        log: false
      )

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  # CDP does not expose cookie access times. Website visits and changed cookie
  # values refresh recency. Export and restore alone do not refresh origin use.
  defp merge_and_evict(previous, patch) do
    origins =
      Map.merge(previous["origins"], patch["origins"])
      |> Map.reject(fn {_, entries} -> entries == [] end)

    old_used = previous["last_used"] || %{}
    access = patch["access"] || %{}
    now = System.system_time(:microsecond)
    prior_cookies = Map.new(previous["cookies"], &{cookie_key(&1), &1})
    cookies = Map.new(patch["cookies"], &{cookie_key(&1), &1})
    hosts = Enum.map(access, fn {origin, used} -> {URI.parse(origin).host, used} end)

    used =
      Map.new(origins, fn {origin, _} ->
        key = "origin:" <> origin
        {key, access[origin] || old_used[key] || now}
      end)

    used =
      Enum.reduce(cookies, used, fn {key, cookie}, acc ->
        domain = String.trim_leading(cookie["domain"] || "", ".")

        visited =
          Enum.reduce(hosts, 0, fn {host, time}, latest ->
            if is_binary(host) and (host == domain or String.ends_with?(host, "." <> domain)),
              do: max(time, latest),
              else: latest
          end)

        changed =
          get_in(patch, ["cookie_access", key]) ||
            if(prior_cookies[key] == cookie, do: old_used[key] || 0, else: now)

        Map.put(acc, key, max(visited, changed))
      end)

    snapshot = %{"cookies" => Map.values(cookies), "origins" => origins, "last_used" => used}
    bytes = byte_size(Jason.encode!(snapshot))
    entries = Enum.sort_by(used, fn {key, time} -> {time, key} end)

    {cookies, origins, used, _} =
      Enum.reduce_while(entries, {cookies, origins, used, bytes}, fn {key, time},
                                                                     {cookies, origins, used,
                                                                      bytes} ->
        if bytes <= @max_bytes do
          {:halt, {cookies, origins, used, bytes}}
        else
          metadata_bytes = member_bytes(key, time, map_size(used))

          {cookies, origins, removed} =
            case key do
              "origin:" <> origin ->
                removed = member_bytes(origin, origins[origin], map_size(origins))
                {cookies, Map.delete(origins, origin), removed}

              _ ->
                removed =
                  byte_size(Jason.encode!(cookies[key])) +
                    if(map_size(cookies) > 1, do: 1, else: 0)

                {Map.delete(cookies, key), origins, removed}
            end

          {:cont, {cookies, origins, Map.delete(used, key), bytes - metadata_bytes - removed}}
        end
      end)

    %{"cookies" => Map.values(cookies), "origins" => origins, "last_used" => used}
  end

  defp member_bytes(key, value, count),
    do:
      byte_size(Jason.encode!(key)) + 1 + byte_size(Jason.encode!(value)) +
        if(count > 1, do: 1, else: 0)

  def cookie_key(cookie),
    do: "cookie:" <> Jason.encode!(Map.take(cookie, ~w(name domain path partitionKey)))

  defp aad(owner), do: Jason.encode!([owner.tenant_id, owner.group_id])

  # The deployment root protects a stolen database and AEAD binds ciphertext
  # to its Group. Application compromise is outside this boundary.
  defp encrypt(owner, %{"cookies" => cookies, "origins" => origins} = snapshot)
       when is_list(cookies) and is_map(origins) do
    encoded = Jason.encode!(snapshot)

    if byte_size(encoded) <= @max_bytes do
      with {:ok, key} <- Crypto.derived_key("browser-group-storage-v1") do
        iv = :crypto.strong_rand_bytes(12)

        {cipher, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, encoded, aad(owner), true)

        {:ok, Base.encode64(iv <> tag <> cipher)}
      end
    else
      {:error, :browser_storage_limit}
    end
  end

  defp encrypt(_, _), do: {:error, :browser_storage_invalid}

  defp decrypt(owner, encoded) do
    with {:ok, key} <- Crypto.derived_key("browser-group-storage-v1"),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           Base.decode64(encoded),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, aad(owner), tag, false),
         {:ok, %{"cookies" => _, "origins" => _} = snapshot} <- Jason.decode(plain) do
      {:ok, snapshot}
    else
      _ -> {:error, :browser_storage_unavailable}
    end
  end
end
