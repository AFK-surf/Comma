defmodule SalixAgent.Tools.Recommendations do
  @moduledoc false

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"recommendation.read",
       "Read the current owner Routine snapshot and freshness state without fetching sources or starting a run. Missing or stale evidence is not proof of no work. Reuse selected items; do not repeat source relevance filtering.",
       read_schema(), &__MODULE__.read/2, @normal_auto_wait_seconds,
       [safety: "read", roles: ["router"], runtimes: [:internal]]},
      {"recommendation.begin",
       "Begin the scheduled Comma Center recommendation run and return its run id, source revision, enabled sources, and catalog contract. If status is skipped, no run exists. End the turn with outcome=blocked and a short reason. Do not retry or call recommendation.fail.",
       empty_schema(), &__MODULE__.begin_run/2, @normal_auto_wait_seconds},
      {"recommendation.publish",
       "Validate and publish the completed Comma Center recommendation snapshot for the current recommendation run. Read help for the complete snapshot schema before first use; call once after collecting the enabled sources.",
       publish_schema(), &__MODULE__.publish/2, @normal_auto_wait_seconds},
      {"recommendation.fail",
       "Finish an existing Comma Center recommendation run as failed when its facts cannot produce a usable result. Use only its returned run id. Never invent an id or call this tool after recommendation.begin returns skipped.",
       fail_schema(), &__MODULE__.fail/2, @normal_auto_wait_seconds}
    ]
  end

  def read(args, ctx) do
    case adapter().read(args, ctx) do
      {:ok, result} -> SalixAgent.IFC.ConnectorLabels.group_audience(Jason.encode!(result), ctx)
      {:error, reason} -> raise "recommendation read rejected: #{inspect(reason)}"
    end
  end

  def begin_run(_args, ctx) do
    case adapter() do
      nil ->
        raise "recommendation publisher is not configured"

      module ->
        case module.begin_run(ctx) do
          {:ok, result} -> Jason.encode!(result)
          {:error, reason} -> raise "recommendation run rejected: #{inspect(reason)}"
        end
    end
  end

  def publish(%{"run_id" => run_id, "snapshot" => snapshot}, ctx)
      when is_binary(run_id) and is_map(snapshot) do
    case adapter() do
      nil ->
        raise "recommendation publisher is not configured"

      module ->
        case module.publish(ctx, run_id, snapshot) do
          {:ok, result} -> Jason.encode!(result)
          {:error, reason} -> raise "recommendation publish rejected: #{inspect(reason)}"
        end
    end
  end

  def publish(_args, _ctx), do: raise("run_id and snapshot are required")

  def fail(%{"run_id" => run_id, "reason" => reason}, ctx)
      when is_binary(run_id) and is_binary(reason) do
    case adapter() do
      nil ->
        raise "recommendation publisher is not configured"

      module ->
        case module.fail(ctx, run_id, reason) do
          {:ok, result} -> Jason.encode!(result)
          {:error, failure} -> raise "recommendation failure rejected: #{inspect(failure)}"
        end
    end
  end

  def fail(_args, _ctx), do: raise("run_id and reason are required")

  defp adapter,
    do: Application.get_env(:salix_agent, :recommendation_adapter_mod)

  defp read_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [],
      "properties" => %{
        "source_id" => bounded_string(128),
        "source_url" => bounded_string(65_536),
        "scope" => %{"type" => "string", "enum" => ["status"]}
      },
      "description" =>
        "Use {} for the bounded published overview, {scope: status} for a current failure, or source_id and source_url from an attention_items read recipe for that exact selected matter. This reads published Routine evidence, not live provider state."
    }
  end

  defp publish_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "run_id" => %{"type" => "string", "description" => "Opaque run id from the request."},
        "snapshot" => %{
          "type" => "object",
          "description" =>
            "Complete snapshot matching the recommendation template catalog. Summary is the document-parts array itself: a greeting-only first markdown paragraph of at most 48 characters, followed by one to four short body paragraphs, one thought each in one or two plain sentences with the most pressing item first (target two to four when that many distinct threads are available), normally one inline-link part per paragraph on its exact source URL; the cards carry the full item list. New paragraphs begin with an empty line in their markdown text: two real newline characters, never a backslash-n spelled out as text, and never HTML such as <a> or <br> - every link is an inline-link part. Never use an object wrapper.",
          "additionalProperties" => false,
          "properties" => %{
            "protocolVersion" => %{"type" => "integer", "enum" => [1]},
            "templateCatalogVersion" => %{"type" => "integer", "enum" => [1]},
            "generatedAt" => %{"type" => "integer", "minimum" => 0},
            "generation" => %{"type" => "integer", "minimum" => 1},
            "sourceRevision" => %{"type" => "integer", "minimum" => 0},
            "summary" => document_schema(),
            "cards" => %{
              "type" => "array",
              "maxItems" => 6,
              "description" =>
                "Cards matching text-list@1 or media-list@1 exactly as defined by the catalog: one routine card per source with a stable id (the toolkit name) and the app's own name as title, at most six cards and eighteen rows in all (three rows each with six cards), and one-line pre-task rows (an imperative Task-style line with the entity as an inline-link) whose action is that task and whose prompt opens with why it needs the user now.",
              "items" => %{"oneOf" => [card_schema("text-list@1"), card_schema("media-list@1")]}
            },
            "warnings" => %{
              "type" => "array",
              "maxItems" => 12,
              "items" => warning_schema()
            }
          },
          "required" => [
            "protocolVersion",
            "templateCatalogVersion",
            "generatedAt",
            "generation",
            "sourceRevision",
            "summary",
            "cards",
            "warnings"
          ]
        }
      },
      "required" => ["run_id", "snapshot"]
    }
  end

  # This describes the existing publication contract; validation and evidence
  # ownership remain in Comma.RecommendationContract. An untyped item object left
  # renderers guessing the action discriminator and adding item-level sourceIds.
  defp card_schema(template) do
    properties = %{
      "id" => bounded_string(128),
      "template" => %{"type" => "string", "enum" => [template]},
      "title" => bounded_string(80),
      "fallbackText" => bounded_string(1_200),
      "sourceIds" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 12,
        "items" => bounded_string(256)
      },
      "items" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 4,
        "items" => item_schema(template)
      }
    }

    properties =
      if template == "text-list@1",
        do: Map.put(properties, "footerAction", action_schema()),
        else: properties

    closed_object(properties, ~w(id template title fallbackText sourceIds items))
  end

  defp item_schema("text-list@1") do
    closed_object(
      %{"id" => bounded_string(128), "parts" => document_schema(), "action" => action_schema()},
      ~w(id parts action)
    )
  end

  defp item_schema("media-list@1") do
    closed_object(
      %{
        "id" => bounded_string(128),
        "title" => bounded_string(160),
        "description" => %{"type" => "string", "maxLength" => 240},
        "imageUrl" => %{"type" => "string", "description" => "Credential-free absolute HTTPS URL"},
        "action" => action_schema()
      },
      ~w(id title imageUrl action)
    )
  end

  defp action_schema do
    %{
      "description" =>
        "A flat action object. The required type field selects the action; never nest it under an action-name key.",
      "oneOf" => Enum.map(~w(open_url open_task_form send_to_comma), &action_schema/1)
    }
  end

  defp action_schema(type) do
    target = if type == "open_url", do: "href", else: "prompt"

    confirmation =
      case type do
        "open_url" -> %{"type" => "boolean", "enum" => [false]}
        "send_to_comma" -> %{"type" => "boolean", "enum" => [true]}
        "open_task_form" -> %{"type" => "boolean"}
      end

    target_schema =
      if target == "href",
        do: %{
          "type" => "string",
          "description" => "Exact absolute HTTP(S) URL from supplied facts"
        },
        else: bounded_string(1_200)

    closed_object(
      %{
        "type" => %{"type" => "string", "enum" => [type]},
        "label" => bounded_string(80),
        "requiresConfirmation" => confirmation,
        target => target_schema
      },
      ["type", "label", "requiresConfirmation", target]
    )
  end

  defp closed_object(properties, required),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }

  defp bounded_string(max_length),
    do: %{"type" => "string", "minLength" => 1, "maxLength" => max_length}

  defp fail_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "run_id" => %{"type" => "string", "minLength" => 1},
        "reason" => %{"type" => "string", "minLength" => 1, "maxLength" => 240}
      },
      "required" => ["run_id", "reason"]
    }
  end

  defp document_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 24,
      "description" => "A non-empty array of document parts, not {parts: [...]}",
      "items" => %{
        "oneOf" => [
          %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["markdown"]},
              "text" => %{
                "type" => "string",
                "maxLength" => 1_200,
                "description" =>
                  "Markdown prose. A paragraph break is an empty line of two real newline characters; no HTML, and no links in the text - every link is a separate inline-link part."
              }
            },
            "required" => ["kind", "text"]
          },
          %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["inline-link"]},
              "link" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{
                  "href" => %{
                    "type" => "string",
                    "description" => "Exact absolute HTTP(S) URL from the supplied facts"
                  },
                  "label" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
                  "sourceId" => %{
                    "type" => "string",
                    "minLength" => 1,
                    "maxLength" => 128,
                    "description" => "The sourceId of the fact that supplied href"
                  }
                },
                "required" => ["href", "label", "sourceId"]
              }
            },
            "required" => ["kind", "link"]
          },
          %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["inline-task"]},
              "task" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{
                  "conversationId" => %{"type" => "string", "minLength" => 1},
                  "label" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
                  "sourceId" => %{"type" => "string", "maxLength" => 128},
                  "status" => %{"type" => "string", "maxLength" => 64}
                },
                "required" => ["conversationId", "label"]
              }
            },
            "required" => ["kind", "task"]
          }
        ]
      }
    }
  end

  defp warning_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "code" => %{
          "type" => "string",
          "enum" => ["partial_sources", "stale", "source_changed", "generation_failed"]
        },
        "message" => %{"type" => "string", "minLength" => 1, "maxLength" => 240},
        "sourceIds" => %{
          "type" => "array",
          "maxItems" => 12,
          "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 256}
        }
      },
      "required" => ["code", "message"]
    }
  end

  defp empty_schema,
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{},
      "required" => []
    }
end
