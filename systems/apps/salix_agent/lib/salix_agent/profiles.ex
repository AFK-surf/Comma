defmodule SalixAgent.Profiles do
  @moduledoc """
  The Profiles' logic Comma and its stations share (systems/profiles): the
  sources, which Profiles serve a request and in what order, and how a runtime
  is given a Profile. Salix keeps the Profiles: an AccountPool record is the
  Profile as stored, with the server's own fields beside it.
  """

  alias SalixAgent.Profiles.Native

  @doc "The sources, in the order they are offered (sources.json)."
  def sources, do: Jason.decode!(Native.sources_json())

  @doc """
  The AccountPool records that serve a request, best first. `opts`: `:model`
  (the catalog model asked for), `:provider_model` (the id the provider is
  asked for it by, what a window of one model counts for) and `:now` (ms since
  the epoch).
  """
  def rank(records, opts \\ []) when is_list(records) do
    profiles = Enum.map(records, &profile/1)

    request = %{
      "model" => blank(opts[:model]),
      "provider_model" => blank(opts[:provider_model]),
      # None that serves it is none: the request moves to another source.
      "strict" => true,
      "keep_unusable" => false,
      "now" => opts[:now] || SystemsClock.system_time(:millisecond)
    }

    case Native.rank_json(Jason.encode!(profiles), Jason.encode!(request)) do
      {:ok, ids} ->
        by_id = Map.new(records, &{&1["id"], &1})
        Enum.map(ids, &Map.fetch!(by_id, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc "What a model is, however it is spelled."
  def model_key(spelled) when is_binary(spelled), do: Native.model_key_of(spelled)

  @doc """
  Whether an account has a window used up that has not refilled, of the whole
  account (a window of one model counts for that model only).
  """
  def exhausted?(record) do
    profile = record |> profile() |> Map.merge(%{"status" => "ok", "disabled" => false})

    case Native.usable_json(Jason.encode!(profile), "", SystemsClock.system_time(:millisecond)) do
      {:ok, usable} -> not usable
      {:error, _} -> false
    end
  end

  # The Profile's fields: an AccountPool record is stored as the Profile, with
  # the server's own fields beside it (sealed credentials, versions, email).
  @profile_fields ~w(id name source credential runtime endpoint protocol auth models disabled_models model env disabled status quota cooldown_until)

  @doc "An AccountPool record as the Profile the shared logic takes."
  def profile(record) do
    record
    |> Map.take(@profile_fields)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> listed()
  end

  # A Custom Profile lists what its endpoint serves; a catalog source or a plan
  # serves its catalog models, so it lists none here.
  defp listed(
         %{"source" => "custom", "credential" => "api_key", "models" => [_ | _] = models} = p
       ),
       do: Map.put(p, "models", Enum.flat_map(models, &model_id/1))

  defp listed(p), do: Map.delete(p, "models")

  defp model_id(id) when is_binary(id), do: [id]
  defp model_id(%{"id" => id}) when is_binary(id), do: [id]
  defp model_id(_), do: []

  @doc """
  A provider's answer about an account's allowance (what account-proxy read
  for it) as the Profile's quota.
  """
  def quota(provider, body) when is_binary(provider) do
    {:ok, json} =
      Native.quota_json(provider, Jason.encode!(body), SystemsClock.system_time(:millisecond))

    Jason.decode!(json)
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
