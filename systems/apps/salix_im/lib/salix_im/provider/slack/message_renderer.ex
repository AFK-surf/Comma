defmodule SalixIM.Provider.Slack.MessageRenderer do
  @moduledoc false

  @behaviour SalixIM.MessageRenderer

  alias SalixIM.SlackMarkdown
  alias SalixIM.MessageRenderer.{Input, Surface}
  alias SalixIM.Provider.Slack.RichCard

  @action_prefix "comma_md_tasks_v1_"
  @block_limit 50
  @markdown_limit 12_000
  @table_character_limit 10_000
  @table_character_count_key :__salix_table_character_count__
  @table_row_limit 100
  @table_column_limit 20
  @checkbox_option_limit 10
  @checkbox_label_limit 75
  @slack_native_reference ~r/<(?:@[UW]|#[CG])[A-Z0-9]{2,}>/
  @slack_native_reference_at_start ~r/\A<(?:@[UW]|#[CG])[A-Z0-9]{2,}>/
  @backtick_run ~r/`+/
  @table_inline_token ~r/<(?:@[UW]|#[CG])[A-Z0-9]{2,}>|\[[^\]\n]+\]\(https?:\/\/[^)\s]+\)/u
  @table_markdown_escape_prefixes ["\\<", "\\>", "\\[", "\\]", "\\(", "\\)"]
  @inline_heading_markup ~r/[*_`~<>\[\]\\]/u
  @task_line ~r/^\s*[-*+]\s+\[([ xX])\]\s+(.+?)\s*$/
  @fence_line ~r/^\s*(```|~~~)/
  @surface_statuses [:pending, :in_progress, :complete, :error]
  @rich_surface_kinds [:map, :stock, :weather]

  @impl true
  def render(%Input{} = input, _opts) do
    text = String.trim(input.markdown)

    with :ok <- validate_text(text),
         chunks <- semantic_chunks(text),
         blocks <- render_chunks(chunks, text),
         :ok <- validate_block_limit(blocks),
         :ok <- validate_markdown_limit(blocks),
         :ok <- validate_table_character_limit(blocks) do
      {:ok, %{text: text, blocks: strip_table_character_counts(blocks)}}
    end
  end

  def render(markdown) when is_binary(markdown), do: render(%Input{markdown: markdown}, [])

  @doc false
  @spec validate_block_limit(term()) ::
          :ok | {:error, :too_many_blocks | :invalid_blocks}
  def validate_block_limit(blocks) when is_list(blocks) do
    if length(blocks) <= @block_limit, do: :ok, else: {:error, :too_many_blocks}
  end

  def validate_block_limit(_blocks), do: {:error, :invalid_blocks}

  @impl true
  def render_surface(%Surface{kind: kind, data: data} = surface, _opts)
      when kind in @rich_surface_kinds do
    with :ok <- validate_surface_id(surface),
         true <- is_map(data),
         {:ok, rendered} <- RichCard.render(Atom.to_string(kind), data),
         :ok <- validate_block_limit(rendered.blocks) do
      {:ok, rendered}
    else
      false -> {:error, :surface_data_required}
      {:error, _reason} = error -> error
    end
  end

  def render_surface(%Surface{} = surface, _opts) do
    with :ok <- validate_surface_common(surface),
         {:ok, block} <- render_surface_block(surface) do
      {:ok, %{text: String.trim(surface.fallback), blocks: [block]}}
    end
  end

  @doc false
  def checkbox_action?(action_id) when is_binary(action_id),
    do: String.starts_with?(action_id, @action_prefix)

  def checkbox_action?(_action_id), do: false

  @doc false
  def apply_checkbox_selection(blocks, action_id, selected_values)
      when is_list(blocks) and is_binary(action_id) and is_list(selected_values) do
    if checkbox_action?(action_id) do
      update_checkbox_blocks(blocks, action_id, selected_values)
    else
      {:error, :unsupported_checkbox_action}
    end
  end

  def apply_checkbox_selection(_blocks, _action_id, _selected_values),
    do: {:error, :invalid_checkbox_action}

  defp validate_surface_id(%Surface{id: id}) do
    if is_binary(id) and String.trim(id) != "",
      do: :ok,
      else: {:error, :surface_id_required}
  end

  defp validate_surface_common(%Surface{fallback: fallback} = surface) do
    with :ok <- validate_surface_id(surface) do
      if is_binary(fallback) and String.trim(fallback) != "",
        do: :ok,
        else: {:error, :surface_fallback_required}
    end
  end

  defp render_surface_block(%Surface{kind: :card} = surface) do
    with :ok <- validate_card_surface(surface),
         {:ok, actions} <- render_card_actions(surface.actions),
         {:ok, hero_image} <- render_surface_image(surface.hero_image),
         {:ok, icon} <- render_surface_image(surface.icon) do
      block = %{
        "type" => "card",
        "block_id" => surface_block_id(surface)
      }

      block =
        block
        |> put_surface_text("title", surface.title, 150)
        |> put_surface_text("subtitle", surface.subtitle, 150)
        |> put_surface_text("body", surface.body, 200)
        |> put_surface_text("subtext", surface.subtext, 200)
        |> put_optional("hero_image", hero_image)
        |> put_optional("icon", icon)
        |> put_optional_list("actions", actions)

      {:ok, block}
    end
  end

  defp render_surface_block(%Surface{kind: :plan} = surface) do
    with :ok <- validate_plan_surface(surface),
         {:ok, tasks} <- render_surface_tasks(surface.tasks) do
      {:ok,
       %{
         "type" => "plan",
         "block_id" => surface_block_id(surface),
         "title" => surface.title |> String.trim() |> String.slice(0, 200),
         "tasks" => tasks
       }}
    end
  end

  defp render_surface_block(%Surface{kind: :task_card} = surface) do
    task = %{
      id: surface.id,
      title: surface.title,
      status: surface.status,
      details: surface.details,
      output: surface.output,
      sources: surface.sources
    }

    with :ok <- validate_surface_task(task),
         {:ok, rendered_task} <- render_surface_task(task) do
      {:ok,
       rendered_task
       |> Map.put("type", "task_card")
       |> Map.put("block_id", surface_block_id(surface))}
    end
  end

  defp render_surface_block(%Surface{}), do: {:error, :unsupported_surface_kind}

  defp validate_card_surface(%Surface{} = surface) do
    has_content =
      surface_text_present?(surface.title) or surface_text_present?(surface.body) or
        surface.actions != [] or is_map(surface.hero_image)

    cond do
      not has_content ->
        {:error, :card_content_required}

      not is_list(surface.actions) or length(surface.actions) > 3 ->
        {:error, :invalid_card_actions}

      true ->
        :ok
    end
  end

  defp validate_plan_surface(%Surface{title: title, tasks: tasks}) do
    cond do
      not surface_text_present?(title) -> {:error, :plan_title_required}
      not is_list(tasks) or tasks == [] -> {:error, :plan_tasks_required}
      true -> :ok
    end
  end

  defp render_card_actions(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, rendered} ->
      case render_card_action(action) do
        {:ok, button} -> {:cont, {:ok, rendered ++ [button]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render_card_action(%{id: id, text: text} = action)
       when is_binary(id) and is_binary(text) do
    id = String.trim(id)
    text = String.trim(text)
    url = Map.get(action, :url)
    style = Map.get(action, :style)

    cond do
      id == "" or text == "" ->
        {:error, :invalid_card_action}

      style not in [nil, :primary, :danger] ->
        {:error, :invalid_card_action}

      not valid_optional_url?(url) ->
        {:error, :invalid_surface_url}

      true ->
        button = %{
          "type" => "button",
          "action_id" => String.slice(id, 0, 255),
          "text" => %{
            "type" => "plain_text",
            "text" => String.slice(text, 0, 75),
            "emoji" => false
          }
        }

        button =
          button
          |> put_optional_url(url)
          |> put_optional_style(style)

        {:ok, button}
    end
  end

  defp render_card_action(_action), do: {:error, :invalid_card_action}

  defp render_surface_image(nil), do: {:ok, nil}

  defp render_surface_image(%{url: url, alt: alt})
       when is_binary(url) and is_binary(alt) do
    if valid_url?(url) and String.trim(alt) != "" do
      {:ok,
       %{
         "type" => "image",
         "image_url" => String.slice(String.trim(url), 0, 3_000),
         "alt_text" => String.slice(String.trim(alt), 0, 2_000)
       }}
    else
      {:error, :invalid_surface_image}
    end
  end

  defp render_surface_image(_image), do: {:error, :invalid_surface_image}

  defp render_surface_tasks(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, rendered} ->
      with :ok <- validate_surface_task(task),
           {:ok, rendered_task} <- render_surface_task(task) do
        {:cont, {:ok, rendered ++ [rendered_task]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_surface_task(%{id: id, title: title, status: status} = task) do
    cond do
      not surface_text_present?(id) -> {:error, :task_id_required}
      not surface_text_present?(title) -> {:error, :task_title_required}
      status not in @surface_statuses -> {:error, :invalid_task_status}
      true -> validate_surface_sources(Map.get(task, :sources, []))
    end
  end

  defp validate_surface_task(%{} = task) do
    cond do
      not surface_text_present?(Map.get(task, :id)) -> {:error, :task_id_required}
      not surface_text_present?(Map.get(task, :title)) -> {:error, :task_title_required}
      Map.get(task, :status) not in @surface_statuses -> {:error, :invalid_task_status}
      true -> validate_surface_sources(Map.get(task, :sources, []))
    end
  end

  defp validate_surface_task(_task), do: {:error, :invalid_surface_task}

  defp render_surface_task(task) do
    with {:ok, sources} <- render_surface_sources(Map.get(task, :sources, [])) do
      rendered = %{
        "task_id" => task.id |> String.trim() |> String.slice(0, 255),
        "title" => task.title |> String.trim() |> String.slice(0, 200),
        "status" => Atom.to_string(task.status)
      }

      rendered =
        rendered
        |> put_surface_rich_text("details", Map.get(task, :details))
        |> put_surface_rich_text("output", Map.get(task, :output))
        |> put_optional_list("sources", sources)

      {:ok, rendered}
    end
  end

  defp validate_surface_sources(sources) when is_list(sources) do
    if Enum.all?(sources, fn
         %{url: url, text: text} ->
           is_binary(url) and valid_url?(url) and surface_text_present?(text)

         _source ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_surface_source}
  end

  defp validate_surface_sources(_sources), do: {:error, :invalid_surface_source}

  defp render_surface_sources(sources) do
    case validate_surface_sources(sources) do
      :ok ->
        {:ok,
         Enum.map(sources, fn source ->
           %{
             "type" => "url",
             "url" => String.trim(source.url),
             "text" => source.text |> String.trim() |> String.slice(0, 200)
           }
         end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_surface_text(block, _key, value, _limit) when not is_binary(value), do: block

  defp put_surface_text(block, key, value, limit) do
    case String.trim(value) do
      "" ->
        block

      text ->
        Map.put(block, key, %{
          "type" => "mrkdwn",
          "text" => text |> SlackMarkdown.to_mrkdwn() |> String.slice(0, limit),
          "verbatim" => false
        })
    end
  end

  defp put_surface_rich_text(block, _key, value) when not is_binary(value), do: block

  defp put_surface_rich_text(block, key, value) do
    case String.trim(value) do
      "" -> block
      text -> Map.put(block, key, surface_rich_text(text))
    end
  end

  defp surface_rich_text(text) do
    SlackMarkdown.render_rich_text(text)
  end

  defp put_optional(block, _key, nil), do: block
  defp put_optional(block, key, value), do: Map.put(block, key, value)

  defp put_optional_list(block, _key, []), do: block
  defp put_optional_list(block, key, value), do: Map.put(block, key, value)

  defp put_optional_url(block, nil), do: block
  defp put_optional_url(block, ""), do: block
  defp put_optional_url(block, url), do: Map.put(block, "url", String.trim(url))

  defp put_optional_style(block, nil), do: block
  defp put_optional_style(block, style), do: Map.put(block, "style", Atom.to_string(style))

  defp surface_text_present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_optional_url?(nil), do: true
  defp valid_optional_url?(""), do: true
  defp valid_optional_url?(url), do: is_binary(url) and valid_url?(url)

  defp valid_url?(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _uri ->
        false
    end
  end

  defp surface_block_id(%Surface{render_id: render_id} = surface) do
    case if(is_binary(render_id), do: String.trim(render_id), else: "") do
      "" ->
        "comma_#{surface.kind}_" <>
          digest(:erlang.term_to_binary(surface, [:deterministic]))

      id ->
        String.slice(id, 0, 255)
    end
  end

  defp validate_text(""), do: {:error, :text_required}
  defp validate_text(_text), do: :ok

  defp semantic_chunks(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{chunks: [], lines: [], tasks: [], fence: nil}, &chunk_line/2)
    |> flush_tasks()
    |> flush_lines()
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

  defp chunk_line(line, %{fence: nil} = state) do
    case Regex.run(@task_line, line) do
      [_, checked, label] ->
        state
        |> flush_lines()
        |> Map.update!(:tasks, &[{checked in ["x", "X"], label} | &1])

      _other ->
        state
        |> flush_tasks()
        |> append_line(line)
        |> maybe_open_fence(line)
    end
  end

  defp chunk_line(line, state) do
    state
    |> append_line(line)
    |> maybe_close_fence(line)
  end

  defp append_line(state, line), do: Map.update!(state, :lines, &[line | &1])

  defp maybe_open_fence(state, line) do
    case Regex.run(@fence_line, line) do
      [_, marker] -> %{state | fence: marker}
      _other -> state
    end
  end

  defp maybe_close_fence(%{fence: marker} = state, line) do
    if Regex.match?(~r/^\s*#{Regex.escape(marker)}\s*$/, line),
      do: %{state | fence: nil},
      else: state
  end

  defp flush_lines(%{lines: []} = state), do: state

  defp flush_lines(state) do
    text = state.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    chunks = if text == "", do: state.chunks, else: [{:text, text} | state.chunks]
    %{state | chunks: chunks, lines: []}
  end

  defp flush_tasks(%{tasks: []} = state), do: state

  defp flush_tasks(state) do
    tasks = Enum.reverse(state.tasks)
    %{state | chunks: [{:tasks, tasks} | state.chunks], tasks: []}
  end

  defp render_chunks(chunks, source_text) do
    chunks
    |> promote_leading_h1()
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:header, title}, _index} ->
        [%{"type" => "header", "text" => %{"type" => "plain_text", "text" => title}}]

      {{:text, text}, _index} ->
        render_text_chunk(text)

      {{:tasks, tasks}, index} ->
        render_task_chunks(tasks, source_text, index)
    end)
    |> coalesce_markdown_blocks()
  end

  defp promote_leading_h1([{:text, text} | rest] = chunks) do
    case SlackMarkdown.render_blocks(text) do
      {:ok,
       [
         %{"type" => "header", "text" => %{"type" => "plain_text", "text" => title}},
         %{"type" => "markdown", "text" => body}
       ]} ->
        [{:header, title}, {:text, body} | rest]

      {:ok, [%{"type" => "header", "text" => %{"type" => "plain_text", "text" => title}}]} ->
        [{:header, title} | rest]

      _other ->
        chunks
    end
  end

  defp promote_leading_h1(chunks), do: chunks

  defp render_text_chunk(text) do
    text
    |> paragraphs()
    |> Enum.map(&render_paragraph/1)
  end

  defp render_paragraph(paragraph) do
    case table_block(paragraph) do
      {:ok, block} ->
        block

      :none ->
        cond do
          thematic_break?(paragraph) ->
            %{"type" => "divider"}

          block = heading_block(paragraph) ->
            block

          true ->
            case native_reference_mrkdwn(paragraph) do
              {:ok, text} ->
                %{
                  "type" => "section",
                  "text" => %{
                    "type" => "mrkdwn",
                    "text" => text
                  }
                }

              :none ->
                SlackMarkdown.render_prose_block(paragraph)
            end
        end
    end
  end

  defp heading_block(paragraph) do
    if String.contains?(paragraph, "\n") do
      nil
    else
      Enum.find_value(1..4, fn level ->
        prefix = String.duplicate("#", level) <> " "

        if String.starts_with?(paragraph, prefix) do
          title = paragraph |> String.replace_prefix(prefix, "") |> String.trim()

          if title != "" and String.length(title) <= 150 and
               not Regex.match?(@inline_heading_markup, title) do
            %{
              "type" => "header",
              "level" => level,
              "text" => %{"type" => "plain_text", "text" => title}
            }
          end
        end
      end)
    end
  end

  defp thematic_break?(paragraph) do
    not String.contains?(paragraph, "\n") and
      (Regex.match?(~r/^\s{0,3}(?:-\s*){3,}$/u, paragraph) or
         Regex.match?(~r/^\s{0,3}(?:\*\s*){3,}$/u, paragraph) or
         Regex.match?(~r/^\s{0,3}(?:_\s*){3,}$/u, paragraph))
  end

  defp table_block(paragraph) do
    case String.split(paragraph, "\n", trim: true) do
      [header_line, separator_line | body_lines] = lines
      when length(lines) <= @table_row_limit ->
        with {:ok, header} <- table_row(header_line),
             {:ok, separators} <- table_row(separator_line),
             true <- length(header) in 1..@table_column_limit,
             true <- length(separators) == length(header),
             {:ok, settings} <- table_column_settings(separators),
             {:ok, body} <- table_body(body_lines, length(header)),
             rows <- [header | body],
             character_count <- table_character_count(rows),
             true <- character_count <= @table_character_limit do
          if table_requires_markdown?(rows) do
            {:ok, %{"type" => "markdown", "text" => paragraph}}
          else
            {:ok,
             %{
               "type" => "table",
               @table_character_count_key => character_count,
               "column_settings" => settings,
               "rows" =>
                 rows
                 |> Enum.with_index()
                 |> Enum.map(fn {row, index} ->
                   Enum.map(row, &table_cell(&1, index == 0))
                 end)
             }}
          end
        else
          _other -> :none
        end

      _other ->
        :none
    end
  end

  defp table_requires_markdown?(rows) do
    rows
    |> List.flatten()
    |> Enum.any?(fn cell ->
      String.contains?(cell, "`") or
        Enum.any?(@table_markdown_escape_prefixes, &String.contains?(cell, &1))
    end)
  end

  defp table_row(line) do
    source = String.trim(line)

    if String.contains?(source, "|") do
      source =
        if String.starts_with?(source, "|"), do: String.slice(source, 1..-1//1), else: source

      source =
        if String.ends_with?(source, "|") and not String.ends_with?(source, "\\|"),
          do: String.slice(source, 0, String.length(source) - 1),
          else: source

      {:ok,
       ~r/(?<!\\)\|/u
       |> Regex.split(source)
       |> Enum.map(&(&1 |> String.trim() |> String.replace("\\|", "|")))}
    else
      :none
    end
  end

  defp table_column_settings(cells) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, settings} ->
      source = String.trim(cell)

      if Regex.match?(~r/^:?-{3,}:?$/u, source) do
        align =
          cond do
            String.starts_with?(source, ":") and String.ends_with?(source, ":") -> "center"
            String.ends_with?(source, ":") -> "right"
            true -> "left"
          end

        {:cont, {:ok, settings ++ [%{"align" => align, "is_wrapped" => true}]}}
      else
        {:halt, :none}
      end
    end)
  end

  defp table_body(lines, column_count) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, rows} ->
      case table_row(line) do
        {:ok, row} when length(row) == column_count -> {:cont, {:ok, rows ++ [row]}}
        _other -> {:halt, :none}
      end
    end)
  end

  defp table_character_count(rows) do
    rows
    |> List.flatten()
    |> Enum.map(&String.length/1)
    |> Enum.sum()
  end

  defp table_cell(source, bold?) do
    text = plain_table_text(source)
    segments = Regex.split(@table_inline_token, text, include_captures: true, trim: true)

    elements =
      case Enum.flat_map(segments, &table_inline_element(&1, bold?)) do
        [] -> [styled_element(%{"type" => "text", "text" => "—"}, bold?)]
        values -> values
      end

    %{
      "type" => "rich_text",
      "elements" => [%{"type" => "rich_text_section", "elements" => elements}]
    }
  end

  defp table_inline_element(token, bold?) do
    cond do
      match = Regex.run(~r/^<@([UW][A-Z0-9]+)>$/, token) ->
        [styled_element(%{"type" => "user", "user_id" => Enum.at(match, 1)}, bold?)]

      match = Regex.run(~r/^<#([CG][A-Z0-9]+)>$/, token) ->
        [styled_element(%{"type" => "channel", "channel_id" => Enum.at(match, 1)}, bold?)]

      match = Regex.run(~r/^\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)$/u, token) ->
        [
          styled_element(
            %{"type" => "link", "text" => Enum.at(match, 1), "url" => Enum.at(match, 2)},
            bold?
          )
        ]

      true ->
        case strip_table_markup(token) do
          "" -> []
          value -> [styled_element(%{"type" => "text", "text" => value}, bold?)]
        end
    end
  end

  defp plain_table_text(text), do: if(String.trim(text) == "", do: "—", else: text)

  defp strip_table_markup(text) do
    text
    |> String.replace(~r/\*\*([^*\n]+)\*\*/u, "\\1")
    |> String.replace(~r/__([^_\n]+)__/u, "\\1")
    |> String.replace(~r/~~([^~\n]+)~~/u, "\\1")
    |> String.replace(~r/\*([^*\n]+)\*/u, "\\1")
    |> String.replace(~r/_([^_\n]+)_/u, "\\1")
    |> String.replace("\\|", "|")
  end

  defp styled_element(element, false), do: element
  defp styled_element(element, true), do: Map.put(element, "style", %{"bold" => true})

  defp paragraphs(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(%{paragraphs: [], lines: [], fence: nil}, fn line, state ->
      cond do
        state.fence == nil and String.trim(line) == "" ->
          flush_paragraph(state)

        state.fence == nil ->
          state
          |> append_paragraph_line(line)
          |> maybe_open_paragraph_fence(line)

        true ->
          state
          |> append_paragraph_line(line)
          |> maybe_close_paragraph_fence(line)
      end
    end)
    |> flush_paragraph()
    |> Map.fetch!(:paragraphs)
    |> Enum.reverse()
  end

  defp append_paragraph_line(state, line), do: Map.update!(state, :lines, &[line | &1])

  defp maybe_open_paragraph_fence(state, line) do
    case Regex.run(@fence_line, line) do
      [_, marker] -> %{state | fence: marker}
      _other -> state
    end
  end

  defp maybe_close_paragraph_fence(%{fence: marker} = state, line) do
    if Regex.match?(~r/^\s*#{Regex.escape(marker)}\s*$/, line),
      do: %{state | fence: nil},
      else: state
  end

  defp flush_paragraph(%{lines: []} = state), do: state

  defp flush_paragraph(state) do
    paragraph = state.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    paragraphs = if paragraph == "", do: state.paragraphs, else: [paragraph | state.paragraphs]
    %{state | paragraphs: paragraphs, lines: []}
  end

  defp native_reference_mrkdwn(paragraph) do
    {rendered, native_reference?} =
      paragraph
      |> fenced_reference_segments()
      |> Enum.map_reduce(false, fn
        {:code, source}, found? ->
          {encode_reference_tokens(source), found?}

        {:text, source}, found? ->
          {rendered, segment_found?} = scan_inline_references(source)
          {rendered, found? or segment_found?}
      end)

    if native_reference? do
      {:ok,
       rendered
       |> IO.iodata_to_binary()
       |> SlackMarkdown.to_mrkdwn(
         preserve_native_references: true,
         preserve_entities: true
       )}
    else
      :none
    end
  end

  defp fenced_reference_segments(paragraph) do
    lines = String.split(paragraph, "\n", trim: false)
    last_index = length(lines) - 1

    {segments, _fence} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, index}, {segments, fence} ->
        source = if index == last_index, do: line, else: line <> "\n"

        cond do
          fence == nil ->
            case Regex.run(@fence_line, line) do
              [_, marker] ->
                {append_reference_segment(segments, :code, source), marker}

              _other ->
                {append_reference_segment(segments, :text, source), nil}
            end

          Regex.match?(~r/^\s*#{Regex.escape(fence)}\s*$/, line) ->
            {append_reference_segment(segments, :code, source), nil}

          true ->
            {append_reference_segment(segments, :code, source), fence}
        end
      end)

    Enum.reverse(segments)
  end

  defp append_reference_segment([{kind, previous} | rest], kind, source),
    do: [{kind, previous <> source} | rest]

  defp append_reference_segment(segments, kind, source), do: [{kind, source} | segments]

  defp scan_inline_references(source), do: scan_inline_references(source, :text, [], false)

  defp scan_inline_references("", _mode, rendered, found?),
    do: {rendered |> Enum.reverse() |> IO.iodata_to_binary(), found?}

  defp scan_inline_references(<<"\\", rest::binary>>, :text, rendered, found?) do
    case reference_token(rest) do
      {token, remaining} ->
        scan_inline_references(
          remaining,
          :text,
          [encode_reference_token(token) | rendered],
          found?
        )

      nil ->
        case String.next_grapheme(rest) do
          {grapheme, remaining} ->
            scan_inline_references(
              remaining,
              :text,
              ["\\" <> grapheme | rendered],
              found?
            )

          nil ->
            scan_inline_references("", :text, ["\\" | rendered], found?)
        end
    end
  end

  defp scan_inline_references(<<"`", _rest::binary>> = source, :text, rendered, found?) do
    {delimiter, remaining} = take_backtick_run(source)
    length = byte_size(delimiter)

    if matching_backtick_run?(remaining, length) do
      scan_inline_references(remaining, {:code, length}, [delimiter | rendered], found?)
    else
      scan_inline_references(remaining, :text, [delimiter | rendered], found?)
    end
  end

  defp scan_inline_references(<<"`", _rest::binary>> = source, {:code, length}, rendered, found?) do
    {delimiter, remaining} = take_backtick_run(source)
    mode = if byte_size(delimiter) == length, do: :text, else: {:code, length}
    scan_inline_references(remaining, mode, [delimiter | rendered], found?)
  end

  defp scan_inline_references(source, :text, rendered, found?) do
    case reference_token(source) do
      {token, remaining} ->
        scan_inline_references(remaining, :text, [token | rendered], true)

      nil ->
        {grapheme, remaining} = String.next_grapheme(source)
        scan_inline_references(remaining, :text, [grapheme | rendered], found?)
    end
  end

  defp scan_inline_references(source, {:code, length} = mode, rendered, found?) do
    case reference_token(source) do
      {token, remaining} ->
        scan_inline_references(
          remaining,
          mode,
          [encode_reference_token(token) | rendered],
          found?
        )

      nil ->
        {grapheme, remaining} = String.next_grapheme(source)
        scan_inline_references(remaining, {:code, length}, [grapheme | rendered], found?)
    end
  end

  defp reference_token(source) do
    case Regex.run(@slack_native_reference_at_start, source) do
      [token] ->
        {token, binary_part(source, byte_size(token), byte_size(source) - byte_size(token))}

      nil ->
        nil
    end
  end

  defp take_backtick_run(source), do: take_backtick_run(source, [])

  defp take_backtick_run(<<"`", rest::binary>>, run),
    do: take_backtick_run(rest, ["`" | run])

  defp take_backtick_run(rest, run), do: {run |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp matching_backtick_run?(source, length) do
    @backtick_run
    |> Regex.scan(source, capture: :first)
    |> Enum.any?(fn [run] -> byte_size(run) == length end)
  end

  defp encode_reference_tokens(source),
    do: Regex.replace(@slack_native_reference, source, &encode_reference_token/1)

  defp encode_reference_token("<" <> rest),
    do: "&lt;" <> String.trim_trailing(rest, ">") <> "&gt;"

  defp render_task_chunks(tasks, source_text, chunk_index) do
    tasks
    |> Enum.chunk_every(@checkbox_option_limit)
    |> Enum.with_index()
    |> Enum.map(fn {group, group_index} ->
      action_id = versioned_id(source_text, chunk_index, group_index)

      options =
        group
        |> Enum.with_index()
        |> Enum.map(fn {{_checked, label}, option_index} ->
          %{
            "text" => %{
              "type" => "plain_text",
              "text" => truncate_label(label)
            },
            "value" => "task_" <> digest("#{action_id}:#{option_index}:#{label}")
          }
        end)

      initial_options =
        group
        |> Enum.zip(options)
        |> Enum.flat_map(fn
          {{true, _label}, option} -> [option]
          {{false, _label}, _option} -> []
        end)

      checkbox =
        %{
          "type" => "checkboxes",
          "action_id" => action_id,
          "options" => options
        }
        |> put_initial_options(initial_options)

      %{
        "type" => "actions",
        "block_id" => checkbox_block_id(action_id, initial_options),
        "elements" => [checkbox]
      }
    end)
  end

  defp versioned_id(source_text, chunk_index, group_index) do
    @action_prefix <> digest("#{source_text}\0#{chunk_index}\0#{group_index}")
  end

  defp truncate_label(label) do
    if String.length(label) <= @checkbox_label_limit do
      label
    else
      String.slice(label, 0, @checkbox_label_limit - 1) <> "…"
    end
  end

  defp checkbox_block_id(action_id, initial_options) do
    selected = Enum.map_join(initial_options, "\0", & &1["value"])
    @action_prefix <> digest("#{action_id}\0#{selected}")
  end

  defp update_checkbox_blocks(blocks, action_id, selected_values) do
    {updated, matches, invalid?} =
      Enum.map_reduce(blocks, {0, false}, fn block, {matches, invalid?} ->
        case update_checkbox_block(block, action_id, selected_values) do
          {:ok, block} -> {block, {matches + 1, invalid?}}
          :not_found -> {block, {matches, invalid?}}
          :invalid -> {block, {matches + 1, true}}
        end
      end)
      |> then(fn {updated, {matches, invalid?}} -> {updated, matches, invalid?} end)

    cond do
      invalid? -> {:error, :invalid_checkbox_selection}
      matches == 0 -> {:error, :checkbox_action_not_found}
      matches > 1 -> {:error, :ambiguous_checkbox_action}
      true -> {:ok, updated}
    end
  end

  defp update_checkbox_block(
         %{"type" => "actions", "elements" => elements} = block,
         action_id,
         selected
       )
       when is_list(elements) do
    case update_checkbox_elements(elements, action_id, selected) do
      {:ok, elements, initial_options} ->
        {:ok,
         block
         |> Map.put("elements", elements)
         |> Map.put("block_id", checkbox_block_id(action_id, initial_options))}

      other ->
        other
    end
  end

  defp update_checkbox_block(_block, _action_id, _selected), do: :not_found

  defp update_checkbox_elements(elements, action_id, selected) do
    matches = Enum.count(elements, &(&1["type"] == "checkboxes" and &1["action_id"] == action_id))

    if matches != 1 do
      if matches == 0, do: :not_found, else: :invalid
    else
      checkbox =
        Enum.find(elements, &(&1["type"] == "checkboxes" and &1["action_id"] == action_id))

      options = checkbox["options"] || []
      option_values = MapSet.new(options, & &1["value"])
      selected_set = MapSet.new(selected)

      if MapSet.size(selected_set) != length(selected) or
           not MapSet.subset?(selected_set, option_values) do
        :invalid
      else
        initial_options = Enum.filter(options, &MapSet.member?(selected_set, &1["value"]))

        elements =
          Enum.map(elements, fn
            %{"type" => "checkboxes", "action_id" => ^action_id} = element ->
              put_initial_options(element, initial_options)

            element ->
              element
          end)

        {:ok, elements, initial_options}
      end
    end
  end

  defp coalesce_markdown_blocks(blocks) do
    blocks
    |> Enum.reduce([], fn
      %{"type" => "markdown", "text" => text},
      [
        %{"type" => "markdown", "text" => previous} | rest
      ] ->
        [%{"type" => "markdown", "text" => previous <> "\n\n" <> text} | rest]

      block, acc ->
        [block | acc]
    end)
    |> Enum.reverse()
  end

  defp put_initial_options(element, []), do: Map.delete(element, "initial_options")
  defp put_initial_options(element, options), do: Map.put(element, "initial_options", options)

  defp validate_markdown_limit(blocks) do
    length =
      blocks
      |> Enum.filter(&(&1["type"] == "markdown"))
      |> Enum.map(&String.length(&1["text"]))
      |> Enum.sum()

    if length <= @markdown_limit, do: :ok, else: {:error, :markdown_too_long}
  end

  defp validate_table_character_limit(blocks) do
    character_count =
      blocks
      |> Enum.filter(&(&1["type"] == "table"))
      |> Enum.map(&Map.fetch!(&1, @table_character_count_key))
      |> Enum.sum()

    if character_count <= @table_character_limit,
      do: :ok,
      else: {:error, :table_too_large}
  end

  defp strip_table_character_counts(blocks) do
    Enum.map(blocks, &Map.delete(&1, @table_character_count_key))
  end

  defp digest(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
