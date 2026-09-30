defmodule BridgeForTeams.SourcedContext.ProcessorOutput do
  @moduledoc false

  alias BridgeForTeams.SourcedContext.CanonicalJSON

  @kinds ~w(person project decision context)
  @entity_kinds ~w(person project)
  @warning_codes ~w(ambiguous_items dropped_items truncated_items unsupported_items)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @type normalized_artifact :: %{String.t() => term()}

  @spec normalize(term(), MapSet.t(Ecto.UUID.t()), keyword()) ::
          {:ok,
           %{
             artifacts: [normalized_artifact()],
             warnings: map(),
             output_sha256: String.t()
           }}
          | {:error, term()}
  def normalize(result, source_object_ids, opts)
      when is_struct(source_object_ids, MapSet) and is_list(opts) do
    max_artifacts = Keyword.fetch!(opts, :max_artifacts)
    max_sources = Keyword.fetch!(opts, :max_sources_per_artifact)
    max_payload_bytes = Keyword.fetch!(opts, :max_payload_bytes)
    max_warnings_bytes = Keyword.fetch!(opts, :max_warnings_bytes)

    with artifacts when is_list(artifacts) <- value(result, :artifacts),
         true <- length(artifacts) <= max_artifacts,
         {:ok, artifacts} <-
           normalize_artifacts(artifacts, source_object_ids,
             max_sources: max_sources,
             max_payload_bytes: max_payload_bytes
           ),
         :ok <- unique_artifact_identities(artifacts),
         :ok <- validate_about_references(artifacts),
         {:ok, warnings} <- normalize_warnings(value(result, :warnings, %{}), max_warnings_bytes),
         output = %{"artifacts" => artifacts, "warnings" => warnings},
         {:ok, output_bytes} <- CanonicalJSON.encode(output),
         output_sha256 = CanonicalJSON.sha256(output_bytes),
         true <- Regex.match?(@sha256, output_sha256) do
      {:ok, %{artifacts: artifacts, warnings: warnings, output_sha256: output_sha256}}
    else
      false -> {:error, :processor_output_bound_exceeded}
      nil -> {:error, :artifacts_required}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_processor_output}
    end
  end

  def normalize(_result, _source_object_ids, _opts),
    do: {:error, :invalid_processor_output}

  defp normalize_artifacts(artifacts, source_object_ids, opts) do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
      case normalize_artifact(artifact, source_object_ids, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok, Enum.sort_by(normalized, &{&1["kind"], &1["stable_key"]})}

      error ->
        error
    end
  end

  defp normalize_artifact(artifact, source_object_ids, opts) when is_map(artifact) do
    with {:ok, kind} <- kind(value(artifact, :kind)),
         {:ok, stable_key} <- stable_key(value(artifact, :stable_key)),
         {:ok, confidence_millis} <- confidence(value(artifact, :confidence_millis)),
         :ok <- reject_core_mapping(artifact),
         {:ok, sources} <-
           sources(
             value(artifact, :source_object_ids),
             source_object_ids,
             Keyword.fetch!(opts, :max_sources)
           ),
         {:ok, payload} <- payload(kind, value(artifact, :payload)),
         {:ok, payload_bytes} <- CanonicalJSON.encode(payload),
         true <- byte_size(payload_bytes) <= Keyword.fetch!(opts, :max_payload_bytes) do
      {:ok,
       %{
         "kind" => kind,
         "stable_key" => stable_key,
         "payload" => payload,
         "confidence_millis" => confidence_millis,
         "source_object_ids" => sources
       }}
    else
      false -> {:error, :artifact_payload_bound_exceeded}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_artifact}
    end
  end

  defp normalize_artifact(_artifact, _source_object_ids, _opts),
    do: {:error, :invalid_artifact}

  defp kind(kind) when is_atom(kind), do: kind(Atom.to_string(kind))

  defp kind(kind) when is_binary(kind) do
    normalized = String.trim(kind)
    if normalized in @kinds, do: {:ok, normalized}, else: {:error, :invalid_artifact_kind}
  end

  defp kind(_kind), do: {:error, :invalid_artifact_kind}

  defp stable_key(value) when is_binary(value) do
    normalized = String.trim(value)

    if normalized != "" and byte_size(normalized) <= 256 and
         Regex.match?(~r/\A[a-z][a-z0-9_.:-]*\z/, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_artifact_stable_key}
    end
  end

  defp stable_key(_value), do: {:error, :invalid_artifact_stable_key}

  defp confidence(value) when is_integer(value) and value in 0..1000, do: {:ok, value}
  defp confidence(_value), do: {:error, :invalid_artifact_confidence}

  # Model output is not identity authority. Mapping an extracted candidate to a
  # core User/Project requires a later explicit review contract.
  defp reject_core_mapping(artifact) do
    if is_nil(value(artifact, :mapped_user_id)) and
         is_nil(value(artifact, :mapped_project_id)) do
      :ok
    else
      {:error, :core_entity_mapping_requires_review}
    end
  end

  defp sources(values, known_ids, max_sources)
       when is_list(values) and values != [] and length(values) <= max_sources do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Ecto.UUID.cast(value) do
        {:ok, id} ->
          if MapSet.member?(known_ids, id),
            do: {:cont, {:ok, [id | acc]}},
            else: {:halt, {:error, :artifact_source_outside_snapshot}}

        :error ->
          {:halt, {:error, :invalid_artifact_source}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp sources(_values, _known_ids, _max_sources),
    do: {:error, :artifact_sources_required}

  defp payload(kind, payload) when kind in @entity_kinds and is_map(payload) do
    with :ok <- exact_keys(payload, ~w(name aliases)),
         {:ok, name} <- display_string(value(payload, :name), 256, :invalid_entity_name),
         {:ok, aliases} <- aliases(value(payload, :aliases, []), name) do
      {:ok, %{"name" => name, "aliases" => aliases}}
    end
  end

  defp payload(kind, payload) when kind in ["decision", "context"] and is_map(payload) do
    with :ok <- exact_keys(payload, ~w(content about)),
         {:ok, content} <-
           display_string(value(payload, :content), 8_000, :invalid_artifact_content),
         {:ok, about} <- about(value(payload, :about)) do
      {:ok, %{"content" => content, "about" => about}}
    end
  end

  defp payload(_kind, _payload), do: {:error, :invalid_artifact_payload}

  defp aliases(values, name) when is_list(values) and length(values) <= 20 do
    values
    |> Enum.reduce_while({:ok, [name]}, fn value, {:ok, acc} ->
      case display_string(value, 256, :invalid_entity_alias) do
        {:ok, alias_value} -> {:cont, {:ok, [alias_value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok,
         normalized
         |> Enum.uniq_by(&String.downcase/1)
         |> Enum.sort_by(&String.downcase/1)}

      error ->
        error
    end
  end

  defp aliases(_values, _name), do: {:error, :invalid_entity_aliases}

  defp about(values) when is_list(values) and values != [] and length(values) <= 20 do
    values
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, acc} ->
      with true <- is_map(reference),
           {:ok, kind} <- entity_kind(value(reference, :kind)),
           {:ok, stable_key} <- stable_key(value(reference, :stable_key)) do
        {:cont, {:ok, [%{"kind" => kind, "stable_key" => stable_key} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_artifact_about}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok, normalized |> Enum.uniq() |> Enum.sort_by(&{&1["kind"], &1["stable_key"]})}

      error ->
        error
    end
  end

  defp about(_values), do: {:error, :artifact_about_required}

  defp entity_kind(kind) when is_atom(kind), do: entity_kind(Atom.to_string(kind))
  defp entity_kind(kind) when kind in @entity_kinds, do: {:ok, kind}
  defp entity_kind(_kind), do: {:error, :invalid_entity_reference}

  defp exact_keys(map, allowed) do
    keys =
      map
      |> Map.keys()
      |> Enum.map(fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _key -> :invalid
      end)

    if :invalid not in keys and Enum.sort(keys) == Enum.sort(allowed),
      do: :ok,
      else: {:error, :invalid_artifact_payload_fields}
  end

  defp unique_artifact_identities(artifacts) do
    identities = Enum.map(artifacts, &{&1["kind"], &1["stable_key"]})

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: {:error, :duplicate_artifact_identity}
  end

  defp validate_about_references(artifacts) do
    entities =
      artifacts
      |> Enum.filter(&(&1["kind"] in @entity_kinds))
      |> MapSet.new(&{&1["kind"], &1["stable_key"]})

    artifacts
    |> Enum.filter(&(&1["kind"] in ["decision", "context"]))
    |> Enum.reduce_while(:ok, fn artifact, :ok ->
      if Enum.all?(artifact["payload"]["about"], fn reference ->
           MapSet.member?(entities, {reference["kind"], reference["stable_key"]})
         end) do
        {:cont, :ok}
      else
        {:halt, {:error, :artifact_about_outside_derivation}}
      end
    end)
  end

  defp normalize_warnings(warnings, max_bytes) when is_map(warnings) do
    with {:ok, warnings} <- finite_warning_counts(warnings),
         {:ok, bytes} <- CanonicalJSON.encode(warnings),
         true <- byte_size(bytes) <= max_bytes do
      {:ok, warnings}
    else
      false -> {:error, :processor_warnings_bound_exceeded}
      {:error, _reason} -> {:error, :invalid_processor_warnings}
    end
  end

  defp normalize_warnings(_warnings, _max_bytes),
    do: {:error, :invalid_processor_warnings}

  defp finite_warning_counts(warnings) do
    Enum.reduce_while(warnings, {:ok, %{}}, fn {key, count}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if key in @warning_codes and is_integer(count) and count in 0..1_000_000 do
        {:cont, {:ok, Map.put(acc, key, count)}}
      else
        {:halt, {:error, :invalid_processor_warnings}}
      end
    end)
  end

  defp display_string(value, max_bytes, error) when is_binary(value) do
    normalized = String.trim(value)

    if normalized != "" and byte_size(normalized) <= max_bytes,
      do: {:ok, normalized},
      else: {:error, error}
  end

  defp display_string(_value, _max_bytes, error), do: {:error, error}

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp value(_map, _key, default), do: default
end
