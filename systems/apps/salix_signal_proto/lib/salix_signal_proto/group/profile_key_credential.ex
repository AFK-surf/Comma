defmodule SalixSignalProto.Group.ProfileKeyCredential do
  @moduledoc """
  The expiring profile key credential (CRS-09a section 14). It proves that a
  group member's encrypted profile key is the one that the member committed
  to on the chat server. A member adds it to group changes as a
  presentation.

  | Object | Bytes | Layout |
  | --- | --- | --- |
  | Request | 329 | `0x00 ‖ enc(Y) ‖ enc(D1) ‖ enc(D2) ‖ enc(E1) ‖ enc(E2) ‖ le64(160) ‖ proof` |
  | Request context (local) | 473 | `0x00 ‖ u ‖ k ‖ sc(y) ‖ enc(Y) ‖ sc(r1) ‖ sc(r2) ‖ D1 D2 E1 E2 ‖ le64(160) ‖ proof` |
  | Response | 497 | `0x00 ‖ sc(t) ‖ enc(U) ‖ enc(S1) ‖ enc(S2) ‖ le64(ε) ‖ le64(352) ‖ proof` |
  | Credential (local) | 153 | `0x00 ‖ sc(t) ‖ enc(U) ‖ enc(V) ‖ u ‖ k ‖ le64(ε)` |
  | Presentation | 721 | see `present/4` |

  The request travels hex-encoded in the profile fetch path (CRS-08). Times
  are Unix seconds; the expiration `ε` is day-aligned.

  `issue/6` and `verify/4` are the server side, for test servers and the
  mock storage service.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Generators, as: G
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.ProfileKey
  alias SalixSignalProto.Group.Proof
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.Sho
  alias SalixSignalProto.Group.Uid

  @request_label "Signal_ZKGroup_20200424_Random_ServerPublicParams_CreateProfileKeyCredentialRequestContext"
  @issue_label "Signal_ZKGroup_20220508_Random_ServerSecretParams_IssueExpiringProfileKeyCredential"
  @present_label "Signal_ZKGroup_20220508_Random_ServerPublicParams_CreateExpiringProfileKeyCredentialPresentation"
  @m5_label "Signal_ZKGroup_20220524_Timestamp_Calc_m"
  @day 86_400
  @presentation_version 0x03

  @request_statement [
    {:y_point, [{:y, :base}]},
    {:d1, [{:r1, :base}]},
    {:e1, [{:r2, :base}]},
    {:j3_point, [{:j3, :g_j3}]},
    {:d2_minus_j1, [{:r1, :y_point}, {:j3, :neg_g_j1}]},
    {:e2_minus_j2, [{:r2, :y_point}, {:j3, :neg_g_j2}]}
  ]

  @issue_statement [
    {:c_w, [{:w, :g_w}, {:w2, :g_w2}]},
    {:g_v_minus_i,
     [
       {:x0, :g_x0},
       {:x1, :g_x1},
       {:y1, :g_y1},
       {:y2, :g_y2},
       {:y3, :g_y3},
       {:y4, :g_y4},
       {:y5, :g_y5}
     ]},
    {:s1, [{:y3, :d1}, {:y4, :e1}, {:r_prime, :base}]},
    {:s2,
     [
       {:y3, :d2},
       {:y4, :e2},
       {:r_prime, :y_point},
       {:w, :g_w},
       {:x0, :u},
       {:x1, :t_u},
       {:y1, :m1},
       {:y2, :m2},
       {:y5, :m5}
     ]}
  ]

  @present_statement [
    {:zp, [{:z, :i}]},
    {:c_x1, [{:t, :c_x0}, {:z0, :g_x0}, {:z, :g_x1}]},
    {:a_plus_b, [{:a1, :g_a1}, {:a2, :g_a2}, {:b1, :g_b1}, {:b2, :g_b2}]},
    {:c_y2_minus_e_a2, [{:z, :g_y2}, {:a2, :neg_e_a1}]},
    {:e_a1, [{:a1, :c_y1}, {:z1, :g_y1}]},
    {:c_y4_minus_e_b2, [{:z, :g_y4}, {:b2, :neg_e_b1}]},
    {:e_b1, [{:b1, :c_y3}, {:z2, :g_y3}]},
    {:identity, [{:z1, :i}, {:a1, :zp}]},
    {:identity, [{:z2, :i}, {:b1, :zp}]},
    {:c_y5, [{:z, :g_y5}]}
  ]

  @doc false
  def statements,
    do: %{request: @request_statement, issue: @issue_statement, present: @present_statement}

  @classic [
    :g_w,
    :g_w2,
    :g_x0,
    :g_x1,
    :g_y1,
    :g_y2,
    :g_y3,
    :g_y4,
    :g_y5,
    :g_v,
    :g_j3,
    :g_a1,
    :g_a2,
    :g_b1,
    :g_b2
  ]

  defp classic_points, do: Map.new(@classic, &{&1, G.get(&1)})

  @doc "`M5 = m5·G_m5` for the expiration `ε`."
  @spec m5(non_neg_integer()) :: R.element()
  def m5(expiration) do
    {m5, _} = @m5_label |> Sho.derive(<<expiration::64>>) |> Sho.squeeze_scalar()
    R.mul(m5, G.get(:g_m5))
  end

  @doc """
  Creates a request for the client's own ACI `uuid` and profile key (section
  14.1). Returns `{context, request}`; keep the context for `receive/4`.
  """
  @spec request(<<_::128>>, ProfileKey.profile_key(), <<_::256>>) :: {binary(), binary()}
  def request(uuid, key, randomness \\ :crypto.strong_rand_bytes(32))

  def request(
        <<_::binary-size(16)>> = uuid,
        <<_::binary-size(32)>> = key,
        <<_::binary-size(32)>> = randomness
      ) do
    state = Sho.derive(@request_label, randomness)
    {[y, r1, r2], state} = Sho.squeeze_scalars(state, 3)
    {proof_randomness, _} = Sho.squeeze(state, 32)
    y_point = R.mul_base(y)
    m3 = ProfileKey.m3(key, uuid)
    m4 = ProfileKey.m4(key)
    d1 = R.mul_base(r1)
    e1 = R.mul_base(r2)
    d2 = R.add(R.mul(r1, y_point), m3)
    e2 = R.add(R.mul(r2, y_point), m4)
    {j1, j2, j3_point} = ProfileKey.commitment_points(key, uuid)
    j3 = ProfileKey.j3(key, uuid)

    points =
      Map.merge(classic_points(), %{
        y_point: y_point,
        d1: d1,
        e1: e1,
        j3_point: j3_point,
        d2_minus_j1: R.sub(d2, j1),
        neg_g_j1: R.sub(R.identity(), G.get(:g_j1)),
        e2_minus_j2: R.sub(e2, j2),
        neg_g_j2: R.sub(R.identity(), G.get(:g_j2))
      })

    proof =
      Proof.prove(
        @request_statement,
        %{y: y, r1: r1, r2: r2, j3: j3},
        points,
        "",
        proof_randomness
      )

    request =
      IO.iodata_to_binary([0, y_point, d1, d2, e1, e2, <<160::little-64>>, proof])

    context =
      IO.iodata_to_binary([
        0,
        uuid,
        key,
        y,
        y_point,
        r1,
        r2,
        d1,
        d2,
        e1,
        e2,
        <<160::little-64>>,
        proof
      ])

    {context, request}
  end

  @doc """
  Receives an issuance response with the request context (section 14.3).
  `now` is the local clock in Unix seconds. Returns `{:ok, credential,
  expiration}`.
  """
  @spec receive(ServerParams.Public.t(), binary(), binary(), integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :invalid}
  def receive(
        %ServerParams.Public{profile_key: {c_w, i}},
        <<0, uuid::binary-size(16), key::binary-size(32), y::binary-size(32),
          y_point::binary-size(32), _r1::binary-size(32), _r2::binary-size(32),
          d1::binary-size(32), d2::binary-size(32), e1::binary-size(32), e2::binary-size(32),
          160::little-64, _proof::binary-size(160)>>,
        <<0, t::binary-size(32), u::binary-size(32), s1::binary-size(32), s2::binary-size(32),
          expiration::little-64, 352::little-64, proof::binary-size(352)>>,
        now
      )
      when is_integer(now) do
    days = div(max(0, expiration - now), @day)

    with true <- rem(expiration, @day) == 0 and days >= 1 and days <= 7,
         {:ok, _} <- R.decode_scalar(t),
         true <- Enum.all?([u, s1, s2], &R.valid?/1) do
      points =
        Map.merge(classic_points(), %{
          c_w: c_w,
          g_v_minus_i: R.sub(G.get(:g_v), i),
          s1: s1,
          d1: d1,
          e1: e1,
          s2: s2,
          d2: d2,
          e2: e2,
          y_point: y_point,
          u: u,
          t_u: R.mul(t, u),
          m1: Uid.m1({:aci, uuid}),
          m2: Uid.m2(uuid),
          m5: m5(expiration)
        })

      if Proof.verify(@issue_statement, points, "", proof) do
        v = R.sub(s2, R.mul(y, s1))

        {:ok,
         <<0, t::binary, u::binary, v::binary, uuid::binary, key::binary, expiration::little-64>>,
         expiration}
      else
        {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def receive(%ServerParams.Public{}, _context, _response, _now), do: {:error, :invalid}

  @doc """
  Creates a 721-byte presentation for the group (section 14.4). Returns
  `{presentation, uid_ciphertext, profile_key_ciphertext}` with 65-byte
  ciphertexts.
  """
  @spec present(ServerParams.Public.t(), Params.t(), binary(), <<_::256>>) ::
          {:ok, {binary(), binary(), binary()}} | {:error, :invalid}
  def present(server, group, credential, randomness \\ :crypto.strong_rand_bytes(32))

  def present(
        %ServerParams.Public{profile_key: {_c_w, i}},
        %Params{} = group,
        <<0, t::binary-size(32), u::binary-size(32), v::binary-size(32), uuid::binary-size(16),
          key::binary-size(32), expiration::little-64>>,
        <<_::binary-size(32)>> = randomness
      ) do
    with {:ok, _} <- R.decode_scalar(t), true <- R.valid?(u) and R.valid?(v) do
      state = Sho.derive(@present_label, randomness)
      {z, state} = Sho.squeeze_scalar(state)
      {proof_randomness, _} = Sho.squeeze(state, 32)

      m1 = Uid.m1({:aci, uuid})
      m2 = Uid.m2(uuid)
      m3 = ProfileKey.m3(key, uuid)
      m4 = ProfileKey.m4(key)
      g = &G.get/1
      c_y1 = R.add(R.mul(z, g.(:g_y1)), m1)
      c_y2 = R.add(R.mul(z, g.(:g_y2)), m2)
      c_y3 = R.add(R.mul(z, g.(:g_y3)), m3)
      c_y4 = R.add(R.mul(z, g.(:g_y4)), m4)
      c_y5 = R.mul(z, g.(:g_y5))
      c_x0 = R.add(R.mul(z, g.(:g_x0)), u)
      c_x1 = R.add(R.mul(z, g.(:g_x1)), R.mul(t, u))
      c_v = R.add(R.mul(z, g.(:g_v)), v)
      z0 = R.scalar_negate(R.scalar_mul(z, t))
      z1 = R.scalar_negate(R.scalar_mul(z, group.a1))
      z2 = R.scalar_negate(R.scalar_mul(z, group.b1))
      zp = R.mul(z, i)
      e_a1 = R.mul(group.a1, m1)
      e_a2 = R.add(R.mul(group.a2, e_a1), m2)
      e_b1 = R.mul(group.b1, m3)
      e_b2 = R.add(R.mul(group.b2, e_b1), m4)

      points =
        presentation_points(%{
          zp: zp,
          i: i,
          c_x0: c_x0,
          c_x1: c_x1,
          a_plus_b: R.add(group.a, group.b),
          c_y1: c_y1,
          c_y2: c_y2,
          c_y3: c_y3,
          c_y4: c_y4,
          c_y5: c_y5,
          e_a1: e_a1,
          e_a2: e_a2,
          e_b1: e_b1,
          e_b2: e_b2
        })

      scalars = %{
        z: z,
        t: t,
        z0: z0,
        a1: group.a1,
        a2: group.a2,
        b1: group.b1,
        b2: group.b2,
        z1: z1,
        z2: z2
      }

      proof = Proof.prove(@present_statement, scalars, points, "", proof_randomness)

      presentation =
        IO.iodata_to_binary([
          @presentation_version,
          [c_x0, c_x1, c_y1, c_y2, c_y3, c_y4, c_y5, c_v],
          <<320::little-64>>,
          proof,
          e_a1,
          e_a2,
          e_b1,
          e_b2,
          <<expiration::little-64>>
        ])

      {:ok, {presentation, <<0, e_a1::binary, e_a2::binary>>, <<0, e_b1::binary, e_b2::binary>>}}
    else
      _ -> {:error, :invalid}
    end
  end

  def present(_server, _group, _credential, _randomness), do: {:error, :invalid}

  defp presentation_points(p) do
    Map.merge(classic_points(), %{
      zp: p.zp,
      i: p.i,
      c_x0: p.c_x0,
      c_x1: p.c_x1,
      a_plus_b: p.a_plus_b,
      c_y2_minus_e_a2: R.sub(p.c_y2, p.e_a2),
      neg_e_a1: R.sub(R.identity(), p.e_a1),
      e_a1: p.e_a1,
      c_y1: p.c_y1,
      c_y4_minus_e_b2: R.sub(p.c_y4, p.e_b2),
      neg_e_b1: R.sub(R.identity(), p.e_b1),
      e_b1: p.e_b1,
      c_y3: p.c_y3,
      identity: R.identity(),
      c_y5: p.c_y5
    })
  end

  @doc """
  Extracts the UID ciphertext and the profile key ciphertext (65 bytes each)
  from a presentation. They are at offsets 585 and 649 in presentation
  versions `0x00` to `0x03` (CRS-09a section 14.4); versions `0x00` and
  `0x01` are 713 bytes, the others 721.
  """
  @spec ciphertexts(binary()) :: {:ok, {binary(), binary()}} | {:error, :invalid}
  def ciphertexts(
        <<version, _::binary-size(584), uid::binary-size(64), pk::binary-size(64), rest::binary>>
      )
      when (version in [0, 1] and rest == <<>>) or (version in [2, 3] and byte_size(rest) == 8) do
    with {:ok, _} <- Uid.parse(<<0, uid::binary>>),
         {:ok, _} <- Uid.parse(<<0, pk::binary>>) do
      {:ok, {<<0, uid::binary>>, <<0, pk::binary>>}}
    end
  end

  def ciphertexts(_bytes), do: {:error, :invalid}

  @doc false
  # Server side (section 14.2), for test servers and the mock chat server.
  # `commitment` is the 97-byte profile key commitment stored with the profile.
  def issue(
        %ServerParams.Secret{classic: classic},
        request,
        uuid,
        commitment,
        expiration,
        randomness
      ) do
    key = classic.profile_key

    with {:ok, r} <- verify_request(request, commitment) do
      state = Sho.derive(@issue_label, randomness)
      {t, state} = Sho.squeeze_scalar(state)
      {u, state} = Sho.squeeze_point(state)
      {r_prime, state} = Sho.squeeze_scalar(state)
      {proof_randomness, _} = Sho.squeeze(state, 32)
      [y1, y2, y3, y4, y5] = key.ys
      m1 = Uid.m1({:aci, uuid})
      m2 = Uid.m2(uuid)
      m5 = m5(expiration)

      v_prime =
        Proof.sum([
          key.big_w,
          R.mul(R.scalar_add(key.x0, R.scalar_mul(key.x1, t)), u),
          R.mul(y1, m1),
          R.mul(y2, m2),
          R.mul(y5, m5)
        ])

      s1 = Proof.sum([R.mul_base(r_prime), R.mul(y3, r.d1), R.mul(y4, r.e1)])
      s2 = Proof.sum([R.mul(r_prime, r.y_point), v_prime, R.mul(y3, r.d2), R.mul(y4, r.e2)])

      points =
        Map.merge(classic_points(), %{
          c_w: key.c_w,
          g_v_minus_i: R.sub(G.get(:g_v), key.i),
          s1: s1,
          d1: r.d1,
          e1: r.e1,
          s2: s2,
          d2: r.d2,
          e2: r.e2,
          y_point: r.y_point,
          u: u,
          t_u: R.mul(t, u),
          m1: m1,
          m2: m2,
          m5: m5
        })

      scalars = %{
        w: key.w,
        w2: key.w2,
        x0: key.x0,
        x1: key.x1,
        y1: y1,
        y2: y2,
        y3: y3,
        y4: y4,
        y5: y5,
        r_prime: r_prime
      }

      proof = Proof.prove(@issue_statement, scalars, points, "", proof_randomness)

      {:ok,
       IO.iodata_to_binary([
         0,
         t,
         u,
         s1,
         s2,
         <<expiration::little-64>>,
         <<352::little-64>>,
         proof
       ])}
    end
  end

  @doc false
  # Server side: the request proof must verify against the stored commitment.
  def verify_request(
        <<0, y_point::binary-size(32), d1::binary-size(32), d2::binary-size(32),
          e1::binary-size(32), e2::binary-size(32), 160::little-64, proof::binary-size(160)>>,
        <<0, j1::binary-size(32), j2::binary-size(32), j3::binary-size(32)>>
      ) do
    if Enum.all?([y_point, d1, d2, e1, e2, j1, j2, j3], &R.valid?/1) do
      points =
        Map.merge(classic_points(), %{
          y_point: y_point,
          d1: d1,
          e1: e1,
          j3_point: j3,
          d2_minus_j1: R.sub(d2, j1),
          neg_g_j1: R.sub(R.identity(), G.get(:g_j1)),
          e2_minus_j2: R.sub(e2, j2),
          neg_g_j2: R.sub(R.identity(), G.get(:g_j2))
        })

      if Proof.verify(@request_statement, points, "", proof),
        do: {:ok, %{y_point: y_point, d1: d1, d2: d2, e1: e1, e2: e2}},
        else: {:error, :invalid}
    else
      {:error, :invalid}
    end
  end

  def verify_request(_request, _commitment), do: {:error, :invalid}

  @doc false
  # Server side (section 14.5): valid strictly before the expiration.
  def verify(%ServerParams.Secret{classic: classic}, group_public, presentation, now) do
    key = classic.profile_key

    with <<@presentation_version, c_x0::binary-size(32), c_x1::binary-size(32),
           c_y1::binary-size(32), c_y2::binary-size(32), c_y3::binary-size(32),
           c_y4::binary-size(32), c_y5::binary-size(32), c_v::binary-size(32), 320::little-64,
           proof::binary-size(320), e_a1::binary-size(32), e_a2::binary-size(32),
           e_b1::binary-size(32), e_b2::binary-size(32), expiration::little-64>> <- presentation,
         true <- now < expiration,
         true <-
           Enum.all?(
             [c_x0, c_x1, c_y1, c_y2, c_y3, c_y4, c_y5, c_v, e_a1, e_a2, e_b1, e_b2],
             &R.valid?/1
           ),
         {:ok, {_gid, a, b}} <- Params.decode_public_params(group_public) do
      [y1, y2, y3, y4, y5] = key.ys

      zp =
        Proof.sum([
          c_v,
          R.sub(R.identity(), key.big_w),
          R.sub(R.identity(), R.mul(key.x0, c_x0)),
          R.sub(R.identity(), R.mul(key.x1, c_x1)),
          R.sub(R.identity(), R.mul(y1, c_y1)),
          R.sub(R.identity(), R.mul(y2, c_y2)),
          R.sub(R.identity(), R.mul(y3, c_y3)),
          R.sub(R.identity(), R.mul(y4, c_y4)),
          R.sub(R.identity(), R.mul(y5, R.add(c_y5, m5(expiration))))
        ])

      points =
        presentation_points(%{
          zp: zp,
          i: key.i,
          c_x0: c_x0,
          c_x1: c_x1,
          a_plus_b: R.add(a, b),
          c_y1: c_y1,
          c_y2: c_y2,
          c_y3: c_y3,
          c_y4: c_y4,
          c_y5: c_y5,
          e_a1: e_a1,
          e_a2: e_a2,
          e_b1: e_b1,
          e_b2: e_b2
        })

      Proof.verify(@present_statement, points, "", proof)
    else
      _ -> false
    end
  end
end
