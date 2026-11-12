defmodule SalixIM.Provider.Feishu.Directory do
  @moduledoc """
  Finds people by name in the app's Feishu Contacts data range.

  A tenant app cannot use Feishu's keyword user search. `lookup/4` first
  matches the stored copy of the data range (`DirectorySnapshot`), which
  needs no directory request; a person added after its last sync is not in
  it, so when nobody there matches, `lookup/4` reads the directory itself:
  the data range roots (`/contact/v3/scopes`), every department under them
  (`fetch_child=true`), and each department's direct members
  (`find_by_department`). It matches name, English name, nickname, email and
  employee number, and names each person's departments. The members of up
  to 8 departments are read at once, and their people are taken in the
  data range's order, so the answer does not depend on which read ends
  first. One search makes at most 120 directory requests and stops when it
  has `limit` people; the result says whether it read the whole data range.
  When several people match, or the search stopped early, the result asks
  the Agent to confirm with the requester which person is meant.

  `list/2` reads the same data range for everyone in it, a bounded part per
  call: at most 120 directory requests, whole departments only (a
  department's members are read in one call or not at all). While the range
  is not finished it answers `continue_from`, the position of the next
  department in the walk's order (data range root, then the department's
  place in that root's listing) with the ids found there, so a later call
  goes on from it and reads no finished department again. A position whose
  ids no longer match means the range changed: the call says to start again.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2]

  alias SalixIM.Provider.Feishu.{API, DirectorySnapshot}

  @max_requests 120
  @page_size 50
  # A name search reads the first member page of this many departments at
  # once. A read that does not answer in time leaves the search incomplete.
  @concurrency 8
  @read_timeout_ms 15_000
  @read_timeout "A Feishu Contacts read took over #{div(@read_timeout_ms, 1_000)} seconds."
  @members_path "/contact/v3/users/find_by_department"
  @stored_note "These people come from the stored copy of the Contacts data range, read whole at synced_at (Unix milliseconds); complete is false when more people match than limit. A person added after synced_at is not in it: when none of these is the person meant, walk the directory with feishu.list_departments and feishu.list_department_users."
  @matched_fields ~w(name en_name nickname email enterprise_email employee_no)
  @kept_fields ~w(open_id union_id user_id name en_name nickname email enterprise_email
                  employee_no job_title department_ids)
  @listed_fields ~w(name en_name email enterprise_email employee_no job_title open_id)
  @start %{
    "v" => 1,
    "r" => 0,
    "root" => nil,
    "d" => 0,
    "id" => nil,
    "u" => 0,
    "uid" => nil,
    "n" => 0
  }

  @doc """
  The answer of `feishu.lookup_users`: the people the bot has seen that match
  `query` (`observed`), then the matches from the directory: from its stored
  copy when anyone there matches, else from a walk of the directory. A blank
  query reads no directory. A missing or old stored copy is synced again in
  the background (`DirectorySnapshot.refresh_if_due/2`).
  """
  @spec lookup(map(), [map()], term(), term()) :: map()
  def lookup(connect, observed, query, limit) do
    limit = limit(limit)
    observed = Enum.map(observed, &Map.put(&1, "source", "observed"))
    needle = query |> str() |> String.trim() |> String.downcase()

    cond do
      needle == "" ->
        %{
          "users" => observed,
          "directory" => %{
            "searched" => false,
            "note" => "Give a query (a name, English name or email) to search the directory."
          }
        }

      length(observed) >= limit ->
        %{
          "users" => Enum.take(observed, limit),
          "directory" => %{
            "searched" => false,
            "note" =>
              "The people the bot has seen already reached limit; raise limit to search the directory too."
          }
        }

      true ->
        stored_or_live(connect, observed, needle, limit)
    end
  end

  # The stored copy answers when anyone in it matches. A miss walks the
  # directory, so a person added after the last sync is still found.
  defp stored_or_live(connect, observed, needle, limit) do
    snapshot = DirectorySnapshot.read(connect)
    DirectorySnapshot.refresh_if_due(connect, snapshot)

    case stored_matches(snapshot, needle) do
      [] -> directory_lookup(connect, observed, needle, limit)
      matches -> stored_lookup(observed, matches, snapshot, limit)
    end
  end

  defp stored_matches(%{"people" => people}, needle) when is_list(people),
    do: Enum.filter(people, &(is_map(&1) and matches?(&1, needle)))

  defp stored_matches(_snapshot, _needle), do: []

  defp stored_lookup(observed, matches, snapshot, limit) do
    known = MapSet.new(observed, &str(&1["open_id"]))

    found =
      matches
      |> Enum.reject(&MapSet.member?(known, str(&1["open_id"])))
      |> Enum.map(&Map.put(&1, "source", "directory"))

    users = Enum.take(observed ++ found, limit)
    complete = length(observed) + length(found) <= limit

    %{
      "users" => users,
      "directory" => %{
        "searched" => true,
        "stored" => true,
        "synced_at" => snapshot["synced_at"],
        "complete" => complete,
        "note" => @stored_note
      }
    }
    |> confirm(users, complete)
  end

  defp directory_lookup(connect, observed, needle, limit) do
    case search(connect, needle, limit) do
      {:ok, %{"users" => found} = directory} ->
        known = MapSet.new(observed, &str(&1["open_id"]))

        found =
          found
          |> Enum.reject(&MapSet.member?(known, str(&1["open_id"])))
          |> Enum.map(&Map.put(&1, "source", "directory"))

        users = Enum.take(observed ++ found, limit)

        %{
          "users" => users,
          "directory" =>
            directory
            |> Map.delete("users")
            |> Map.put("searched", true)
            |> Map.put("note", note(users, directory))
        }
        |> confirm(users, directory["complete"])

      {:error, reason} ->
        %{
          "users" => observed,
          "directory" => %{
            "searched" => false,
            "error" => reason,
            "note" =>
              "The directory data range could not be read; the error says why. Only people the bot has seen were searched."
          }
        }
    end
  end

  defp confirm(result, users, _complete) when length(users) > 1,
    do:
      Map.put(
        result,
        "confirm",
        "#{length(users)} people match. Before you message or act on one of them, ask the requester which person they mean, naming each one's departments, job title and email."
      )

  defp confirm(result, [_user], false),
    do:
      Map.put(
        result,
        "confirm",
        "The search stopped before the whole data range was read, so other people may match too. Before you message or act on this person, confirm with the requester that they are the one meant."
      )

  defp confirm(result, _users, _complete), do: result

  defp note(_users, %{"complete" => false}),
    do:
      "The search did not read the whole data range: it reached limit or the request budget, or a read failed. More people may match; raise limit or walk the rest with feishu.list_departments and feishu.list_department_users before saying a person is absent."

  defp note([], _directory),
    do:
      "Nobody in the app's Contacts data range matches. That range is what feishu.list_contact_scopes names; people outside it are invisible to the app."

  defp note(_users, _directory), do: "Read the whole Contacts data range."

  defp limit(limit), do: limit |> int_or(50) |> min(100) |> max(1)

  defp search(connect, needle, limit) do
    with {:ok, roots, state} <- roots(connect, new_state()) do
      {users, state} = walk(connect, needle, limit, roots, state)
      users = Enum.map(users, &with_departments(&1, state.department_names))

      result = %{
        "users" => users,
        "complete" => state.complete and state.error == nil,
        "departments_read" => state.departments_read,
        "people_read" => state.people_read
      }

      {:ok, if(state.error, do: Map.put(result, "error", state.error), else: result)}
    end
  end

  defp new_state do
    %{
      requests: 0,
      complete: true,
      error: nil,
      department_names: %{},
      department_parents: %{},
      departments_read: 0,
      people_read: 0,
      seen: MapSet.new()
    }
  end

  # The data range roots: departments (`"0"` when the range is the whole
  # tenant) and people named one by one.
  defp roots(connect, state) do
    fold = fn data, acc ->
      %{
        departments: acc.departments ++ List.wrap(data["department_ids"]),
        users: acc.users ++ List.wrap(data["user_ids"])
      }
    end

    case pages(connect, "/contact/v3/scopes", %{}, state, %{departments: [], users: []}, fold) do
      {:ok, roots, state} -> {:ok, roots, state}
      {:error, reason, _state} -> {:error, reason}
    end
  end

  defp walk(connect, needle, limit, roots, state) do
    {found, state} = named_users(connect, needle, roots.users, [], state)

    roots.departments
    |> Enum.uniq()
    |> Enum.reduce_while({found, state}, fn department_id, {found, state} ->
      step(found, state, limit, fn ->
        department_tree(connect, needle, limit, department_id, found, state)
      end)
    end)
    |> then(fn {found, state} ->
      complete = state.complete and length(found) <= limit
      {Enum.take(found, limit), %{state | complete: complete}}
    end)
  end

  # Reads the next department unless the search already has `limit` people,
  # which leaves part of the data range unread, or ran out of requests.
  defp step(found, state, limit, _read) when length(found) >= limit,
    do: {:halt, {found, %{state | complete: false}}}

  defp step(found, %{complete: false} = state, _limit, _read), do: {:halt, {found, state}}
  defp step(_found, _state, _limit, read), do: {:cont, read.()}

  defp named_users(_connect, _needle, [], found, state), do: {found, state}

  defp named_users(connect, needle, [open_id | rest], found, state) do
    case request(connect, "/contact/v3/users/#{URI.encode_www_form(open_id)}", %{}, state) do
      {:ok, %{"user" => user}, state} ->
        {found, state} = consider(needle, [user], found, state)
        named_users(connect, needle, rest, found, state)

      {_result, _data, state} ->
        named_users(connect, needle, rest, found, state)
    end
  end

  defp with_departments(user, names) do
    departments =
      user["department_ids"]
      |> List.wrap()
      |> Enum.map(&names[&1])
      |> Enum.reject(&(&1 in [nil, ""]))

    Map.put(user, "departments", departments)
  end

  defp department_tree(connect, needle, limit, root_id, found, state) do
    state = root_name(connect, root_id, state)

    {departments, state} =
      case descendants(connect, root_id, state) do
        {:ok, departments, state} -> {departments, state}
        {:error, _reason, state} -> {[root_id], state}
      end

    read_members(connect, needle, limit, departments, found, state)
  end

  # The departments' members in listing order, a chunk at a time: the first
  # member page of up to @concurrency departments is read at once (one
  # request each, within the request budget), then each department of the
  # chunk is taken in order, its further pages read before the next one. The
  # search stops where `step/4` would stop it.
  defp read_members(_connect, _needle, _limit, [], found, state), do: {found, state}

  defp read_members(_connect, _needle, limit, _departments, found, state)
       when length(found) >= limit,
       do: {found, %{state | complete: false}}

  defp read_members(_connect, _needle, _limit, _departments, found, %{complete: false} = state),
    do: {found, state}

  # No request is left: the department's read finds the budget spent, as a
  # sequential walk's would.
  defp read_members(
         connect,
         needle,
         limit,
         [department_id | rest],
         found,
         %{requests: requests} = state
       )
       when requests >= @max_requests do
    {found, state} = department_members(connect, needle, department_id, found, state)
    read_members(connect, needle, limit, rest, found, state)
  end

  defp read_members(connect, needle, limit, departments, found, state) do
    {chunk, rest} = Enum.split(departments, min(@concurrency, @max_requests - state.requests))
    firsts = first_pages(connect, chunk)
    state = %{state | requests: state.requests + length(chunk)}

    case take_chunk(connect, needle, limit, Enum.zip(chunk, firsts), found, state) do
      {:cont, found, state} -> read_members(connect, needle, limit, rest, found, state)
      {:halt, found, state} -> {found, state}
    end
  end

  defp take_chunk(_connect, _needle, _limit, [], found, state), do: {:cont, found, state}

  defp take_chunk(connect, needle, limit, [{department_id, first} | rest], found, state) do
    {found, state} =
      counted(needle, members_after(connect, department_id, first, state), found)

    cond do
      rest == [] -> {:cont, found, state}
      length(found) >= limit -> {:halt, found, %{state | complete: false}}
      not state.complete -> {:halt, found, state}
      true -> take_chunk(connect, needle, limit, rest, found, state)
    end
  end

  # The first member page of each department, read at once; the answers come
  # in the departments' order.
  defp first_pages(connect, departments) do
    departments
    |> SystemsClock.async_stream(
      &API.get(connect, @members_path, Map.put(member_params(&1), :page_size, @page_size)),
      max_concurrency: @concurrency,
      timeout: @read_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _reason} -> {:error, @read_timeout}
    end)
  end

  # A department's members from its first page, read in a chunk, and every
  # further page.
  defp members_after(connect, department_id, first, state) do
    case received(first, state) do
      {:ok, data, state} ->
        users = List.wrap(data["items"])
        next = str(data["page_token"])
        params = member_params(department_id)

        if data["has_more"] == true and next != "",
          do: pages(connect, @members_path, params, state, users, &collect_items/2, next),
          else: {:ok, users, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # The root and every department below it, in the order Feishu lists them,
  # keeping their names and parents in `state`.
  defp descendants(connect, root_id, state) do
    collect = fn data, acc -> acc ++ List.wrap(data["items"]) end
    params = %{department_id_type: "open_department_id", fetch_child: true}
    path = "/contact/v3/departments/#{URI.encode_www_form(root_id)}/children"

    case pages(connect, path, params, state, [], collect) do
      {:ok, departments, state} ->
        ids = Enum.map(departments, &str(&1["open_department_id"]))
        names = Map.new(departments, &{str(&1["open_department_id"]), str(&1["name"])})

        parents =
          Map.new(departments, &{str(&1["open_department_id"]), str(&1["parent_department_id"])})

        state = %{
          state
          | department_names: Map.merge(state.department_names, names),
            department_parents: Map.merge(state.department_parents, parents)
        }

        {:ok, [root_id | ids] |> Enum.reject(&(&1 == "")) |> Enum.uniq(), state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # A data range root's own name; the tenant root `"0"` has none.
  defp root_name(_connect, "0", state), do: state

  defp root_name(connect, root_id, state) do
    path = "/contact/v3/departments/#{URI.encode_www_form(root_id)}"

    # A missing name does not make the search incomplete.
    case request(connect, path, %{department_id_type: "open_department_id"}, state) do
      {:ok, %{"department" => %{"name" => name}}, state} ->
        %{state | department_names: Map.put(state.department_names, root_id, str(name))}

      {:error, :budget, state} ->
        state

      {_result, _data, after_request} ->
        %{after_request | error: state.error}
    end
  end

  defp department_members(connect, needle, department_id, found, state),
    do: counted(needle, members(connect, department_id, state), found)

  defp counted(needle, {:ok, users, state}, found),
    do: consider(needle, users, found, %{state | departments_read: state.departments_read + 1})

  defp counted(_needle, {:error, _reason, state}, found), do: {found, state}

  # A department's direct members, every page. A read the request budget
  # cut short leaves `state.complete` false.
  defp members(connect, department_id, state),
    do: pages(connect, @members_path, member_params(department_id), state, [], &collect_items/2)

  defp member_params(department_id) do
    %{
      department_id: department_id,
      department_id_type: "open_department_id",
      user_id_type: "open_id"
    }
  end

  defp collect_items(data, acc), do: acc ++ List.wrap(data["items"])

  defp consider(needle, users, found, state) do
    Enum.reduce(users, {found, state}, fn user, {found, state} ->
      open_id = str(user["open_id"])

      if open_id != "" and MapSet.member?(state.seen, open_id) do
        {found, state}
      else
        state = %{
          state
          | people_read: state.people_read + 1,
            seen: MapSet.put(state.seen, open_id)
        }

        if matches?(user, needle),
          do: {found ++ [Map.take(user, @kept_fields)], state},
          else: {found, state}
      end
    end)
  end

  defp matches?(user, needle) do
    Enum.any?(@matched_fields, fn field ->
      user[field] |> str() |> String.downcase() |> String.contains?(needle)
    end)
  end

  @merge "A person in departments that different calls read is in each of those calls: merge the calls' users by open_id, joining their departments."
  @changed "The Contacts data range changed since this continue_from was made."
  @invalid "continue_from is not one that feishu.list_directory_users returned; call it without continue_from to start from the beginning."
  @too_wide "A root of the Contacts data range has more departments than one call can list, so this operation cannot read the range."

  @doc """
  The answer of `feishu.list_directory_users`: everyone in the app's Contacts
  data range, from the start or from the `continue_from` an earlier call
  answered. `{:error, reason}` when the data range roots cannot be read or
  `continue_from` is not valid here.
  """
  @spec list(map(), term()) :: {:ok, map()} | {:error, String.t()}
  def list(connect, continue_from) do
    with {:ok, at} <- position(continue_from),
         {:ok, roots, state} <- roots(connect, new_state()),
         roots = %{departments: ids(roots.departments), users: ids(roots.users)},
         :ok <- same_range(at, roots) do
      acc = %{state: state, people: %{}, order: [], read: 0, users_read: 0, unread: []}
      {:ok, list_from(connect, roots, at, acc)}
    end
  end

  @doc """
  True for a `list/2` error that means a walk must start again from the
  beginning: the data range changed, or the position is not valid.
  """
  @spec restart?(term()) :: boolean()
  def restart?(@invalid), do: true
  def restart?(error) when is_binary(error), do: String.starts_with?(error, @changed)
  def restart?(_error), do: false

  defp ids(ids), do: ids |> Enum.map(&str/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp list_from(connect, roots, %{"r" => r} = at, acc) when r < length(roots.departments) do
    root = Enum.at(roots.departments, r)
    at = %{at | "root" => root}
    state = root_name(connect, root, acc.state)

    case descendants(connect, root, state) do
      {:ok, departments, %{complete: true} = state} ->
        acc = %{acc | state: state}

        if at["d"] == 0 or Enum.at(departments, at["d"]) == at["id"],
          do: list_departments(connect, roots, departments, at, acc),
          else: listed(acc, roots, at, :changed)

      # The budget ran out while listing this root's departments. A call
      # that read nothing before it can never get further: say so instead of
      # answering a continue_from that leads back here.
      {:ok, _departments, state} ->
        outcome = if acc.read == 0 and acc.users_read == 0, do: :too_wide, else: nil
        listed(%{acc | state: state}, roots, at, outcome)

      {:error, reason, state} ->
        listed(%{acc | state: state}, roots, at, reason)
    end
  end

  defp list_from(connect, roots, %{"u" => u} = at, acc) when u < length(roots.users) do
    url = "/contact/v3/users/#{URI.encode_www_form(Enum.at(roots.users, u))}"

    case request(connect, url, %{}, acc.state) do
      {:ok, data, state} ->
        acc = %{acc | state: state, users_read: acc.users_read + 1}

        acc =
          case data["user"] do
            %{} = user ->
              add(acc, user, Enum.map(List.wrap(user["department_ids"]), &path(&1, state)))

            _none ->
              acc
          end

        list_from(connect, roots, next_user(at, roots, u + 1), acc)

      {:error, :budget, state} ->
        listed(%{acc | state: state}, roots, at, nil)

      {:error, reason, state} ->
        listed(%{acc | state: state}, roots, at, reason)
    end
  end

  defp list_from(_connect, roots, at, acc), do: listed(acc, roots, at, :complete)

  defp list_departments(connect, roots, departments, %{"d" => d} = at, acc) do
    case Enum.at(departments, d) do
      nil ->
        list_from(connect, roots, next_root(at, roots), acc)

      department ->
        at = %{at | "id" => department}

        case members(connect, department, acc.state) do
          {:ok, users, %{complete: true} = state} ->
            acc = %{acc | state: state, read: acc.read + 1}
            acc = Enum.reduce(users, acc, &add(&2, &1, [path(department, state)]))
            next = %{at | "d" => d + 1, "id" => Enum.at(departments, d + 1)}
            list_departments(connect, roots, departments, next, acc)

          # The budget ran out inside the department: none of its members
          # count. One that no call can read whole is named and passed.
          {:ok, _part, state} ->
            if acc.read > 0 or acc.users_read > 0,
              do: listed(%{acc | state: state}, roots, at, nil),
              else:
                listed(
                  %{acc | state: state, unread: [unread(department, state)]},
                  roots,
                  %{at | "d" => d + 1, "id" => Enum.at(departments, d + 1)},
                  nil
                )

          {:error, reason, state} ->
            listed(%{acc | state: state}, roots, at, reason)
        end
    end
  end

  defp next_root(%{"r" => r} = at, roots) do
    case Enum.at(roots.departments, r + 1) do
      nil -> next_user(%{at | "r" => r + 1, "root" => nil, "d" => 0, "id" => nil}, roots, 0)
      root -> %{at | "r" => r + 1, "root" => root, "d" => 0, "id" => nil}
    end
  end

  defp next_user(at, roots, u), do: %{at | "u" => u, "uid" => Enum.at(roots.users, u)}

  defp unread(department, state) do
    %{"open_department_id" => department, "path" => path(department, state)}
  end

  # One entry per person in this call, with every department this call found
  # them in.
  defp add(acc, user, paths) do
    open_id = str(user["open_id"])
    key = if open_id == "", do: {:no_id, length(acc.order)}, else: open_id
    paths = Enum.reject(paths, &(&1 == ""))

    case acc.people do
      %{^key => person} ->
        person = Map.update!(person, "departments", &Enum.uniq(&1 ++ paths))
        %{acc | people: Map.put(acc.people, key, person)}

      _new ->
        person =
          user
          |> Map.take(@listed_fields)
          |> Map.reject(fn {_field, value} -> value in [nil, ""] end)
          |> Map.put("departments", Enum.uniq(paths))

        %{acc | people: Map.put(acc.people, key, person), order: [key | acc.order]}
    end
  end

  # A department's names from the data range root down, as far as this call
  # knows them; the tenant root `"0"` has no name.
  defp path(department_id, state), do: path(department_id, state, [], 0)

  defp path(department_id, state, below, depth) when depth < 32 do
    case state.department_names[department_id] do
      name when name not in [nil, ""] ->
        parent = state.department_parents[department_id]

        if parent in [nil, "", "0", department_id],
          do: Enum.join([name | below], " / "),
          else: path(parent, state, [name | below], depth + 1)

      _unknown ->
        Enum.join(below, " / ")
    end
  end

  defp path(_department_id, _state, below, _depth), do: Enum.join(below, " / ")

  defp listed(acc, roots, at, outcome) do
    users = acc.order |> Enum.reverse() |> Enum.map(&acc.people[&1])
    roots_total = length(roots.departments) + length(roots.users)
    reached = if outcome == :complete, do: roots_total, else: roots_reached(at, roots)

    %{
      "users" => users,
      "complete" => outcome == :complete,
      "people_returned" => length(users),
      "departments_read" => acc.read,
      "departments_read_total" => at["n"] + acc.read,
      "requests" => acc.state.requests,
      "data_range" => %{
        "root_departments" => length(roots.departments),
        "root_users" => length(roots.users),
        "roots_reached" => reached,
        "all_roots_reached" => reached == roots_total
      }
    }
    |> put_outcome(outcome, %{at | "n" => at["n"] + acc.read})
    |> then(&if(acc.unread == [], do: &1, else: Map.put(&1, "unread_departments", acc.unread)))
    |> then(&Map.put(&1, "note", list_note(&1)))
  end

  defp put_outcome(result, :complete, _at), do: result
  defp put_outcome(result, :changed, _at), do: Map.put(result, "error", @changed)
  defp put_outcome(result, :too_wide, _at), do: Map.put(result, "error", @too_wide)

  defp put_outcome(result, error, at) do
    result = Map.put(result, "continue_from", encode_position(at))
    if error, do: Map.put(result, "error", error), else: result
  end

  defp roots_reached(%{"r" => r, "d" => d, "u" => u}, roots) do
    if r < length(roots.departments),
      do: r + if(d > 0, do: 1, else: 0),
      else: length(roots.departments) + u
  end

  defp list_note(%{"complete" => true, "departments_read_total" => total}),
    do:
      "Read the whole Contacts data range (#{total} departments in all calls). Each person is listed once in a call, with every department that call read them in. " <>
        @merge

  defp list_note(%{"continue_from" => _} = result) do
    first =
      if result["error"],
        do:
          "A Feishu read failed (error says why); the people listed were read before it. Call feishu.list_directory_users again with this continue_from to retry from the department that failed.",
        else:
          "This call reached its request budget before the end of the Contacts data range. Call feishu.list_directory_users again with this continue_from, exactly as given, and repeat until complete is true."

    unread =
      if result["unread_departments"],
        do:
          " The departments in unread_departments have more members than one call can read; list them with feishu.list_department_users.",
        else: ""

    first <> unread <> " " <> @merge
  end

  defp list_note(%{"error" => @too_wide}),
    do:
      "Do not call feishu.list_directory_users again for this range. Walk it with feishu.list_departments and feishu.list_department_users, a department at a time."

  defp list_note(_changed),
    do:
      "Start again: call feishu.list_directory_users without continue_from, and merge what it lists with the earlier calls by open_id."

  defp position(nil), do: {:ok, @start}
  defp position(""), do: {:ok, @start}

  defp position(text) when is_binary(text) do
    with {:ok, json} <- Base.url_decode64(text, padding: false),
         {:ok, %{"v" => 1, "r" => r, "d" => d, "u" => u, "n" => n} = at}
         when is_integer(r) and r >= 0 and is_integer(d) and d >= 0 and is_integer(u) and
                u >= 0 and is_integer(n) and n >= 0 <- Jason.decode(json) do
      {:ok, Map.merge(@start, Map.take(at, Map.keys(@start)))}
    else
      _invalid -> {:error, @invalid}
    end
  end

  defp position(_other), do: {:error, @invalid}

  defp encode_position(at), do: at |> Jason.encode!() |> Base.url_encode64(padding: false)

  # A position names the root and department (or the person named as a root)
  # it stands at; when those moved, the walk would skip or repeat people.
  defp same_range(%{"r" => r} = at, roots) do
    departments = length(roots.departments)

    cond do
      r == 0 and at["d"] == 0 and at["u"] == 0 and is_nil(at["root"]) ->
        :ok

      r < departments and Enum.at(roots.departments, r) == at["root"] ->
        :ok

      r == departments and is_nil(at["root"]) and Enum.at(roots.users, at["u"]) == at["uid"] ->
        :ok

      true ->
        {:error, @changed <> " Call it without continue_from to start again."}
    end
  end

  # Reads every page of one list, folding each page's data into `acc`. Stops
  # without error when the request budget runs out, marking the search
  # incomplete.
  defp pages(connect, path, params, state, acc, fold, page_token \\ nil) do
    params =
      params
      |> Map.put(:page_size, @page_size)
      |> then(&if(page_token, do: Map.put(&1, :page_token, page_token), else: &1))

    case request(connect, path, params, state) do
      {:ok, data, state} ->
        acc = fold.(data, acc)
        next = str(data["page_token"])

        if data["has_more"] == true and next != "" and next != page_token,
          do: pages(connect, path, params, state, acc, fold, next),
          else: {:ok, acc, state}

      {:error, :budget, state} ->
        {:ok, acc, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp request(_connect, _path, _params, %{requests: requests} = state)
       when requests >= @max_requests,
       do: {:error, :budget, %{state | complete: false}}

  defp request(connect, path, params, state),
    do: received(API.get(connect, path, params), %{state | requests: state.requests + 1})

  # One directory answer, its request already counted in `state`.
  defp received({:ok, data}, state) when is_map(data), do: {:ok, data, state}
  defp received({:ok, _data}, state), do: {:ok, %{}, state}

  defp received({:error, reason}, state),
    do: {:error, reason, %{state | error: state.error || reason}}
end
