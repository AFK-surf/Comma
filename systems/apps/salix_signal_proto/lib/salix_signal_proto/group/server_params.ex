defmodule SalixSignalProto.Group.ServerParams do
  @moduledoc """
  The storage and chat servers' credential keys (CRS-09a section 11).

  Clients hold the 673-byte public params as a constant: `production/0`
  returns the published production value. `decode_public/1` extracts the
  keys that clients use:

  | Offset | Key | Used for |
  | --- | --- | --- |
  | 129 | `notary` (`PK_sig`) | Notary signatures (section 12) |
  | 289 | `profile_key` (`{C_W, I}`, classic table) | Expiring profile key credential (section 14) |
  | 417 | `generic` (`C_W`, `I_2 … I_7`) | Group auth credential with `I_5` (section 13) |
  | 641 | `endorsement` (`PK_e`) | Group send endorsements (section 15) |

  The secret params and `generate/1` exist only for test servers and the
  mock storage service. Their 2721-byte layout is test-server-only.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Generators, as: G
  alias SalixSignalProto.Group.Sho

  @classic_label "Signal_ZKGroup_20200424_Random_ServerSecretParams_Generate"
  @generic_label "Signal_ZKCredential_CredentialPrivateKey_generate_20230410"
  @endorsement_label "Signal_ZKCredential_Endorsements_ServerRootKeyPair_generate_20240207"

  @production Base.decode64!(
                "AMhf5ywVwITZMsff/eCyudZx9JDmkkkbV6PInzG4p8x3VqVJSFiMvnvlEKWuRob/1eaIetR31IYeAbm0NdOuHH8Qi+Rexi1wLlpzIo1gstHWBfZzy1+qHRV5A4TqPp15YzBPm0WSggW6PbSn+F4lf57VCnHF7p8SvzAA2ZZJPYJURt8X7bbg+H3i+PEjH9DXItNEqs2sNcug37xZQDLm7X36nOoGPs54XsEGzPdEV+itQNGUFEjY6X9Uv+Acuks7NpyGvCoKxGwgKgE5XyJ+nNKlyHHOLb6N1NuHyBrZrgtY/JYJHRooo5CEqYKBqdFnmbTVGEkCvJKxLnjwKWf+fEPoWeQFj5ObDjcKMZf2Jm2Ae69x+ikU5gBXsRmoF94GXTLfN0/vLt98KDPnxwAQL9j5V1jGOY8jQl6MLxEs56cwXN0dqCnImzVH3TZT1cJ8SW1BRX6qIVxEzjsSGx3yxF3suAilPMqGRp4ffyopjMD1JXiKR2RwLKzizUe5e8XyGOy9fplzhw3jVzTRyUZTRSZKkMLWcQ/gv0E4aONNqs4P+NameAZYOD12qRkxosQQP5uux6B2nRyZ7sAV54DgFyLiRcq1FvwKw2EPQdk4HDoePrO/RNUbyNddnM/mMgj4FW65xCoT1LmjrIjsv/Ggdlx46ueczhMgtBunx1/w8k8V+l8LVZ8gAT6wkU5J+DPQalQguMg12Jzug3q4TbdHiGCmD9EunCwOmsLuLJkz6EcSYXtrlDEnAM+hicw7iergYLLlMXpfTdGxJCWJmP4zqUFeTTmsmhsjGBt7NiEB/9pFFEB3pSbf4iiUukw63Eo8Aqnf4iwob6X1QviCWuc8t0LUlT9vALgh/f2DPVOOmR0RW6bgRvc7DSF20V/omg+YBw=="
              )

  defmodule Public do
    @moduledoc "The client-side keys in the server public params."
    @enforce_keys [:notary, :profile_key, :generic, :endorsement, :bytes]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            notary: <<_::256>>,
            profile_key: {<<_::256>>, <<_::256>>},
            generic: {<<_::256>>, [<<_::256>>]},
            endorsement: <<_::256>>,
            bytes: <<_::5384>>
          }

    @doc "The generic credential key `I_n` for `n` attribute slots (2 to 7)."
    @spec generic_i(t(), 2..7) :: <<_::256>>
    def generic_i(%__MODULE__{generic: {_cw, is}}, n) when n in 2..7, do: Enum.at(is, n - 2)
  end

  defmodule Secret do
    @moduledoc false
    # Test-server-only keys. `classic` maps each key name to
    # %{w, w2, big_w, x0, x1, ys, c_w, i}; `generic` holds %{w, w2, big_w, x0,
    # x1, ys} with ys = [y0, ..., y6]; `endorsement` is the root scalar e.
    @enforce_keys [:classic, :notary, :generic, :endorsement]
    defstruct @enforce_keys
  end

  # {name, stored y count N, active attribute count n}, in squeeze order;
  # the notary key sits between the second and third pair.
  @classic_pairs [
    {:retired_auth, 4, 3},
    {:retired_profile_key, 4, 4},
    {:receipt, 4, 2},
    {:retired_pni, 6, 6},
    {:profile_key, 5, 5},
    {:retired_auth_with_pni, 5, 5}
  ]

  @doc "The production public params (673 bytes)."
  @spec production() :: <<_::5384>>
  def production, do: @production

  @doc "Parses 673-byte public params. All points must decode."
  @spec decode_public(binary()) :: {:ok, Public.t()} | {:error, :invalid}
  def decode_public(
        <<0, _retired::binary-size(128), notary::binary-size(32), _receipt::binary-size(128),
          pk_cw::binary-size(32), pk_i::binary-size(32), _retired2::binary-size(64),
          generic_cw::binary-size(32), generic_is::binary-size(192),
          endorsement::binary-size(32)>> =
          bytes
      ) do
    is = for <<i::binary-size(32) <- generic_is>>, do: i

    if Enum.all?(
         [notary, pk_cw, pk_i, generic_cw, endorsement | is] ++ other_points(bytes),
         &R.valid?/1
       ) do
      {:ok,
       %Public{
         notary: notary,
         profile_key: {pk_cw, pk_i},
         generic: {generic_cw, is},
         endorsement: endorsement,
         bytes: bytes
       }}
    else
      {:error, :invalid}
    end
  end

  def decode_public(_bytes), do: {:error, :invalid}

  defp other_points(<<0, rest::binary>>) do
    for <<point::binary-size(32) <- rest>>, do: point
  end

  @doc false
  # Test servers only (CRS-09a section 11.2).
  @spec generate(<<_::256>>) :: %Secret{}
  def generate(<<_::binary-size(32)>> = randomness) do
    state = Sho.derive(@classic_label, randomness)

    {pairs, state} =
      Enum.map_reduce(Enum.take(@classic_pairs, 2), state, &classic_pair/2)

    {x, state} = Sho.squeeze_scalar(state)
    {rest, _state} = Enum.map_reduce(Enum.drop(@classic_pairs, 2), state, &classic_pair/2)

    {[w, w2, x0, x1 | ys], _} =
      @generic_label |> Sho.derive(randomness) |> Sho.squeeze_scalars(11)

    {e, _} = @endorsement_label |> Sho.derive(randomness) |> Sho.squeeze_scalar()

    %Secret{
      classic: Map.new(pairs ++ rest),
      notary: x,
      generic: %{w: w, w2: w2, big_w: R.mul(w, G.get(:h_w)), x0: x0, x1: x1, ys: ys},
      endorsement: e
    }
  end

  defp classic_pair({name, count, active}, state) do
    {[w, w2, x0, x1 | ys], state} = Sho.squeeze_scalars(state, 4 + count)
    big_w = R.mul(w, G.get(:g_w))
    c_w = R.add(big_w, R.mul(w2, G.get(:g_w2)))

    i =
      ys
      |> Enum.take(active)
      |> Enum.with_index(1)
      |> Enum.reduce(
        G.get(:g_v) |> R.sub(R.mul(x0, G.get(:g_x0))) |> R.sub(R.mul(x1, G.get(:g_x1))),
        fn {y, index}, acc -> R.sub(acc, R.mul(y, G.get(:"g_y#{index}"))) end
      )

    {{name, %{w: w, w2: w2, big_w: big_w, x0: x0, x1: x1, ys: ys, c_w: c_w, i: i}}, state}
  end

  @doc false
  # The generic key's `C_W` and `I_n` for n = 2..7.
  def generic_public(%Secret{generic: g}) do
    c_w = R.add(g.big_w, R.mul(g.w2, G.get(:h_w2)))
    [y0 | rest] = g.ys

    base =
      G.get(:h_v)
      |> R.sub(R.mul(g.x0, G.get(:h_x0)))
      |> R.sub(R.mul(g.x1, G.get(:h_x1)))
      |> R.sub(R.mul(y0, G.get(:h_y0)))

    {is, _} =
      Enum.map_reduce(2..7, base, fn n, acc ->
        # I_n = I_{n-1} - y_{n-1}·H_y{n-1}, starting from the y0 term.
        acc = R.sub(acc, R.mul(Enum.at(rest, n - 2), G.get(:"h_y#{n - 1}")))
        {acc, acc}
      end)

    {c_w, is}
  end

  @doc false
  # Serializes the 2721-byte test-server secret params.
  def encode_secret(%Secret{} = secret) do
    {pairs, rest} = Enum.split(@classic_pairs, 2)
    encode_pair = fn {name, _, _} -> encode_classic(secret.classic[name]) end
    g = secret.generic

    IO.iodata_to_binary([
      0,
      Enum.map(pairs, encode_pair),
      secret.notary,
      R.mul_base(secret.notary),
      Enum.map(rest, encode_pair),
      [g.w, g.w2, g.big_w, g.x0, g.x1 | g.ys],
      secret.endorsement
    ])
  end

  defp encode_classic(k), do: [k.w, k.w2, k.big_w, k.x0, k.x1, k.ys, k.c_w, k.i]

  @doc false
  # The 673-byte public params of a test server.
  def public_from_secret(%Secret{} = secret) do
    pub = fn name -> [secret.classic[name].c_w, secret.classic[name].i] end
    {c_w, is} = generic_public(secret)

    IO.iodata_to_binary([
      0,
      pub.(:retired_auth),
      pub.(:retired_profile_key),
      R.mul_base(secret.notary),
      pub.(:receipt),
      pub.(:retired_pni),
      pub.(:profile_key),
      pub.(:retired_auth_with_pni),
      c_w,
      is,
      R.mul_base(secret.endorsement)
    ])
  end

  @doc false
  # Parses the 2721-byte test-server secret params written by encode_secret/1.
  def decode_secret(<<0, rest::binary>> = bytes) when byte_size(bytes) == 2721 do
    {pairs_a, rest} = parse_pairs(Enum.take(@classic_pairs, 2), rest)
    <<x::binary-size(32), _pk::binary-size(32), rest::binary>> = rest
    {pairs_b, rest} = parse_pairs(Enum.drop(@classic_pairs, 2), rest)

    <<w::binary-size(32), w2::binary-size(32), big_w::binary-size(32), x0::binary-size(32),
      x1::binary-size(32), ys::binary-size(224), e::binary-size(32)>> = rest

    {:ok,
     %Secret{
       classic: Map.new(pairs_a ++ pairs_b),
       notary: x,
       generic: %{w: w, w2: w2, big_w: big_w, x0: x0, x1: x1, ys: chunks(ys)},
       endorsement: e
     }}
  end

  def decode_secret(_bytes), do: {:error, :invalid}

  defp parse_pairs(specs, bytes) do
    Enum.map_reduce(specs, bytes, fn {name, count, _active}, rest ->
      y_bytes = 32 * count

      <<w::binary-size(32), w2::binary-size(32), big_w::binary-size(32), x0::binary-size(32),
        x1::binary-size(32), ys::binary-size(^y_bytes), c_w::binary-size(32), i::binary-size(32),
        rest::binary>> = rest

      {{name, %{w: w, w2: w2, big_w: big_w, x0: x0, x1: x1, ys: chunks(ys), c_w: c_w, i: i}},
       rest}
    end)
  end

  defp chunks(bytes), do: for(<<c::binary-size(32) <- bytes>>, do: c)
end
