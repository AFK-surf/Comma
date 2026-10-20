defmodule SalixAgent.Tailnet.Config do
  @moduledoc """
  The Group's tailnet settings: whether the Group has a tailnet node, the
  tags it requests, whether it uses approved subnet routes, and the tailnet
  it must join.

  One JSON record per Group at `SalixStore.Keys.ctl_group_tailnet_config/1`,
  changed only by compare-and-swap. Every change that affects the node
  increments `generation`; an owner that sees a new generation applies it.
  The settings come from the Comma app, the BFT dashboard, the Salix
  dashboard or the Group's router Agent; `updated_by` records which.
  """

  alias SalixStore.{CasRecord, Keys}

  @default_tags ["tag:comma-agent"]
  @max_tags 8
  @tag ~r/\Atag:[A-Za-z][A-Za-z0-9-]{0,62}\z/
  @max_tailnet_bytes 253

  @type t :: %{required(String.t()) => term()}

  @doc "Tags a new Group node requests."
  def default_tags, do: @default_tags

  @doc "The settings, or the defaults of a Group that never connected."
  @spec get(String.t()) :: {:ok, t()} | {:error, term()}
  def get(group_id) when is_binary(group_id) do
    case CasRecord.get(Keys.ctl_group_tailnet_config(group_id)) do
      {:ok, record} -> {:ok, normalize(record)}
      {:error, :not_found} -> {:ok, defaults()}
      {:error, reason} -> {:error, {:tailnet_config_unavailable, reason}}
    end
  end

  @doc """
  Enable the Group's node with `attrs` (`"tags"`, `"accept_routes"`,
  `"expected_tailnet"`; a missing key keeps its value). The generation
  changes only when the node must change: it was disabled, or a setting
  differs.
  """
  @spec enable(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def enable(group_id, attrs, actor) when is_binary(group_id) and is_map(attrs) do
    with {:ok, current} <- get(group_id),
         {:ok, settings} <- settings(current, attrs) do
      update(group_id, fn record ->
        record = normalize(record || %{})
        next = Map.merge(record, Map.put(settings, "enabled", true))

        if next == record,
          do: {:unchanged, record},
          else: changed(next, record, actor)
      end)
    end
  end

  @doc "Disable the Group's node. Its owner logs it out of the tailnet."
  @spec disable(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def disable(group_id, actor) when is_binary(group_id) do
    update(group_id, fn
      nil ->
        {:unchanged, defaults()}

      record ->
        record = normalize(record)

        if record["enabled"],
          do: changed(Map.put(record, "enabled", false), record, actor),
          else: {:unchanged, record}
    end)
  end

  @doc false
  def delete(group_id), do: SalixStore.S3.delete(Keys.ctl_group_tailnet_config(group_id))

  @doc "The settings a node uses, for comparing two generations."
  def node_settings(config),
    do: Map.take(config, ["enabled", "tags", "accept_routes", "expected_tailnet"])

  defp update(group_id, fun) do
    case CasRecord.update(Keys.ctl_group_tailnet_config(group_id), fun) do
      {:ok, record} -> {:ok, normalize(record)}
      {:error, reason} -> {:error, {:tailnet_config_unavailable, reason}}
    end
  end

  defp changed(next, previous, actor) do
    Map.merge(next, %{
      "generation" => previous["generation"] + 1,
      "updated_by" => actor,
      "updated_at" => DateTime.to_iso8601(SystemsClock.utc_now())
    })
  end

  defp defaults do
    %{
      "enabled" => false,
      "tags" => @default_tags,
      "accept_routes" => false,
      "expected_tailnet" => nil,
      "generation" => 0,
      "updated_by" => nil,
      "updated_at" => nil
    }
  end

  defp normalize(record), do: Map.merge(defaults(), Map.take(record, Map.keys(defaults())))

  defp settings(current, attrs) do
    with {:ok, tags} <- tags(Map.get(attrs, "tags", current["tags"])),
         {:ok, routes} <- boolean(Map.get(attrs, "accept_routes", current["accept_routes"])),
         {:ok, tailnet} <-
           tailnet(Map.get(attrs, "expected_tailnet", current["expected_tailnet"])) do
      {:ok, %{"tags" => tags, "accept_routes" => routes, "expected_tailnet" => tailnet}}
    end
  end

  defp tags(tags) when is_list(tags) and length(tags) <= @max_tags do
    tags = tags |> Enum.map(&if(is_binary(&1), do: String.trim(&1), else: &1)) |> Enum.uniq()

    if Enum.all?(tags, &(is_binary(&1) and Regex.match?(@tag, &1))),
      do: {:ok, Enum.sort(tags)},
      else: {:error, :invalid_tags}
  end

  defp tags(_tags), do: {:error, :invalid_tags}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_accept_routes}

  defp tailnet(nil), do: {:ok, nil}

  defp tailnet(value) when is_binary(value) do
    case value |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> {:ok, nil}
      name when byte_size(name) <= @max_tailnet_bytes -> {:ok, name}
      _long -> {:error, :invalid_expected_tailnet}
    end
  end

  defp tailnet(_value), do: {:error, :invalid_expected_tailnet}
end
