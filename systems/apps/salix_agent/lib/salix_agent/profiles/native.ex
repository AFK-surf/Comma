defmodule SalixAgent.Profiles.Native do
  @moduledoc false
  # The NIF of systems/profiles/nif, staged into priv/native by
  # Mix.Tasks.Compile.ProfilesNif (and by the release image's own stage).

  @on_load :load_nif

  def load_nif do
    :salix_agent
    |> :code.priv_dir()
    |> :filename.join(~c"native/comma_profiles_nif")
    |> :erlang.load_nif(0)
  end

  def sources_json, do: :erlang.nif_error(:nif_not_loaded)
  def rank_json(_profiles, _request), do: :erlang.nif_error(:nif_not_loaded)
  def runtime_config_json(_profile, _runtime, _key), do: :erlang.nif_error(:nif_not_loaded)
  def model_key_of(_spelled), do: :erlang.nif_error(:nif_not_loaded)
  def usable_json(_profile, _model, _now), do: :erlang.nif_error(:nif_not_loaded)
  def refills_at_json(_profile, _model, _now), do: :erlang.nif_error(:nif_not_loaded)
  def quota_json(_provider, _body, _now), do: :erlang.nif_error(:nif_not_loaded)
end
