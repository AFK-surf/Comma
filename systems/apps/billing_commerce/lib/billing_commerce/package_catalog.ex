defmodule BillingCommerce.PackageCatalog do
  @moduledoc "Immutable package version catalog commands."

  @spec create_package(map()) :: {:ok, map()} | {:error, term()}
  def create_package(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    code = required(attrs, :code)
    surface = required(attrs, :surface)
    name = attrs[:name] || attrs["name"] || code
    status = attrs[:status] || attrs["status"] || "active"
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    sql.query!(
      repo,
      """
      INSERT INTO billing_packages (
        code, surface, name, status, metadata, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, now(), now())
      ON CONFLICT (code) DO UPDATE
      SET name = EXCLUDED.name,
          status = EXCLUDED.status,
          metadata = EXCLUDED.metadata,
          updated_at = now()
      """,
      [code, surface, name, status, metadata]
    )

    get_package(Map.put(attrs, :code, code))
  end

  @spec create_package_version(map()) :: {:ok, map()} | {:error, term()}
  def create_package_version(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    terms = version_terms(attrs)

    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_package_versions (
          id, package_code, version, surface, kind, billing_period,
          grant_credits, grant_period, currency, amount_minor, usage_policy,
          effective_at, expires_at, status, inserted_at
        ) VALUES (
          $1, $2, $3, $4, $5, $6,
          $7, $8, $9, $10, $11,
          $12, $13, $14, now()
        )
        ON CONFLICT (package_code, version) DO NOTHING
        RETURNING id, package_code, version, surface, kind, billing_period,
          grant_credits, grant_period, currency, amount_minor, usage_policy,
          effective_at, expires_at, status
        """,
        [
          attrs[:id] || id("pkgver"),
          terms.package_code,
          terms.version,
          terms.surface,
          terms.kind,
          terms.billing_period,
          terms.grant_credits,
          terms.grant_period,
          terms.currency,
          terms.amount_minor,
          terms.usage_policy,
          terms.effective_at,
          terms.expires_at,
          terms.status
        ]
      )

    case result.rows do
      [row | _] ->
        {:ok, row_to_version(row) |> Map.put(:idempotent, false)}

      [] ->
        case get_package_version(%{
               repo: repo,
               sql_runner: sql,
               package_code: terms.package_code,
               version: terms.version
             }) do
          {:ok, existing} ->
            if immutable_match?(existing, terms) do
              {:ok, Map.put(existing, :idempotent, true)}
            else
              {:error, :package_version_immutable}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @spec get_package_version(map()) :: {:ok, map()} | {:error, :not_found}
  def get_package_version(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    package_code = attrs[:package_code] || attrs["package_code"] || attrs[:code] || attrs["code"]
    version = required(attrs, :version)

    result =
      sql.query!(
        repo,
        """
        SELECT id, package_code, version, surface, kind, billing_period,
          grant_credits, grant_period, currency, amount_minor, usage_policy,
          effective_at, expires_at, status
        FROM billing_package_versions
        WHERE package_code = $1 AND version = $2
        LIMIT 1
        """,
        [package_code, version]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_version(row)}
      [] -> {:error, :not_found}
    end
  end

  @spec list_package_versions(map()) :: {:ok, %{data: [map()]}} | {:error, term()}
  def list_package_versions(attrs \\ %{}) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    surface = attrs[:surface] || attrs["surface"]
    issuable_only? = Map.get(attrs, :issuable_only?, Map.get(attrs, "issuable_only?", false))

    latest_per_package? =
      Map.get(attrs, :latest_per_package?, Map.get(attrs, "latest_per_package?", false))

    at = attrs[:at] || attrs["at"] || DateTime.utc_now()

    {surface_where, surface_params} =
      if is_binary(surface) and String.trim(surface) != "" do
        {"AND v.surface = $2", [surface]}
      else
        {"", []}
      end

    issuable_where =
      if issuable_only? do
        """
        AND v.status = 'active'
        AND v.effective_at <= $1
        AND (v.expires_at IS NULL OR v.expires_at > $1)
        """
      else
        ""
      end

    distinct =
      if latest_per_package? do
        "DISTINCT ON (v.package_code)"
      else
        ""
      end

    order_by =
      if latest_per_package? do
        "v.package_code ASC, v.effective_at DESC, v.version DESC"
      else
        "v.package_code ASC, v.effective_at DESC, v.version DESC"
      end

    result =
      sql.query!(
        repo,
        """
        SELECT #{distinct}
          v.id, v.package_code, v.version, v.surface, v.kind, v.billing_period,
          v.grant_credits, v.grant_period, v.currency, v.amount_minor, v.usage_policy,
          v.effective_at, v.expires_at, v.status,
          p.name, p.status
        FROM billing_package_versions v
        JOIN billing_packages p ON p.code = v.package_code
        WHERE ($1::timestamptz IS NOT NULL OR TRUE)
          AND p.status = 'active'
          #{surface_where}
          #{issuable_where}
        ORDER BY #{order_by}
        """,
        [at | surface_params]
      )

    {:ok, %{data: Enum.map(result.rows, &row_to_listed_version/1)}}
  rescue
    error -> {:error, error}
  end

  def package_snapshot(version) when is_map(version) do
    %{
      "package_code" => version.package_code,
      "package_version" => version.version,
      "surface" => version.surface,
      "kind" => version.kind,
      "billing_period" => version.billing_period,
      "grant_credits" => version.grant_credits,
      "grant_period" => version.grant_period,
      "currency" => version.currency,
      "amount_minor" => version.amount_minor,
      "usage_policy" => version.usage_policy
    }
  end

  def ensure_issuable(%{} = version, %DateTime{} = at) do
    cond do
      version.status != "active" ->
        {:error, :package_version_inactive}

      DateTime.compare(version.effective_at, at) == :gt ->
        {:error, :package_version_not_yet_effective}

      match?(%DateTime{}, version.expires_at) and DateTime.compare(version.expires_at, at) != :gt ->
        {:error, :package_version_expired}

      true ->
        :ok
    end
  end

  defp get_package(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    code = required(attrs, :code)

    result =
      sql.query!(
        repo,
        """
        SELECT code, surface, name, status, metadata
        FROM billing_packages
        WHERE code = $1
        LIMIT 1
        """,
        [code]
      )

    case result.rows do
      [[code, surface, name, status, metadata] | _] ->
        {:ok,
         %{
           code: code,
           surface: surface,
           name: name,
           status: status,
           metadata: decode_json(metadata)
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp version_terms(attrs) do
    %{
      package_code: required(attrs, :package_code),
      version: required(attrs, :version),
      surface: required(attrs, :surface),
      kind: required(attrs, :kind),
      billing_period: required(attrs, :billing_period),
      grant_credits: required(attrs, :grant_credits),
      grant_period: required(attrs, :grant_period),
      currency: required(attrs, :currency),
      amount_minor: required(attrs, :amount_minor),
      usage_policy: attrs[:usage_policy] || attrs["usage_policy"] || %{},
      effective_at: required(attrs, :effective_at),
      expires_at: attrs[:expires_at] || attrs["expires_at"],
      status: attrs[:status] || attrs["status"] || "active"
    }
  end

  @doc "Compare persisted commercial terms with a desired catalog version."
  def version_terms_match?(existing, attrs), do: immutable_match?(existing, version_terms(attrs))

  defp immutable_match?(existing, terms) do
    Enum.all?(
      [
        :surface,
        :kind,
        :billing_period,
        :grant_credits,
        :grant_period,
        :currency,
        :amount_minor,
        :usage_policy,
        :effective_at,
        :expires_at,
        :status
      ],
      fn
        :usage_policy ->
          same_term?(
            commercial_policy(existing.usage_policy),
            commercial_policy(terms.usage_policy)
          )

        key ->
          same_term?(Map.fetch!(existing, key), Map.fetch!(terms, key))
      end
    )
  end

  # Provider lookup keys and display descriptions are not immutable commercial terms.
  defp commercial_policy(policy), do: Map.drop(policy, ["stripe_lookup_key", "description"])

  defp same_term?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_term?(left, right), do: left == right

  defp row_to_version([
         id,
         package_code,
         version,
         surface,
         kind,
         billing_period,
         grant_credits,
         grant_period,
         currency,
         amount_minor,
         usage_policy,
         effective_at,
         expires_at,
         status
       ]) do
    %{
      id: id,
      package_code: package_code,
      version: version,
      surface: surface,
      kind: kind,
      billing_period: billing_period,
      grant_credits: grant_credits,
      grant_period: grant_period,
      currency: currency,
      amount_minor: amount_minor,
      usage_policy: decode_json(usage_policy),
      effective_at: effective_at,
      expires_at: expires_at,
      status: status
    }
  end

  defp row_to_listed_version(row) do
    [
      id,
      package_code,
      version,
      surface,
      kind,
      billing_period,
      grant_credits,
      grant_period,
      currency,
      amount_minor,
      usage_policy,
      effective_at,
      expires_at,
      status,
      package_name,
      package_status
    ] = row

    row_to_version([
      id,
      package_code,
      version,
      surface,
      kind,
      billing_period,
      grant_credits,
      grant_period,
      currency,
      amount_minor,
      usage_policy,
      effective_at,
      expires_at,
      status
    ])
    |> Map.put(:package_name, package_name)
    |> Map.put(:package_status, package_status)
  end

  defp repo(attrs),
    do: attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(attrs), do: attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] || raise ArgumentError, "missing package field #{key}"
  end

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
