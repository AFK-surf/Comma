defmodule SalixSignalProto.Crypto.Native do
  @moduledoc false
  # The libsodium NIF (c_src/salix_signal_proto_nif.c). Callers are the
  # public modules in SalixSignalProto.Crypto; every function raises
  # ArgumentError for an input of the wrong type or size.

  @on_load :load_nif

  def load_nif do
    :salix_signal_proto
    |> :code.priv_dir()
    |> :filename.join(~c"salix_signal_proto_nif")
    |> :erlang.load_nif(0)
  end

  def xeddsa_sign(_private_key, _message, _random), do: :erlang.nif_error(:nif_not_loaded)

  def ristretto255_is_valid_point(_point), do: :erlang.nif_error(:nif_not_loaded)
  def ristretto255_from_hash(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def ristretto255_add(_p, _q), do: :erlang.nif_error(:nif_not_loaded)
  def ristretto255_sub(_p, _q), do: :erlang.nif_error(:nif_not_loaded)
  def ristretto255_scalarmult(_scalar, _point), do: :erlang.nif_error(:nif_not_loaded)
  def ristretto255_scalarmult_base(_scalar), do: :erlang.nif_error(:nif_not_loaded)

  def scalar_is_canonical(_scalar), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_reduce(_wide), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_add(_x, _y), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_sub(_x, _y), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_mul(_x, _y), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_negate(_x), do: :erlang.nif_error(:nif_not_loaded)
  def scalar_invert(_x), do: :erlang.nif_error(:nif_not_loaded)
end
