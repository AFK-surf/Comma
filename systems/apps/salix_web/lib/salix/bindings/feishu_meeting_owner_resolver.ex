defmodule Salix.Bindings.FeishuMeetingOwnerResolver do
  @moduledoc false

  require Logger

  @max_pages 8
  @page_size 50
  @max_members @max_pages * @page_size
  @max_name_graphemes 100
  @default_deadline_ms 10_000
  @open_id ~r/\Aou_[A-Za-z0-9_-]{1,128}\z/

  @type resolution :: %{optional(non_neg_integer()) => map()}

  @doc false
  @spec resolve(map(), [term()], keyword()) :: {:ok, resolution()} | {:error, term()}
  def resolve(state, action_items, opts \\ [])

  def resolve(state, action_items, opts) when is_map(state) and is_list(action_items) do
    case resolve_with_roster(state, action_items, opts) do
      {:ok, %{mapping: mapping}} -> {:ok, mapping}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_state, _action_items, _opts), do: {:ok, %{}}

  @doc false
  @spec resolve_with_roster(map(), [term()], keyword()) ::
          {:ok,
           %{
             mapping: resolution(),
             roster: [map()],
             blocked_owner_indices: [non_neg_integer()]
           }}
          | {:error, term()}
  def resolve_with_roster(state, action_items, opts \\ [])

  def resolve_with_roster(state, action_items, opts)
      when is_map(state) and is_list(action_items) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    result =
      run_with_deadline(
        fn ->
          with {:ok, connect} <- connect(state, opts),
               :ok <- validate_bot_identity(state, connect),
               {:ok, members} <- members(state, connect, opts) do
            members = exclude_bot_identity(members, connect)
            {:ok, resolve_members_with_context(action_items, members)}
          end
        end,
        deadline_ms
      )

    case result do
      {:ok, %{mapping: resolved} = context} ->
        Logger.info(
          "meeting_feishu_owner_resolution outcome=complete resolved_count=#{map_size(resolved)}"
        )

        {:ok, context}

      {:error, {:provider_error, reason}} ->
        Logger.warning(
          "meeting_feishu_owner_resolution outcome=retryable error_class=#{error_class(reason)}"
        )

        {:error, {:provider_owner_lookup, reason}}

      {:error, reason} ->
        Logger.info(
          "meeting_feishu_owner_resolution outcome=unresolved reason=#{terminal_reason(reason)} resolved_count=0"
        )

        {:ok, empty_context()}
    end
  end

  def resolve_with_roster(_state, _action_items, _opts),
    do: {:ok, empty_context()}

  defp run_with_deadline(fun, timeout)
       when is_function(fun, 0) and is_integer(timeout) and timeout > 0 do
    task =
      Task.async(fn ->
        try do
          {:result, fun.()}
        rescue
          exception -> {:lookup_crash, {:exception, exception.__struct__}}
        catch
          kind, reason -> {:lookup_crash, {kind, error_class(reason)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:result, result}} -> result
      {:ok, {:lookup_crash, reason}} -> {:error, {:provider_error, {:lookup_crash, reason}}}
      {:exit, reason} -> {:error, {:provider_error, {:lookup_exit, error_class(reason)}}}
      nil -> {:error, :lookup_deadline_exceeded}
    end
  end

  defp run_with_deadline(_fun, _timeout), do: {:error, :invalid_lookup_deadline}

  @doc false
  def collect_pages(fetch_page, max_pages \\ @max_pages)
      when is_function(fetch_page, 1) and is_integer(max_pages) and max_pages > 0 do
    do_collect_pages(fetch_page, nil, MapSet.new(), [], 1, min(max_pages, @max_pages))
  end

  @doc false
  def resolve_members(action_items, members)
      when is_list(action_items) and is_list(members) do
    action_items
    |> resolve_members_with_context(members)
    |> Map.fetch!(:mapping)
  end

  def resolve_members(_action_items, _members), do: %{}

  @doc false
  def resolve_members_with_context(action_items, members)
      when is_list(action_items) and is_list(members) do
    %{eligible: eligible, blocked_names: blocked_names} = member_analysis(members)

    %{
      mapping: resolve_members_from_rows(action_items, eligible),
      roster: roster_from_rows(eligible),
      blocked_owner_indices: blocked_owner_indices(action_items, blocked_names)
    }
  end

  def resolve_members_with_context(_action_items, _members), do: empty_context()

  @doc false
  def eligible_roster(members) when is_list(members) do
    members
    |> eligible_member_rows()
    |> roster_from_rows()
  end

  def eligible_roster(_members), do: []

  defp members(state, connect, opts) do
    case trim(get_in(state, ["feishu_ref", "chat_type"])) do
      "group" -> group_members(state, connect, opts)
      "p2p" -> p2p_member(state, connect, opts)
      _ -> {:error, :invalid_chat_type}
    end
  end

  defp group_members(state, connect, opts) do
    chat_id = trim(get_in(state, ["feishu_ref", "chat_id"]))

    if chat_id == "" do
      {:error, :missing_chat_id}
    else
      fetch_page =
        Keyword.get_lazy(opts, :fetch_page, fn ->
          fn page_token ->
            params =
              %{"chat_id" => chat_id, "page_size" => @page_size}
              |> maybe_put("page_token", page_token)

            SalixIM.Provider.Feishu.call(nil, connect, "feishu.list_chat_members", params)
          end
        end)

      collect_pages(fetch_page)
    end
  end

  defp p2p_member(state, connect, opts) do
    sender_open_id = trim(get_in(state, ["source", "sender_open_id"]))

    if valid_open_id?(sender_open_id) do
      fetch_user =
        Keyword.get_lazy(opts, :fetch_user, fn ->
          fn user_id ->
            SalixIM.Provider.Feishu.call(
              nil,
              connect,
              "feishu.get_user",
              %{"user_id" => user_id, "user_id_type" => "open_id"}
            )
          end
        end)

      case fetch_user.(sender_open_id) do
        {:ok, %{"user" => user}} ->
          if verified_p2p_user?(user, sender_open_id),
            do: {:ok, [user]},
            else: {:error, :sender_identity_mismatch}

        {:ok, _unexpected} ->
          {:error, :invalid_user_response}

        {:error, reason} ->
          {:error, {:provider_error, reason}}

        other ->
          {:error, {:invalid_user_response, error_class(other)}}
      end
    else
      {:error, :missing_or_invalid_sender_open_id}
    end
  end

  defp connect(state, opts) do
    case Keyword.get(opts, :connect) do
      %{} = connect ->
        {:ok, connect}

      nil ->
        case SalixIM.ProviderConnects.get_active_connect_by_id(
               trim(state["group_id"]),
               trim(state["connect_id"]),
               "feishu"
             ) do
          {:ok, connect} -> {:ok, connect}
          {:error, reason} -> {:error, {:provider_error, reason}}
        end

      _ ->
        {:error, :invalid_connect}
    end
  end

  defp do_collect_pages(_fetch_page, _token, _seen, members, page, max_pages)
       when page > max_pages do
    if length(members) <= @max_members,
      do: {:error, :pagination_budget_exhausted},
      else: {:error, :member_budget_exhausted}
  end

  defp do_collect_pages(fetch_page, token, seen, members, page, max_pages) do
    case fetch_page.(token) do
      {:ok, result} when is_map(result) ->
        collect_page_result(fetch_page, token, seen, members, page, max_pages, result)

      {:error, reason} ->
        {:error, {:provider_error, reason}}

      other ->
        {:error, {:invalid_member_page, error_class(other)}}
    end
  end

  defp collect_page_result(fetch_page, token, seen, members, page, max_pages, result) do
    page_members = result["members"]

    with true <- is_list(page_members),
         true <- length(page_members) <= @page_size,
         combined <- members ++ page_members,
         true <- length(combined) <= @max_members do
      case result["has_more"] do
        true ->
          next_token = trim(result["next_page_token"])

          cond do
            page >= max_pages ->
              {:error, :pagination_budget_exhausted}

            next_token == "" ->
              {:error, :missing_next_page_token}

            next_token == token or MapSet.member?(seen, next_token) ->
              {:error, :non_progressing_page_token}

            true ->
              do_collect_pages(
                fetch_page,
                next_token,
                MapSet.put(seen, next_token),
                combined,
                page + 1,
                max_pages
              )
          end

        false ->
          {:ok, combined}

        _invalid ->
          {:error, :invalid_has_more}
      end
    else
      false -> {:error, :invalid_or_oversized_page}
    end
  end

  defp member_row(%{} = member) do
    name = trusted_name(member)
    %{user_id: trusted_user_id(member), name: name, normalized_name: normalize_name(name)}
  end

  defp member_row(_member), do: %{user_id: "", name: "", normalized_name: ""}

  defp exclude_bot_identity(members, connect) do
    bot_open_id = trim(connect["bot_open_id"])
    Enum.reject(members, &(trusted_user_id(&1) == bot_open_id))
  end

  defp eligible_member_rows(members) do
    members
    |> member_analysis()
    |> Map.fetch!(:eligible)
  end

  defp member_analysis(members) do
    rows = Enum.map(members, &member_row/1)

    conflicting_ids =
      rows
      |> Enum.filter(&(&1.user_id != "" and &1.normalized_name != ""))
      |> Enum.group_by(& &1.user_id, & &1.normalized_name)
      |> Enum.reduce(MapSet.new(), fn {user_id, names}, acc ->
        if names |> Enum.uniq() |> length() > 1,
          do: MapSet.put(acc, user_id),
          else: acc
      end)

    candidates =
      rows
      |> Enum.reject(&(&1.normalized_name == ""))
      |> Enum.group_by(& &1.normalized_name)
      |> Map.new(fn {name, bucket} -> {name, unique_member(bucket, conflicting_ids)} end)

    eligible =
      rows
      |> Enum.map(&Map.get(candidates, &1.normalized_name))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.user_id)

    observed_names =
      rows
      |> Enum.map(& &1.normalized_name)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    eligible_names = MapSet.new(eligible, & &1.normalized_name)

    %{
      eligible: eligible,
      blocked_names: MapSet.difference(observed_names, eligible_names)
    }
  end

  defp resolve_members_from_rows(action_items, eligible) do
    candidates = Map.new(eligible, &{&1.normalized_name, &1})

    action_items
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {item, index}, acc ->
      owner = owner_name(item)

      case Map.get(candidates, normalize_name(owner)) do
        %{user_id: user_id, name: name} when owner != "" ->
          Map.put(acc, index, %{
            "provider" => "feishu",
            "user_id" => user_id,
            "display_name" => name
          })

        _unresolved_or_ambiguous ->
          acc
      end
    end)
  end

  defp roster_from_rows(rows) do
    Enum.map(rows, fn member ->
      %{"user_id" => member.user_id, "display_name" => member.name}
    end)
  end

  defp blocked_owner_indices(action_items, blocked_names) do
    action_items
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, index}, acc ->
      if MapSet.member?(blocked_names, normalize_name(owner_name(item))),
        do: [index | acc],
        else: acc
    end)
    |> Enum.reverse()
  end

  defp validate_bot_identity(state, connect) do
    case trim(get_in(state, ["feishu_ref", "chat_type"])) do
      "group" ->
        if valid_open_id?(connect["bot_open_id"]),
          do: :ok,
          else: {:error, :missing_or_invalid_bot_open_id}

      _ ->
        :ok
    end
  end

  defp empty_context do
    %{mapping: %{}, roster: [], blocked_owner_indices: []}
  end

  defp unique_member(bucket, conflicting_ids) do
    ids = Enum.map(bucket, & &1.user_id)
    unique_ids = ids |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    cond do
      Enum.any?(ids, &(&1 == "")) ->
        nil

      length(unique_ids) != 1 ->
        nil

      MapSet.member?(conflicting_ids, hd(unique_ids)) ->
        nil

      true ->
        %{
          user_id: hd(unique_ids),
          name: hd(bucket).name,
          normalized_name: hd(bucket).normalized_name
        }
    end
  end

  defp trusted_user_id(member) do
    ids =
      [member["member_id"], member["open_id"]]
      |> Enum.map(&trim/1)
      |> Enum.reject(&(&1 == ""))

    if ids != [] and Enum.all?(ids, &valid_open_id?/1) and length(Enum.uniq(ids)) == 1,
      do: hd(ids),
      else: ""
  end

  defp verified_p2p_user?(%{} = user, sender_open_id) do
    open_id = trim(user["open_id"])

    open_id == sender_open_id and valid_open_id?(open_id)
  end

  defp verified_p2p_user?(_user, _sender_open_id), do: false

  defp trusted_name(member) do
    name = trim(member["name"])

    if name != "" and String.length(name) <= @max_name_graphemes,
      do: name,
      else: ""
  end

  defp owner_name(%{} = item),
    do: trim(item["owner"] || item["assignee"] || item["owner_name"])

  defp owner_name(_item), do: ""

  defp normalize_name(name) do
    name = trim(name)

    if String.length(name) <= @max_name_graphemes do
      name
      |> String.normalize(:nfkc)
      |> :string.casefold()
    else
      ""
    end
  end

  defp valid_open_id?(value), do: is_binary(value) and Regex.match?(@open_id, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp terminal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp terminal_reason(_reason), do: "invalid_provider_response"

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_class(reason) when is_binary(reason), do: "provider_error"
  defp error_class(_reason), do: "unknown"

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)

  defp trim(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  defp trim(_value), do: ""
end
