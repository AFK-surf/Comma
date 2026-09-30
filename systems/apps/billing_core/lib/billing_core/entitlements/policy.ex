defmodule BillingCore.Entitlements.Policy do
  @moduledoc "Normalizer for billing entitlement policy snapshots."

  @default %{
    "version" => 1,
    "usage_credits" => %{"mode" => "metered"},
    "llm_models" => %{"mode" => "unrestricted", "models" => []},
    "vm_concurrency" => %{"mode" => "unrestricted", "limit" => nil},
    "storage_hard_cap" => %{"mode" => "unrestricted", "bytes" => nil}
  }

  @spec default() :: map()
  def default, do: @default

  @spec normalize(map() | nil) :: {:ok, map()} | {:error, term()}
  def normalize(nil), do: {:ok, default()}
  def normalize(%{} = policy), do: normalize_policy(policy)
  def normalize(_policy), do: {:error, :invalid_policy}

  @spec normalize!(map() | nil) :: map()
  def normalize!(policy) do
    case normalize(policy) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid entitlement policy: #{inspect(reason)}"
    end
  end

  @spec merge_active([map()]) :: map()
  def merge_active(policies) when is_list(policies) do
    normalized =
      policies
      |> Enum.map(&normalize/1)
      |> Enum.flat_map(fn
        {:ok, policy} -> [policy]
        {:error, _reason} -> []
      end)

    usage_mode = active_usage_mode(normalized)

    default()
    |> Map.put("usage_credits", %{"mode" => Atom.to_string(usage_mode)})
    |> Map.put("llm_models", merge_llm_models(normalized))
    |> Map.put("vm_concurrency", merge_limit(normalized, "vm_concurrency", "limit"))
    |> Map.put("storage_hard_cap", merge_limit(normalized, "storage_hard_cap", "bytes"))
  end

  def merge_active(_policies), do: default()

  @spec active_usage_mode([atom() | String.t() | map()]) :: :metered | :unlimited_metered
  def active_usage_mode(values) when is_list(values) do
    if Enum.any?(values, &(usage_mode(&1) == :unlimited_metered)) do
      :unlimited_metered
    else
      :metered
    end
  end

  def active_usage_mode(_values), do: :metered

  @spec usage_mode(map() | atom() | String.t() | nil) :: :metered | :unlimited_metered
  def usage_mode(%{} = policy) do
    usage_credits = policy["usage_credits"] || policy[:usage_credits] || %{}

    case usage_credits["mode"] || usage_credits[:mode] || "metered" do
      "unlimited_metered" -> :unlimited_metered
      :unlimited_metered -> :unlimited_metered
      _ -> :metered
    end
  end

  def usage_mode("unlimited_metered"), do: :unlimited_metered
  def usage_mode(:unlimited_metered), do: :unlimited_metered
  def usage_mode(_value), do: :metered

  defp merge_llm_models([]), do: @default["llm_models"]

  defp merge_llm_models(policies) do
    llm_policies = Enum.map(policies, & &1["llm_models"])

    if Enum.any?(llm_policies, &(&1["mode"] == "unrestricted")) do
      @default["llm_models"]
    else
      models =
        llm_policies
        |> Enum.flat_map(&(&1["models"] || []))
        |> Enum.uniq()

      %{"mode" => "allowlist", "models" => models}
    end
  end

  defp merge_limit([], policy_key, _value_key), do: @default[policy_key]

  defp merge_limit(policies, policy_key, value_key) do
    limit_policies = Enum.map(policies, & &1[policy_key])

    if Enum.any?(limit_policies, &(&1["mode"] == "unrestricted")) do
      @default[policy_key]
    else
      value =
        limit_policies
        |> Enum.map(& &1[value_key])
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> 0 end)

      %{"mode" => "limit", value_key => value}
    end
  end

  defp normalize_policy(policy) do
    with {:ok, usage_credits} <-
           normalize_usage_credits(policy["usage_credits"] || policy[:usage_credits]),
         {:ok, llm_models} <- normalize_allowlist(policy["llm_models"] || policy[:llm_models]),
         {:ok, vm_concurrency} <-
           normalize_limit(policy["vm_concurrency"] || policy[:vm_concurrency], "limit"),
         {:ok, storage_hard_cap} <-
           normalize_limit(policy["storage_hard_cap"] || policy[:storage_hard_cap], "bytes") do
      {:ok,
       %{
         "version" => 1,
         "usage_credits" => usage_credits,
         "llm_models" => llm_models,
         "vm_concurrency" => vm_concurrency,
         "storage_hard_cap" => storage_hard_cap
       }}
    end
  end

  defp normalize_usage_credits(nil), do: {:ok, @default["usage_credits"]}

  defp normalize_usage_credits(%{} = attrs) do
    mode = to_string(attrs["mode"] || attrs[:mode] || "metered")

    case mode do
      "metered" -> {:ok, %{"mode" => "metered"}}
      "unlimited_metered" -> {:ok, %{"mode" => "unlimited_metered"}}
      _ -> {:error, {:invalid_usage_credits, attrs}}
    end
  end

  defp normalize_usage_credits(other), do: {:error, {:invalid_usage_credits, other}}

  defp normalize_allowlist(nil), do: {:ok, @default["llm_models"]}

  defp normalize_allowlist(%{} = attrs) do
    mode = to_string(attrs["mode"] || attrs[:mode] || "unrestricted")
    models = attrs["models"] || attrs[:models] || []

    cond do
      mode == "unrestricted" ->
        {:ok, @default["llm_models"]}

      mode == "allowlist" and is_list(models) and Enum.all?(models, &valid_string?/1) ->
        {:ok, %{"mode" => mode, "models" => Enum.uniq(models)}}

      true ->
        {:error, {:invalid_llm_models, attrs}}
    end
  end

  defp normalize_allowlist(other), do: {:error, {:invalid_llm_models, other}}

  defp normalize_limit(nil, key), do: {:ok, @default[limit_policy_key(key)]}

  defp normalize_limit(%{} = attrs, value_key) do
    mode = to_string(attrs["mode"] || attrs[:mode] || "unrestricted")
    value = attrs[value_key] || attrs[String.to_atom(value_key)]

    cond do
      mode == "unrestricted" ->
        {:ok, %{"mode" => "unrestricted", value_key => nil}}

      mode == "limit" and is_integer(value) and value >= 0 ->
        {:ok, %{"mode" => "limit", value_key => value}}

      true ->
        {:error, {:invalid_limit, value_key, attrs}}
    end
  end

  defp normalize_limit(other, key), do: {:error, {:invalid_limit, key, other}}

  defp limit_policy_key("limit"), do: "vm_concurrency"
  defp limit_policy_key("bytes"), do: "storage_hard_cap"

  defp valid_string?(value), do: is_binary(value) and String.trim(value) != ""
end
