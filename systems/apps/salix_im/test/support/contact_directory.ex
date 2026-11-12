defmodule SalixIM.TestSupport.ContactDirectory do
  @moduledoc """
  A Contacts directory for the fake Feishu and Lark OpenAPIs of the provider
  tests, answered as `/contact/v3` answers it: the data range roots, every
  department below a department (`fetch_child=true`), one department, its
  direct members and one person, in pages of the requested size.

  A directory is `%{roots: [department_id], named: [user],
  departments: [%{"open_department_id", "name", "parent_department_id"}],
  members: %{department_id => [user]}, failing: [department_id]}`: `named`
  are the people the data range names one by one. A failing department's
  members are refused with a permission error.
  """

  @doc """
  A small tenant: the tenant root's own member, Engineering with Backend
  below it (Alice is in both), Design, and one person named by the range.
  """
  def small do
    alice = %{
      "open_id" => "ou_alice",
      "name" => "Alice",
      "en_name" => "Alice Wu",
      "email" => "alice@acme.test",
      "employee_no" => "E1",
      "job_title" => "Engineer",
      "mobile" => "+8613800000000",
      "avatar" => %{"avatar_72" => "https://example.test/a.png"},
      "department_ids" => ["od_eng", "od_backend"]
    }

    %{
      roots: ["0"],
      named: [%{"open_id" => "ou_dana", "name" => "Dana", "department_ids" => ["od_design"]}],
      departments: [
        department("od_eng", "Engineering", "0"),
        department("od_backend", "Backend", "od_eng"),
        department("od_design", "Design", "0")
      ],
      members: %{
        "0" => [%{"open_id" => "ou_ceo", "name" => "Chen"}],
        "od_eng" => [alice],
        "od_backend" => [%{"open_id" => "ou_bob", "name" => "Bob"}, alice],
        "od_design" => [%{"open_id" => "ou_carol", "name" => "Carol"}]
      }
    }
  end

  @doc """
  A tenant of `count` departments under the root, one person each, and
  `ou_both` in the first and the last department.
  """
  def wide(count) do
    ids = for n <- 1..count, do: "od_" <> String.pad_leading(Integer.to_string(n), 3, "0")
    both = %{"open_id" => "ou_both", "name" => "Both"}

    members =
      Map.new(ids, fn "od_" <> n = id ->
        {id, [%{"open_id" => "ou_" <> n, "name" => "P" <> n}]}
      end)

    %{
      roots: ["0"],
      departments: Enum.map(ids, &department(&1, "Team " <> &1, "0")),
      members:
        members
        |> Map.update!(List.first(ids), &(&1 ++ [both]))
        |> Map.update!(List.last(ids), &(&1 ++ [both]))
    }
  end

  defp department(id, name, parent),
    do: %{"open_department_id" => id, "name" => name, "parent_department_id" => parent}

  @doc "The answer to a GET of `path` (after `/open-apis`), or `:none` for another path."
  def answer(directory, path, query) do
    case path do
      ["contact", "v3", "scopes"] ->
        ok(%{
          "department_ids" => directory.roots,
          "user_ids" => Enum.map(Map.get(directory, :named, []), & &1["open_id"]),
          "has_more" => false
        })

      ["contact", "v3", "departments", id, "children"] ->
        page(below(directory, id), query)

      ["contact", "v3", "departments", id] ->
        case Enum.find(directory.departments, &(&1["open_department_id"] == id)) do
          nil -> {400, %{"code" => 40_003, "msg" => "department not found"}}
          department -> ok(%{"department" => department})
        end

      ["contact", "v3", "users", "find_by_department"] ->
        id = query["department_id"]

        if id in Map.get(directory, :failing, []),
          do: {400, %{"code" => 99_991_672, "msg" => "Access denied. No permission for #{id}."}},
          else: page(Map.get(directory.members, id, []), query)

      ["contact", "v3", "users", open_id] ->
        directory.members
        |> Map.values()
        |> List.flatten()
        |> Enum.concat(Map.get(directory, :named, []))
        |> Enum.find(&(&1["open_id"] == open_id))
        |> case do
          nil -> {400, %{"code" => 41_050, "msg" => "no user authority error"}}
          user -> ok(%{"user" => user})
        end

      _other ->
        :none
    end
  end

  # Every department below `id`, parents before their children.
  defp below(directory, id) do
    children = Enum.filter(directory.departments, &(&1["parent_department_id"] == id))
    Enum.flat_map(children, &[&1 | below(directory, &1["open_department_id"])])
  end

  defp page(items, query) do
    size = String.to_integer(query["page_size"] || "50")
    offset = String.to_integer(query["page_token"] || "0")
    rest = Enum.drop(items, offset)
    more? = length(rest) > size

    ok(%{
      "items" => Enum.take(rest, size),
      "has_more" => more?,
      "page_token" => if(more?, do: Integer.to_string(offset + size), else: "")
    })
  end

  defp ok(data), do: {200, %{"code" => 0, "msg" => "ok", "data" => data}}
end
