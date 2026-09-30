defmodule SalixSignalProto.Group.AuthCredential do
  @moduledoc """
  The group auth credential with PNI (CRS-09a section 13). A client proves
  group membership to the storage service with a presentation of it.

  | Object | Bytes | Layout |
  | --- | --- | --- |
  | Issuance response | 425 | `0x03 ‖ sc(t) ‖ enc(U) ‖ enc(V) ‖ le64(320) ‖ proof` |
  | Credential (local) | 265 | `0x03 ‖ sc(t) ‖ enc(U) ‖ enc(V) ‖ u_aci ‖ enc(M1) ‖ enc(M2) ‖ u_pni ‖ enc(M1) ‖ enc(M2) ‖ le64(τ)` |
  | Presentation | 633 | see `present/4` |

  Times are Unix seconds. The redemption time `τ` is day-aligned.

  `issue/5` and `verify/4` are the server side, for test servers and the
  mock storage service.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Generators, as: G
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.Proof
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.Sho
  alias SalixSignalProto.Group.Uid

  @m0_label "20240222_Signal_AuthCredentialZkc"
  @issue_label "Signal_ZKCredential_Issuance_20230410"
  @present_label "Signal_ZKCredential_Presentation_20230410"
  @version 0x03
  @day 86_400
  # {name, UUID} of the RFC 4122 namespace for synthetic PNIs (section 13.6).
  @synthetic_namespace <<0x01, 0x9F, 0xAA, 0x2B, 0x7B, 0xCB, 0x70, 0xC2, 0xAC, 0x7F, 0xCD, 0x77,
                         0x04, 0x14, 0x68, 0x9A>>

  @issue_statement [
    {:c_w, [{:w, :h_w}, {:w2, :h_w2}]},
    {:h_v_minus_i5,
     [
       {:x0, :h_x0},
       {:x1, :h_x1},
       {:y0, :h_y0},
       {:y1, :h_y1},
       {:y2, :h_y2},
       {:y3, :h_y3},
       {:y4, :h_y4}
     ]},
    {:v,
     [
       {:w, :h_w},
       {:x0, :u},
       {:x1, :t_u},
       {:y0, :m0},
       {:y1, :m1},
       {:y2, :m2},
       {:y3, :m3},
       {:y4, :m4}
     ]}
  ]

  @present_statement [
    {:zp, [{:z, :i5}]},
    {:c_x1, [{:t, :c_x0}, {:z0, :h_x0}, {:z, :h_x1}]},
    {:identity, [{:z1, :i5}, {:a1, :zp}]},
    {:a, [{:a1, :g_a1}, {:a2, :g_a2}]},
    {:e_a1, [{:a1, :c_y1}, {:z1, :h_y1}]},
    {:c_y2_minus_e_a2, [{:z, :h_y2}, {:a2, :neg_e_a1}]},
    {:e_a3, [{:a1, :c_y3}, {:z1, :h_y3}]},
    {:c_y4_minus_e_a4, [{:z, :h_y4}, {:a2, :neg_e_a3}]},
    {:c_y0, [{:z, :h_y0}]}
  ]

  @doc false
  def statements, do: %{issue: @issue_statement, present: @present_statement}

  @type service_id :: Uid.service_id()

  @doc "`M0`, the public time attribute: squeeze-point of `H(label; be64(τ))`."
  @spec m0(non_neg_integer()) :: R.element()
  def m0(redemption_time) do
    {point, _} = @m0_label |> Sho.derive(<<redemption_time::64>>) |> Sho.squeeze_point()
    point
  end

  @doc """
  The synthetic PNI of an account without a PNI (section 13.6): the RFC 4122
  version-5 UUID with the fixed namespace and name `SHA-256(salt) ‖ aci`.
  """
  @spec synthetic_pni(<<_::128>>, binary()) :: <<_::128>>
  def synthetic_pni(<<_::binary-size(16)>> = aci, salt) when is_binary(salt) do
    <<a::binary-size(6), b6, b7, b8, rest::binary-size(7), _::binary>> =
      :crypto.hash(:sha, [@synthetic_namespace, :crypto.hash(:sha256, salt), aci])

    <<a::binary, Bitwise.bor(Bitwise.band(b6, 0x0F), 0x50), b7,
      Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80), rest::binary>>
  end

  @doc """
  Receives an issuance response (section 13.3) for the client's own ACI and
  PNI (raw UUIDs) and day-aligned redemption time. Pass `{:salt, salt}` as
  the PNI for an account without one (section 13.6).
  """
  @spec receive(
          ServerParams.Public.t(),
          <<_::128>>,
          <<_::128>> | {:salt, binary()},
          non_neg_integer(),
          binary()
        ) :: {:ok, binary()} | {:error, :invalid}
  def receive(%ServerParams.Public{} = server, aci, pni, redemption_time, response) do
    {pni_attr, pni_stored} = pni_parts(aci, pni)

    with true <- rem(redemption_time, @day) == 0,
         <<@version, t::binary-size(32), u::binary-size(32), v::binary-size(32), 320::little-64,
           proof::binary-size(320)>> <- response,
         {:ok, _} <- R.decode_scalar(t),
         true <- R.valid?(u) and R.valid?(v),
         m = attributes(aci, pni_attr, redemption_time),
         {c_w, _} = server.generic,
         points =
           Map.merge(generic_points(), %{
             c_w: c_w,
             h_v_minus_i5: R.sub(G.get(:h_v), ServerParams.Public.generic_i(server, 5)),
             v: v,
             u: u,
             t_u: R.mul(t, u),
             m0: m.m0,
             m1: m.m1,
             m2: m.m2,
             m3: m.m3,
             m4: m.m4
           }),
         true <- Proof.verify(@issue_statement, points, "", proof) do
      {:ok,
       <<@version, t::binary, u::binary, v::binary, aci::binary, m.m1::binary, m.m2::binary,
         pni_stored::binary, m.m3::binary, m.m4::binary, redemption_time::little-64>>}
    else
      _ -> {:error, :invalid}
    end
  end

  defp pni_parts(aci, {:salt, salt}), do: {synthetic_pni(aci, salt), <<0::128>>}
  defp pni_parts(_aci, <<_::binary-size(16)>> = pni), do: {pni, pni}

  defp attributes(aci, pni, redemption_time) do
    %{
      m0: m0(redemption_time),
      m1: Uid.m1({:aci, aci}),
      m2: Uid.m2(aci),
      m3: Uid.m1({:pni, pni}),
      m4: Uid.m2(pni)
    }
  end

  defp generic_points do
    Map.new(
      [:h_w, :h_w2, :h_x0, :h_x1, :h_y0, :h_y1, :h_y2, :h_y3, :h_y4, :h_v],
      &{&1, G.get(&1)}
    )
  end

  @doc """
  Creates a 633-byte presentation for the group (section 13.4) with 32 bytes
  of randomness. Returns `{presentation, aci_ciphertext, pni_ciphertext}`;
  the ciphertexts are the 65-byte UID ciphertexts that the server extracts.
  """
  @spec present(ServerParams.Public.t(), Params.t(), binary(), <<_::256>>) ::
          {:ok, {binary(), binary(), binary()}} | {:error, :invalid}
  def present(server, group, credential, randomness \\ :crypto.strong_rand_bytes(32))

  def present(
        %ServerParams.Public{} = server,
        %Params{} = group,
        <<@version, t::binary-size(32), u::binary-size(32), v::binary-size(32),
          _aci::binary-size(16), m1::binary-size(32), m2::binary-size(32), _pni::binary-size(16),
          m3::binary-size(32), m4::binary-size(32), redemption_time::little-64>>,
        <<_::binary-size(32)>> = randomness
      ) do
    with {:ok, _} <- R.decode_scalar(t),
         true <- Enum.all?([u, v, m1, m2, m3, m4], &R.valid?/1) do
      state = Sho.derive(@present_label, randomness)
      {z, state} = Sho.squeeze_scalar(state)
      {proof_randomness, _state} = Sho.squeeze(state, 32)

      i5 = ServerParams.Public.generic_i(server, 5)
      h = fn name -> G.get(name) end
      c_y0 = R.mul(z, h.(:h_y0))
      c_y1 = R.add(R.mul(z, h.(:h_y1)), m1)
      c_y2 = R.add(R.mul(z, h.(:h_y2)), m2)
      c_y3 = R.add(R.mul(z, h.(:h_y3)), m3)
      c_y4 = R.add(R.mul(z, h.(:h_y4)), m4)
      c_x0 = R.add(R.mul(z, h.(:h_x0)), u)
      c_x1 = R.add(R.mul(z, h.(:h_x1)), R.mul(t, u))
      c_v = R.add(R.mul(z, h.(:h_v)), v)
      z0 = R.scalar_negate(R.scalar_mul(z, t))
      z1 = R.scalar_negate(R.scalar_mul(z, group.a1))
      zp = R.mul(z, i5)
      e_a1 = R.mul(group.a1, m1)
      e_a2 = R.add(R.mul(group.a2, e_a1), m2)
      e_a3 = R.mul(group.a1, m3)
      e_a4 = R.add(R.mul(group.a2, e_a3), m4)

      points =
        Map.merge(generic_points(), %{
          zp: zp,
          i5: i5,
          c_x0: c_x0,
          c_x1: c_x1,
          identity: R.identity(),
          a: group.a,
          g_a1: G.get(:g_a1),
          g_a2: G.get(:g_a2),
          e_a1: e_a1,
          c_y1: c_y1,
          c_y2_minus_e_a2: R.sub(c_y2, e_a2),
          neg_e_a1: R.sub(R.identity(), e_a1),
          e_a3: e_a3,
          c_y3: c_y3,
          c_y4_minus_e_a4: R.sub(c_y4, e_a4),
          neg_e_a3: R.sub(R.identity(), e_a3),
          c_y0: c_y0
        })

      scalars = %{z: z, t: t, z0: z0, z1: z1, a1: group.a1, a2: group.a2}
      proof = Proof.prove(@present_statement, scalars, points, "", proof_randomness)

      presentation =
        IO.iodata_to_binary([
          @version,
          c_x0,
          c_x1,
          c_v,
          <<5::little-64>>,
          [c_y0, c_y1, c_y2, c_y3, c_y4],
          <<224::little-64>>,
          proof,
          e_a1,
          e_a2,
          e_a3,
          e_a4,
          <<redemption_time::little-64>>
        ])

      {:ok, {presentation, <<0, e_a1::binary, e_a2::binary>>, <<0, e_a3::binary, e_a4::binary>>}}
    else
      _ -> {:error, :invalid}
    end
  end

  def present(_server, _group, _credential, _randomness), do: {:error, :invalid}

  @doc """
  Parses a 633-byte presentation into its parts. Returns the two 65-byte UID
  ciphertexts and the redemption time with the commitments and proof.
  """
  @spec decode_presentation(binary()) :: {:ok, map()} | {:error, :invalid}
  def decode_presentation(
        <<@version, c_x0::binary-size(32), c_x1::binary-size(32), c_v::binary-size(32),
          5::little-64, c_ys::binary-size(160), 224::little-64, proof::binary-size(224),
          e_a1::binary-size(32), e_a2::binary-size(32), e_a3::binary-size(32),
          e_a4::binary-size(32), redemption_time::little-64>>
      ) do
    c_y = for <<p::binary-size(32) <- c_ys>>, do: p
    points = [c_x0, c_x1, c_v, e_a1, e_a2, e_a3, e_a4 | c_y]

    if Enum.all?(points, &R.valid?/1) do
      {:ok,
       %{
         c_x0: c_x0,
         c_x1: c_x1,
         c_v: c_v,
         c_y: c_y,
         proof: proof,
         aci_ciphertext: <<0, e_a1::binary, e_a2::binary>>,
         pni_ciphertext: <<0, e_a3::binary, e_a4::binary>>,
         redemption_time: redemption_time
       }}
    else
      {:error, :invalid}
    end
  end

  def decode_presentation(_bytes), do: {:error, :invalid}

  @doc false
  # Server side (section 13.2), for test servers and the mock storage service.
  def issue(%ServerParams.Secret{generic: key} = secret, aci, pni, redemption_time, randomness) do
    {pni_attr, _} = pni_parts(aci, pni)
    state = Sho.derive(@issue_label, randomness)
    {t, state} = Sho.squeeze_scalar(state)
    {u, state} = Sho.squeeze_point(state)
    {proof_randomness, _state} = Sho.squeeze(state, 32)
    m = attributes(aci, pni_attr, redemption_time)
    [y0, y1, y2, y3, y4 | _] = key.ys

    v =
      Proof.sum([
        key.big_w,
        R.mul(R.scalar_add(key.x0, R.scalar_mul(key.x1, t)), u),
        R.mul(y0, m.m0),
        R.mul(y1, m.m1),
        R.mul(y2, m.m2),
        R.mul(y3, m.m3),
        R.mul(y4, m.m4)
      ])

    {c_w, is} = ServerParams.generic_public(secret)

    points =
      Map.merge(generic_points(), %{
        c_w: c_w,
        h_v_minus_i5: R.sub(G.get(:h_v), Enum.at(is, 3)),
        v: v,
        u: u,
        t_u: R.mul(t, u),
        m0: m.m0,
        m1: m.m1,
        m2: m.m2,
        m3: m.m3,
        m4: m.m4
      })

    scalars = %{
      w: key.w,
      w2: key.w2,
      x0: key.x0,
      x1: key.x1,
      y0: y0,
      y1: y1,
      y2: y2,
      y3: y3,
      y4: y4
    }

    proof = Proof.prove(@issue_statement, scalars, points, "", proof_randomness)
    <<@version, t::binary, u::binary, v::binary, 320::little-64, proof::binary>>
  end

  @doc false
  # Server side (section 13.5): accepts within [τ − 1 day, τ + 2 days].
  def verify(%ServerParams.Secret{generic: key} = secret, group_public, presentation, now) do
    with {:ok, p} <- decode_presentation(presentation),
         true <- p.redemption_time - @day <= now and now <= p.redemption_time + 2 * @day,
         {:ok, {_gid, a, _b}} <- Params.decode_public_params(group_public) do
      {_c_w, is} = ServerParams.generic_public(secret)
      i5 = Enum.at(is, 3)
      m0 = m0(p.redemption_time)
      [c_y0, c_y1, c_y2, c_y3, c_y4] = p.c_y
      <<0, e_a1::binary-size(32), e_a2::binary-size(32)>> = p.aci_ciphertext
      <<0, e_a3::binary-size(32), e_a4::binary-size(32)>> = p.pni_ciphertext

      zp =
        Enum.zip(key.ys, p.c_y)
        |> Enum.take(5)
        |> Enum.reduce(
          p.c_v
          |> R.sub(key.big_w)
          |> R.sub(R.mul(key.x0, p.c_x0))
          |> R.sub(R.mul(key.x1, p.c_x1)),
          fn {y, c}, acc -> R.sub(acc, R.mul(y, c)) end
        )
        |> R.sub(R.mul(hd(key.ys), m0))

      points =
        Map.merge(generic_points(), %{
          zp: zp,
          i5: i5,
          c_x0: p.c_x0,
          c_x1: p.c_x1,
          identity: R.identity(),
          a: a,
          g_a1: G.get(:g_a1),
          g_a2: G.get(:g_a2),
          e_a1: e_a1,
          c_y1: c_y1,
          c_y2_minus_e_a2: R.sub(c_y2, e_a2),
          neg_e_a1: R.sub(R.identity(), e_a1),
          e_a3: e_a3,
          c_y3: c_y3,
          c_y4_minus_e_a4: R.sub(c_y4, e_a4),
          neg_e_a3: R.sub(R.identity(), e_a3),
          c_y0: c_y0
        })

      Proof.verify(@present_statement, points, "", p.proof)
    else
      _ -> false
    end
  end
end
