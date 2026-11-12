defmodule Salix.Control.AndroidControl do
  @moduledoc """
  Fail-closed reader for the versioned tenant Android capability record.

  This record owns tenant admission and lease duration. The Connector enforces
  its single runtime slot. Connector metadata,
  plugin visibility, and skill projection are not substitutes for it.

  `allowed_modes` names what the tenant admits: `connected`, a station-hosted
  emulator started from an installed profile (protocol 2), and `device`, a
  computer's own emulators and the phones its owner offers to agents
  (protocol 3, systems/station/docs/android-screen.md). A record admits only the
  modes it names; profiles are required while it names `connected`.
  """

  alias Salix.Control.Tenants

  @profile_id ~r/^[a-z0-9][a-z0-9._-]{0,63}$/
  @modes ~w(connected device)
  @device_target ~r/^android:[^\s\/?#]{1,200}$/

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
         valid_modes?(modes) and profiles_for?(modes, profiles) and leases == 1 and
         seconds >= 60 and seconds <= 3600 do
      {:ok, %{max_lease_seconds: seconds, allowed_profiles: profiles, allowed_modes: modes}}
    else
      {:error, :android_not_authorized}
    end
  end

  defp validate(_config), do: {:error, :android_not_authorized}

  defp valid_modes?(modes) do
    modes != [] and length(Enum.uniq(modes)) == length(modes) and
      Enum.all?(modes, &(&1 in @modes))
  end

  defp profiles_for?(modes, profiles),
    do:
      if("connected" in modes,
        do: valid_profiles?(profiles),
        else: profiles == [] or valid_profiles?(profiles)
      )

  defp valid_profiles?(profiles) do
    length(profiles) in 1..8 and length(Enum.uniq(profiles)) == length(profiles) and
      Enum.all?(profiles, &(is_binary(&1) and Regex.match?(@profile_id, &1)))
  end

  @doc """
  Resolve the requested profile before dispatch to a version-two Connector, or
  the device a version-three Connector names in its `device` mode.
  """
  def authorize_action(policy, %{"protocol_version" => 3, "mode" => "device"}, action) do
    cond do
      "device" not in Map.get(policy, :allowed_modes, []) ->
        {:error, :android_mode_not_allowed}

      action["action"] == "start" and
          not (is_binary(action["target"]) and Regex.match?(@device_target, action["target"])) ->
        {:error, :android_target_required}

      true ->
        {:ok, Map.delete(action, "profile")}
    end
  end

  def authorize_action(policy, %{"protocol_version" => 2} = android, action) do
    if "connected" in Map.get(policy, :allowed_modes, ["connected"]),
      do: authorize_profile(policy, android, action),
      else: {:error, :android_mode_not_allowed}
  end

  def authorize_action(_policy, _android, _action), do: {:error, :android_profile_unavailable}

  defp authorize_profile(policy, android, action) do
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
