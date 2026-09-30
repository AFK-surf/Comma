defmodule SalixAgent.ToolResultProjection do
  @moduledoc """
  Pure planning for lossless, budgeted tool-result projection.

  A candidate keeps the exact JSON serialization of the content that would
  otherwise be shown to the model. `plan/3` measures the caller's complete
  model envelope and replaces the largest ordinary contents with compact
  reader capsules until that serialized envelope fits the shared byte budget.
  Existing reader pages are never spilled recursively: when capsules alone
  are insufficient, their page bodies are resized against that same exact
  envelope.

  This module does not mint references, write storage, or read the clock. The
  caller owns those effects and supplies a stable, session-owned opaque
  `result_ref` before preparing a candidate.
  """

  @encoding "json"
  @reader_tool "tool_call.get_result"
  @model_envelope_max_bytes 120_000

  @doc "Shared serialized-byte budget for projected tool-result envelopes and reader pages."
  @spec model_envelope_max_bytes() :: pos_integer()
  def model_envelope_max_bytes, do: @model_envelope_max_bytes

  @typedoc "A prepared result and its exact, recoverable content serialization."
  @type candidate :: %{
          required(:result) => map(),
          required(:result_ref) => String.t(),
          required(:tool_call_id) => String.t() | nil,
          required(:tool_name) => String.t(),
          required(:status) => String.t(),
          required(:is_error) => boolean(),
          required(:result_json) => binary(),
          required(:result_sha256) => String.t(),
          required(:result_bytes) => non_neg_integer(),
          required(:result_chars) => non_neg_integer()
        }

  @typedoc "A successful whole-envelope projection plan."
  @type plan :: %{
          required(:projected_results) => [map()],
          required(:stored_events) => [map()],
          required(:envelope) => term(),
          required(:envelope_bytes) => non_neg_integer()
        }

  @doc """
  Prepare one complete tool result for deterministic projection.

  The content is normalized with `to_string/1`, matching the existing tool
  result boundary. Its `Jason.encode!/1` output is retained verbatim so later
  storage and hashing cannot silently serialize a different value.
  """
  @spec prepare(map(), String.t()) :: {:ok, candidate()} | {:error, term()}
  def prepare(result, result_ref) when is_map(result) do
    with :ok <- validate_ref(result_ref),
         {:ok, tool_name} <- tool_name(result) do
      prepare_candidate(result, result_ref, tool_name)
    end
  end

  def prepare(_result, _result_ref), do: {:error, :invalid_tool_result}

  @doc """
  Prepare a candidate with an explicit tool name.

  This form is useful at seams which still hold the canonical call name
  separately from the result map.
  """
  @spec prepare(String.t(), map(), String.t()) :: {:ok, candidate()} | {:error, term()}
  def prepare(tool_name, result, result_ref) when is_binary(tool_name) and is_map(result) do
    with :ok <- validate_tool_name(tool_name),
         :ok <- validate_ref(result_ref) do
      prepare_candidate(result, result_ref, tool_name)
    end
  end

  def prepare(_tool_name, _result, _result_ref), do: {:error, :invalid_tool_result}

  @doc "Return the compact, JSON-encodable model-facing reader capsule."
  @spec capsule(candidate()) :: map()
  def capsule(candidate) do
    %{
      "stored_result" => true,
      "result_ref" => candidate.result_ref,
      "encoding" => @encoding,
      "bytes" => candidate.result_bytes,
      "chars" => candidate.result_chars,
      "sha256" => candidate.result_sha256,
      "tool_name" => candidate.tool_name,
      "get_result" => %{
        "tool" => @reader_tool,
        "arguments" => %{
          "result_ref" => candidate.result_ref,
          "offset" => 0
        }
      }
    }
  end

  @doc false
  @spec capsule_result(candidate()) :: map()
  def capsule_result(candidate) do
    capsule_content = Jason.encode!(capsule(candidate))
    original_content = field(candidate.result, :content)

    candidate.result
    |> put_content(capsule_content)
    |> project_duplicate_content_fields(original_content, capsule_content)
  end

  @doc "Return deterministic event data for durably storing a spilled result."
  @spec stored_event(candidate()) :: map()
  def stored_event(candidate) do
    %{
      "type" => "tool_result_stored",
      "result_ref" => candidate.result_ref,
      "tool_call_id" => candidate.tool_call_id,
      "tool_name" => candidate.tool_name,
      "result_json" => candidate.result_json,
      "result_sha256" => candidate.result_sha256,
      "result_bytes" => candidate.result_bytes,
      "result_chars" => candidate.result_chars,
      "status" => candidate.status,
      "is_error" => candidate.is_error
    }
    |> then(fn event ->
      case field(candidate.result, :ifc) do
        %{} = ifc -> Map.put(event, "ifc", ifc)
        _ -> event
      end
    end)
  end

  @doc """
  Plan one batch against the caller's complete serialized model envelope.

  Results remain in their original order. If the full envelope is too large,
  candidates are spilled by descending canonical byte size; original position
  breaks ties. Returned stored events are ordered like the original batch.

  `envelope_fun` must be deterministic and return a Jason-encodable term.
  """
  @spec plan([candidate()], ([map()] -> term()), pos_integer()) ::
          {:ok, plan()}
          | {:error, {:minimum_envelope_exceeds_budget, map()}}
          | {:error, :invalid_budget | :invalid_candidates}
  def plan(candidates, envelope_fun, budget)
      when is_list(candidates) and is_function(envelope_fun, 1) and is_integer(budget) and
             budget > 0 do
    if Enum.all?(candidates, &candidate?/1) do
      projected_results = Enum.map(candidates, & &1.result)
      {envelope, envelope_bytes} = encode_envelope(envelope_fun, projected_results)

      if envelope_bytes <= budget do
        {:ok,
         %{
           projected_results: projected_results,
           stored_events: [],
           envelope: envelope,
           envelope_bytes: envelope_bytes
         }}
      else
        spill_to_budget(candidates, envelope_fun, budget)
      end
    else
      {:error, :invalid_candidates}
    end
  end

  def plan(candidates, envelope_fun, _budget)
      when is_list(candidates) and is_function(envelope_fun, 1),
      do: {:error, :invalid_budget}

  def plan(_candidates, _envelope_fun, _budget), do: {:error, :invalid_candidates}

  defp prepare_candidate(result, result_ref, tool_name) do
    original_content = field(result, :content)
    content = normalize_content(original_content)
    result_json = Jason.encode!(content)
    is_error = field(result, :error) == true

    result =
      result
      |> put_content(content)
      |> project_duplicate_content_fields(original_content, content)

    {:ok,
     %{
       result: result,
       result_ref: result_ref,
       tool_call_id: optional_string(field(result, :tool_call_id) || field(result, :id)),
       tool_name: tool_name,
       status:
         optional_string(field(result, :status) || field(result, :status_hint)) ||
           if(is_error, do: "error", else: "completed"),
       is_error: is_error,
       result_json: result_json,
       result_sha256: sha256(result_json),
       result_bytes: byte_size(result_json),
       result_chars: String.length(result_json)
     }}
  end

  defp spill_to_budget(candidates, envelope_fun, budget) do
    projected_results = Enum.map(candidates, & &1.result)
    reader_pages = reader_pages(candidates)
    reader_indexes = MapSet.new(reader_pages, & &1.index)

    candidates
    |> Enum.with_index()
    |> Enum.reject(fn {_candidate, index} -> MapSet.member?(reader_indexes, index) end)
    |> Enum.sort_by(fn {candidate, index} -> {-candidate.result_bytes, index} end)
    |> Enum.reduce_while({projected_results, []}, fn {candidate, index}, {projected, stored} ->
      projected = List.replace_at(projected, index, capsule_result(candidate))
      stored = [{index, stored_event(candidate)} | stored]
      {envelope, envelope_bytes} = encode_envelope(envelope_fun, projected)

      if envelope_bytes <= budget do
        {:halt,
         {:ok,
          %{
            projected_results: projected,
            stored_events: ordered_events(stored),
            envelope: envelope,
            envelope_bytes: envelope_bytes
          }}}
      else
        {:cont, {projected, stored}}
      end
    end)
    |> case do
      {:ok, _plan} = ok ->
        ok

      {spilled_results, stored} ->
        resize_reader_pages(
          reader_pages,
          spilled_results,
          stored,
          envelope_fun,
          budget
        )
    end
  end

  defp resize_reader_pages([], minimum_results, _stored, envelope_fun, budget),
    do: minimum_envelope_error(minimum_results, envelope_fun, budget)

  defp resize_reader_pages(reader_pages, spilled_results, stored, envelope_fun, budget) do
    minimum_results =
      Enum.reduce(reader_pages, spilled_results, fn reader_page, projected ->
        resize_reader_result(projected, reader_page, reader_page.minimum_chars)
      end)

    {minimum_envelope, minimum_bytes} = encode_envelope(envelope_fun, minimum_results)

    if minimum_bytes > budget do
      {:error,
       {:minimum_envelope_exceeds_budget,
        %{
          budget: budget,
          envelope_bytes: minimum_bytes,
          envelope: minimum_envelope
        }}}
    else
      {projected_results, envelope, envelope_bytes} =
        Enum.reduce(
          reader_pages,
          {minimum_results, minimum_envelope, minimum_bytes},
          fn reader_page, {projected, _envelope, _envelope_bytes} ->
            content_chars =
              largest_fitting_reader_chars(
                projected,
                reader_page,
                envelope_fun,
                budget,
                reader_page.minimum_chars,
                reader_page.maximum_chars
              )

            projected = resize_reader_result(projected, reader_page, content_chars)
            {envelope, envelope_bytes} = encode_envelope(envelope_fun, projected)
            {projected, envelope, envelope_bytes}
          end
        )

      {:ok,
       %{
         projected_results: projected_results,
         stored_events: ordered_events(stored),
         envelope: envelope,
         envelope_bytes: envelope_bytes
       }}
    end
  end

  defp minimum_envelope_error(minimum_results, envelope_fun, budget) do
    {minimum_envelope, minimum_bytes} = encode_envelope(envelope_fun, minimum_results)

    {:error,
     {:minimum_envelope_exceeds_budget,
      %{
        budget: budget,
        envelope_bytes: minimum_bytes,
        envelope: minimum_envelope
      }}}
  end

  defp reader_pages(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.flat_map(fn {candidate, index} ->
      case reader_page(candidate, index) do
        {:ok, reader_page} -> [reader_page]
        :error -> []
      end
    end)
  end

  defp reader_page(%{tool_name: @reader_tool, result: result}, index) do
    with content when is_binary(content) <- field(result, :content),
         {:ok, %{"result_page" => page} = envelope} when is_map(page) <- Jason.decode(content),
         page_content when is_binary(page_content) <- page["content"],
         offset when is_integer(offset) and offset >= 0 <- page["offset"],
         total_chars when is_integer(total_chars) and total_chars >= 0 <- page["total_chars"] do
      remaining_chars = max(total_chars - offset, 0)
      maximum_chars = String.length(page_content)
      minimum_chars = if remaining_chars > 0, do: 1, else: 0

      if maximum_chars >= minimum_chars and maximum_chars <= remaining_chars do
        {:ok,
         %{
           index: index,
           envelope: envelope,
           page: page,
           page_content: page_content,
           offset: offset,
           total_chars: total_chars,
           minimum_chars: minimum_chars,
           maximum_chars: maximum_chars
         }}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp reader_page(_candidate, _index), do: :error

  defp resize_reader_result(projected_results, reader_page, content_chars) do
    List.update_at(projected_results, reader_page.index, fn result ->
      resized_content = reader_page_content(reader_page, content_chars)
      original_content = field(result, :content)

      result
      |> put_content(resized_content)
      |> project_duplicate_content_fields(original_content, resized_content)
    end)
  end

  defp reader_page_content(reader_page, content_chars) do
    content = String.slice(reader_page.page_content, 0, content_chars)
    actual_chars = String.length(content)
    next_offset = reader_page.offset + actual_chars

    page =
      reader_page.page
      |> Map.put("content", content)
      |> Map.put("content_chars", actual_chars)
      |> Map.put(
        "truncated",
        reader_page.offset > 0 or next_offset < reader_page.total_chars
      )

    page =
      if next_offset < reader_page.total_chars do
        Map.put(page, "next_offset", next_offset)
      else
        Map.delete(page, "next_offset")
      end

    reader_page.envelope
    |> Map.put("result_page", page)
    |> Jason.encode!()
  end

  defp largest_fitting_reader_chars(
         _projected,
         _reader_page,
         _envelope_fun,
         _budget,
         content_chars,
         content_chars
       ),
       do: content_chars

  defp largest_fitting_reader_chars(
         projected,
         reader_page,
         envelope_fun,
         budget,
         low,
         high
       ) do
    mid = div(low + high + 1, 2)
    candidate_results = resize_reader_result(projected, reader_page, mid)
    {_envelope, envelope_bytes} = encode_envelope(envelope_fun, candidate_results)

    if envelope_bytes <= budget do
      largest_fitting_reader_chars(
        projected,
        reader_page,
        envelope_fun,
        budget,
        mid,
        high
      )
    else
      largest_fitting_reader_chars(
        projected,
        reader_page,
        envelope_fun,
        budget,
        low,
        mid - 1
      )
    end
  end

  defp encode_envelope(envelope_fun, results) do
    envelope = envelope_fun.(results)
    {envelope, envelope |> Jason.encode!() |> byte_size()}
  end

  defp ordered_events(stored) do
    stored
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp candidate?(candidate) when is_map(candidate) do
    is_map(candidate[:result]) and is_binary(candidate[:result_ref]) and
      is_binary(candidate[:tool_name]) and is_binary(candidate[:result_json]) and
      is_binary(candidate[:result_sha256]) and is_integer(candidate[:result_bytes]) and
      is_integer(candidate[:result_chars])
  end

  defp candidate?(_candidate), do: false

  defp tool_name(result) do
    case optional_string(field(result, :tool_name) || field(result, :name)) do
      nil ->
        {:error, :missing_tool_name}

      name ->
        if(validate_tool_name(name) == :ok, do: {:ok, name}, else: {:error, :invalid_tool_name})
    end
  end

  defp validate_tool_name(name) when is_binary(name) do
    if name != "" and String.valid?(name), do: :ok, else: {:error, :invalid_tool_name}
  end

  defp validate_tool_name(_name), do: {:error, :invalid_tool_name}

  defp validate_ref(result_ref) when is_binary(result_ref) do
    if result_ref != "" and String.valid?(result_ref),
      do: :ok,
      else: {:error, :invalid_result_ref}
  end

  defp validate_ref(_result_ref), do: {:error, :invalid_result_ref}

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content), do: to_string(content)

  defp put_content(result, content) do
    cond do
      Map.has_key?(result, :content) -> Map.put(result, :content, content)
      Map.has_key?(result, "content") -> Map.put(result, "content", content)
      true -> Map.put(result, :content, content)
    end
  end

  # Tool execution records model-visible content again in `output`, and sync
  # failures also repeat it in `error_message`. Keep only those exact
  # duplicates aligned with the projected content; independent diagnostics
  # must remain untouched.
  defp project_duplicate_content_fields(result, original_content, projected_content) do
    Enum.reduce([:output, :error_message], result, fn key, projected ->
      if has_field?(projected, key) and field(projected, key) == original_content do
        put_field(projected, key, projected_content)
      else
        projected
      end
    end)
  end

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp has_field?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp put_field(map, key, value) do
    if Map.has_key?(map, key) do
      Map.put(map, key, value)
    else
      Map.put(map, Atom.to_string(key), value)
    end
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
