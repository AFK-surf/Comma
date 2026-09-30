defmodule SalixSignalProto.Group.Generators do
  @moduledoc """
  The fixed generator points of the group credential system (CRS-09a
  section 4).

  The values are interoperability constants. `derive/0` recomputes every
  table from its ASCII label with `SalixSignalProto.Group.Sho`; the tests
  check that the derivation gives these constants.

  | Name | Table |
  | --- | --- |
  | `:g_a1`, `:g_a2` | UID encryption (4.1) |
  | `:g_b1`, `:g_b2` | Profile key encryption (4.1) |
  | `:g_j1`, `:g_j2`, `:g_j3` | Profile key commitment (4.1) |
  | `:g_w` … `:g_m5` | Classic credential table (4.2) |
  | `:h_w` … `:h_y6` | Generic credential table (4.3) |
  """

  alias SalixSignalProto.Group.Sho

  @uid_label "Signal_ZKGroup_20200424_Constant_UidEncryption_SystemParams_Generate"
  @profile_key_label "Signal_ZKGroup_20200424_Constant_ProfileKeyEncryption_SystemParams_Generate"
  @commitment_label "Signal_ZKGroup_20200424_Constant_ProfileKeyCommitment_SystemParams_Generate"
  @classic_label "Signal_ZKGroup_20200424_Constant_Credentials_SystemParams_Generate"
  @generic_label "Signal_ZKCredential_ConstantSystemParams_generate_20230410"

  @uid [:g_a1, :g_a2]
  @profile_key [:g_b1, :g_b2]
  @commitment [:g_j1, :g_j2, :g_j3]
  @classic [
    :g_w,
    :g_w2,
    :g_x0,
    :g_x1,
    :g_y1,
    :g_y2,
    :g_y3,
    :g_y4,
    :g_m1,
    :g_m2,
    :g_m3,
    :g_m4,
    :g_v,
    :g_z,
    :g_y5,
    :g_y6,
    :g_m5
  ]
  @generic [
    :h_w,
    :h_w2,
    :h_x0,
    :h_x1,
    :h_v,
    :h_z,
    :h_y0,
    :h_y1,
    :h_y2,
    :h_y3,
    :h_y4,
    :h_y5,
    :h_y6
  ]

  @points %{
    g_a1: "a6324c368df734691147981348b6e7eb42c3307e711b6c7eccd3032d45693f5a",
    g_a2: "048013525b76124bf2640c5e9369c76efbe80aba2a24aa5d8e18a98eba14f837",
    g_b1: "f6baa317ce1839c93d617e0cd837d19da9c8a4c520bf7c51b1e6c2cb2a049c61",
    g_b2: "2e0175894c8730b203ab3bd98ecb2d81abacb65f8a6124f49771d14a9852120c",
    g_j1: "a8ca0bbd1148c466725860640ac53d2772b14eeae0170a38c62c7b3dd29c3e4a",
    g_j2: "14b9462d948f059450799f4cc2a06e55dec807735670b94a5ce80f59f1950861",
    g_j3: "b0c0f7b91f6ef9c7556093d8930a86bd36188cec740554657d92dcd86aad251c",
    g_w: "9ae7c8e5ed779b114ae7708aa2f794670adda324987b659913122c35505b105e",
    g_w2: "6ca31025d2d76be7fd34944f98f7fa0e37babb2c8b98bbbdbd3dd1bf130cca2c",
    g_x0: "8a9a3bdfaaa2b6b322d46b93eca7b0d51c86a3c839e11466358258a6c10c577f",
    g_x1: "c2bffd34cd99164c9a6cd29fab55d91ff9269322ec3458603cc96a0d47f70405",
    g_y1: "8288f62ee0acedb8aa23242121d98965a9bb2991250c11758095ece0fd2b3328",
    g_y2: "5286fe1fcb056103b6081744b975f550d08521568dd3d8618f25c140375a0f40",
    g_y3: "24c3aa23bdfffb27fbd982208d3ecd1fd3bcb7ac0c3a14b109804fc748d7fa45",
    g_y4: "6cffb4934f980b6e09a248a60f44a6150ae6c13d7e3c06261d7e4eed37f39f60",
    g_m1: "cc6037dc31c2e8d4474fb519587a448693182ad9d6d86b535957858f547b9340",
    g_m2: "127da75f8074caee944ac36c0ac662d38c9b3ccce03a093fcd9644047398b86b",
    g_m3: "6e83372ff14fb8bb0dea65531252ac70d58a4a0810d682a0e709c9227b30ef6c",
    g_m4: "8e17c5915d527221bb00da8175cd6489aa8aa492a500f9abee5690b9dfca8855",
    g_v: "04b616c706c80c756c11a3016bbfb60977f4648b5f2395a4b428b7211940813e",
    g_z: "3afde2b87aa9c2c37bf716e2578f95656df12c2fb6f5d0631f6f71e2c3193f6d",
    g_y5: "b04dd9d607fd357012274d3c63dbb38e7378599c9e97dfbb28842694891d5f0d",
    g_y6: "dc729919b798b4131503408cc57a9c532f4427632c88f54cea53861a5bc44c61",
    g_m5: "dc0bd02a7f277add240f639ac16801e81574afb4683edff63b9a01e93dbd867a",
    h_w: "589c8718e8263a53a78932b6212a46e7fd52de3ad157b5bb277dba494cfd3471",
    h_w2: "d4cc5f90685952917b33366efcce0512a1f8d70f974758266cb04fc424346d37",
    h_x0: "b20f49cb2a081c94b1771fd8c172ae21785c61ea2c7e31947ce351e7b5ff0702",
    h_x1: "8c5329beb87b317ffcd981e440819d91136c988d6d9fbea4a87e55ed24a5993a",
    h_v: "a02f688ab1d3bd19056f94c8a44b8faddfa3c9c79c95ad44311a7bf00e5e862e",
    h_z: "c2c399f0d689dfb8c2dc0d7caba32afcf58cf0d85f78195a0b5ab732f5655954",
    h_y0: "92cfd982321d1f9be4b21fe6a0214306023d6a05d0d23f67ddc1c0400e5e0a5e",
    h_y1: "92d17595131b7a095e740b884b8c9bb0226a39cfd027c769c4f4677c51f21b24",
    h_y2: "da81fb2bd1356a9d0650f6a63fcc90d93bd74a954ba6f75f0e9fca47a6d21734",
    h_y3: "bce7b28f06b76ef2c44d20a07026534e586eb8e1038874a93e44de362ce7bc08",
    h_y4: "44bffc88e390c62519e281aa6fd53ff9ddd1d9ba303cf70004278ea2ae66ce05",
    h_y5: "a2749d29eba56f3efe99e42902825c473dfc3c154c3762d2e76bd103f629d250",
    h_y6: "b2d9d5c243a4cf8f3be21a84f153f44e2733a105cf780a20f03d84fe1ebbeb0e"
  }

  @decoded Map.new(@points, fn {name, hex} -> {name, Base.decode16!(hex, case: :lower)} end)

  @doc "The generator point called `name` (32-byte encoding)."
  @spec get(atom()) :: <<_::256>>
  def get(name), do: Map.fetch!(@decoded, name)

  @doc "All generator points by name."
  @spec all() :: %{atom() => <<_::256>>}
  def all, do: @decoded

  @doc """
  Recomputes every table from its label (CRS-09a sections 4.1 to 4.3).
  Returns a map with the same keys as `all/0`.
  """
  @spec derive() :: %{atom() => <<_::256>>}
  def derive do
    [
      {Sho.derive(@uid_label, ""), @uid},
      {Sho.derive(@profile_key_label, ""), @profile_key},
      {Sho.derive(@commitment_label, ""), @commitment},
      {Sho.derive(@classic_label, ""), @classic},
      {Sho.new_sha256(@generic_label), @generic}
    ]
    |> Enum.flat_map(fn {state, names} ->
      {points, _state} =
        Enum.map_reduce(names, state, fn _name, s -> Sho.squeeze_point(s) end)

      Enum.zip(names, points)
    end)
    |> Map.new()
  end
end
