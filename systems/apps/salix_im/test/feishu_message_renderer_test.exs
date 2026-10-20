defmodule SalixIM.Provider.Feishu.MessageRendererTest do
  use SystemsClock.Case, async: true

  alias SalixIM.MessageRenderer.{Input, Surface}
  alias SalixIM.Provider.Feishu.MessageRenderer, as: Renderer
  @options [extension: [table: true, tasklist: true, strikethrough: true, autolink: true]]

  test "only structured mentions notify and IDs and display names survive" do
    source = ~s(<at user_id="all">all</at> <AT user_id="ou_eve">Eve</AT> <@U123> <!everyone> @all)

    assert {:ok, body} =
             render(source, mentions: [%{open_id: "ou_alice", name: "Alice & **Bob**"}])

    assert [mentions, [%{"tag" => "md"}]] = rows(body)

    assert mentions == [
             %{"tag" => "at", "user_id" => "ou_alice", "user_name" => "Alice & **Bob**"}
           ]

    assert [] == Enum.filter(nodes(md(body)), &match?(%MDEx.HtmlInline{}, &1))
    assert {:ok, all} = render("hello", mention_all: true)
    assert hd(rows(all)) == [%{"tag" => "at", "user_id" => "all", "user_name" => "所有人"}]

    for id <- ["all", "ALL", "U0AU3GAP8ER", "W012A3CDE", "C0BBJS6BC84", "<@U123>"] do
      assert {:error, _} = render("hello", mentions: [id])
    end

    # Tenant-defined Feishu user IDs can be short uppercase codes.
    for id <- ["C001", "USERADMIN"] do
      assert {:ok, body} = render("hello", mentions: [id])
      assert [[%{"tag" => "at", "user_id" => ^id}], _] = rows(body)
    end
  end

  test "task cards render as updatable interactive cards with escaped Markdown" do
    surface = %Surface{
      kind: :task_card,
      id: "task-1",
      fallback: "Task Deploy: in progress",
      title: "  Deploy  ",
      subtitle: "In progress",
      status: :in_progress,
      details: "Step <at user_id=\"all\">x</at>",
      output: String.duplicate("界", 10_000)
    }

    assert {:ok, card} = Renderer.render_surface(surface, [])
    assert card["schema"] == "2.0"
    assert card["config"]["update_multi"] == true
    assert card["config"]["summary"]["content"] == "Task Deploy: in progress"
    assert card["header"]["title"]["content"] == "Deploy"
    assert card["header"]["template"] == "blue"

    assert [details, output] = card["body"]["elements"]
    assert details["content"] == "Step &#60;at user_id=\"all\"&#62;x&#60;/at&#62;"
    assert byte_size(output["content"]) <= 18_000
    assert String.ends_with?(output["content"], "…")

    assert {:ok, %{"body" => %{"elements" => [%{"content" => "Pending"}]}}} =
             Renderer.render_surface(
               %{surface | status: :pending, subtitle: "Pending", details: nil, output: nil},
               []
             )

    assert {:error, :invalid_task_card_surface} =
             Renderer.render_surface(%{surface | title: " "}, [])

    assert {:error, :unsupported_surface_kind} =
             Renderer.render_surface(%{surface | kind: :plan}, [])
  end

  defp render(text, opts \\ []), do: Renderer.render(%Input{markdown: text}, opts)
  defp rows(body), do: get_in(Jason.decode!(body["content"]), ["zh_cn", "content"])
  defp md(body), do: rows(body) |> List.last() |> hd() |> Map.fetch!("text")

  defp nodes(markdown) do
    document = MDEx.parse_document!(markdown, @options)

    {_document, nodes} =
      MDEx.traverse_and_update(document, [], fn node, nodes -> {node, [node | nodes]} end)

    Enum.reverse(nodes)
  end
end
