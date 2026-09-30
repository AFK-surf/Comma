defmodule Salix.Control.AndroidControl do
  @moduledoc """
  Fail-closed reader for the versioned tenant Android capability record.

  This record owns tenant admission and lease duration. The Connector enforces
  its single runtime slot. Connector metadata,
  plugin visibility, and skill projection are not substitutes for it.
  """

  alias Salix.Control.Tenants

  @profile_id ~r/^[a-z0-9][a-z0-9._-]{0,63}$/
  @mode "connected"

  @spec authorize(String.t()) :: {:ok, map()} | {:error, atom()}
  def authorize(tenant_id) when is_binary(tenant_id) do
    case Tenants.get_config(tenant_id, "android_control", :missing) do
      {:ok, config} -> validate(config)
      {:error, _reason} -> {:error, :android_policy_unavailable}
    end
  rescue
    _exception -> {:error, :android_policy_unavailable}
  end

  def authorize(_tenant_id), do: {:error, :android_not_authorized}

  defp validate(
         %{
           "version" => 2,
           "enabled" => true,
           "allowed_modes" => modes,
           "allowed_profiles" => profiles,
           "max_concurrent_leases" => leases,
           "max_lease_seconds" => seconds
         } = config
       )
       when is_list(modes) and is_list(profiles) and is_integer(leases) and
              is_integer(seconds) do
    allowed_keys =
      ~w(version enabled allowed_modes allowed_profiles max_concurrent_leases max_lease_seconds)

    if Map.keys(config) |> Enum.all?(&(&1 in allowed_keys)) and
         modes == [@mode] and valid_profiles?(profiles) and leases == 1 and
         seconds >= 60 and seconds <= 3600 do
      {:ok, %{max_lease_seconds: seconds, allowed_profiles: profiles}}
    else
      {:error, :android_not_authorized}
    end
  end

  defp validate(_config), do: {:error, :android_not_authorized}

  defp valid_profiles?(profiles) do
    length(profiles) in 1..8 and length(Enum.uniq(profiles)) == length(profiles) and
      Enum.all?(profiles, &(is_binary(&1) and Regex.match?(@profile_id, &1)))
  end

  @doc "Resolve the requested profile before dispatch to a version-two Connector."
  def authorize_action(policy, %{"protocol_version" => 2} = android, action) do
    with {:ok, installed} <- installed_profiles(android) do
      profile =
        if action["action"] == "start",
          do: Map.get(action, "profile", android["default_profile"]),
          else: action["profile"]

      cond do
        action["action"] == "status" and is_nil(profile) ->
          {:ok, Map.delete(action, "profile")}

        not is_binary(profile) or profile == "" ->
          {:error, :android_profile_required}

        profile not in policy.allowed_profiles ->
          {:error, :android_profile_not_allowed}

        profile not in installed ->
          {:error, :android_profile_unavailable}

        true ->
          {:ok, Map.put(action, "profile", profile)}
      end
    end
  end

  def authorize_action(_policy, _android, _action), do: {:error, :android_profile_unavailable}

  defp installed_profiles(%{"profiles" => profiles, "profile_details" => details})
       when is_list(profiles) and is_list(details) and length(profiles) in 1..8 and
              length(details) <= 8 do
    valid_profiles =
      length(Enum.uniq(profiles)) == length(profiles) and
        Enum.all?(profiles, &(is_binary(&1) and Regex.match?(@profile_id, &1)))

    valid_details =
      Enum.all?(details, fn
        %{"id" => id, "status" => status}
        when is_binary(id) and status in ["installed", "unavailable"] ->
          id in profiles

        _other ->
          false
      end)

    detail_ids = for %{"id" => id} <- details, do: id

    installed =
      for %{"id" => id, "status" => "installed"} <- details,
          do: id

    if valid_profiles and valid_details and length(details) == length(profiles) and
         length(Enum.uniq(detail_ids)) == length(detail_ids) and
         Enum.sort(detail_ids) == Enum.sort(profiles) do
      {:ok, installed}
    else
      {:error, :android_profile_unavailable}
    end
  end

  defp installed_profiles(_android), do: {:error, :android_profile_unavailable}
end
