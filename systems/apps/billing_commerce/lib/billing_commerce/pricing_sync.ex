defmodule BillingCommerce.PricingSync do
  @moduledoc """
  Converges a desired product catalog into local immutable package versions.

  Provider network sync is intentionally outside this module; BillingCommerce
  owns the local catalog facts and provider adapters bind external ids later.
  """

  alias BillingCommerce.PackageCatalog

  @spec sync_local_catalog(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_local_catalog(catalog, opts \\ []) when is_map(catalog) do
    attrs = Map.new(opts)

    with {:ok, packages} <- sync_packages(catalog[:packages] || catalog["packages"] || [], attrs),
         {:ok, versions} <- sync_versions(catalog[:versions] || catalog["versions"] || [], attrs) do
      {:ok,
       %{
         catalog: catalog[:name] || catalog["name"],
         packages: packages,
         versions: versions
       }}
    end
  end

  @spec catalog_current?(map(), keyword()) :: boolean()
  def catalog_current?(catalog, opts \\ []) when is_map(catalog) do
    attrs = Map.new(opts)

    Enum.all?(catalog[:versions] || catalog["versions"] || [], fn expected ->
      query = %{
        repo: attrs[:repo],
        package_code: expected[:package_code] || expected["package_code"],
        version: expected[:version] || expected["version"]
      }

      case PackageCatalog.get_package_version(query) do
        {:ok, actual} -> PackageCatalog.version_terms_match?(actual, expected)
        {:error, :not_found} -> false
      end
    end)
  rescue
    _error -> false
  end

  defp sync_packages(packages, attrs) do
    reduce(packages, fn package ->
      package
      |> Map.merge(attrs)
      |> PackageCatalog.create_package()
    end)
  end

  defp sync_versions(versions, attrs) do
    reduce(versions, fn version ->
      version
      |> Map.merge(attrs)
      |> PackageCatalog.create_package_version()
    end)
  end

  defp reduce(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end
end
