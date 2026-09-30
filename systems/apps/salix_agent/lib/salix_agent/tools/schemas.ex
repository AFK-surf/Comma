defmodule SalixAgent.Tools.Schemas do
  @moduledoc """
  Per-tool input schemas — the single source of truth for what the LLM is
  told about each tool's arguments.

  Contract (enforced by `schemas_test.exs`): every registry tool has an entry
  here, every `required` field is a declared property, and the schema mirrors
  the dispatcher's actual validation — an argument is `required` exactly when
  the handler rejects a call without it. Property descriptions follow willow's
  Go `InputSchema`s where the port matches; fields willow defines but Salix
  does not read are deliberately absent.

  Schema-carrying registry entries may carry their own schema map directly in
  the registry tuple; other registry entries are listed here.

  This replaces the early shared "permissive schema" (a generic property
  bag), which let server-side validation and the model-visible contract
  drift — e.g. `env.exec` required `description` while the schema didn't even
  list `command`. `salix_llm` converters now require explicit schemas too, so
  a schemaless tool spec fails before it reaches a provider request.
  """

  @meeting_trigger_kinds ["decision", "publication", "deadline_fence"]
  @exec_description_max_length 19
  @interaction_locale %{
    "type" => "string",
    "enum" => ["en", "zh-CN"],
    "description" =>
      "Infer from the current dialogue: zh-CN for Chinese, en for English. Controls Telegram card labels and completion, not option text or client language."
  }
  @schemas %{
    # ---- runtime meta ----
    "help" => %{
      "type" => "object",
      "properties" => %{
        "tool" => %{
          "type" => "string",
          "description" =>
            "Canonical tool name, dynamic operation id, or ifc for information-flow rules."
        }
      },
      "required" => ["tool"]
    },

    # ---- core (tools.ex @registry) ----
    "fs.write_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Visible file path to write. Supports ordinary VFS paths and writable session runtime files such as editable skills under /.runtime/skills."
        },
        "content" => %{"type" => "string", "description" => "File content (10MB cap)"}
      },
      "required" => ["path", "content"]
    },
    "fs.read_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "File path to read. Supports VFS files and session runtime files such as /.runtime/compaction-recovery.md and /.runtime/skills."
        },
        "vision_query" => %{
          "type" => "string",
          "description" =>
            "For images, ask the configured auxiliary vision model this question and return its text answer. Without an auxiliary model, return the image to the image-capable active model. Image input requires declared image support or a configured vision describer."
        },
        "start_line" => %{
          "type" => "integer",
          "description" =>
            "1-based first line for a paged text read. Cannot be used with tail_lines. Omit start_line, num_lines, and tail_lines for normal full read behavior.",
          "minimum" => 1
        },
        "num_lines" => %{
          "type" => "integer",
          "description" =>
            "Maximum lines to return for a forward paged text read. Defaults to 200 when start_line or num_lines is provided and is capped at 2000. Cannot be used with tail_lines.",
          "minimum" => 1,
          "maximum" => 2_000
        },
        "tail_lines" => %{
          "type" => "integer",
          "description" =>
            "Read the last N lines of a text file. Cannot be used with start_line or num_lines. Large text results keep head and tail content and report omitted middle characters.",
          "minimum" => 1,
          "maximum" => 2_000
        }
      },
      "required" => ["path"]
    },
    "fs.list_files" => %{
      "type" => "object",
      "properties" => %{
        "prefix" => %{
          "type" => "string",
          "description" => "Path prefix to list under; empty lists all visible file paths"
        }
      },
      "required" => []
    },
    "fs.delete_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Visible file path to delete (the body is retained)"
        }
      },
      "required" => ["path"]
    },
    "script.run" => %{
      "type" => "object",
      "properties" => %{
        "source" => %{
          "type" => "string",
          "description" =>
            "The C source of main.c: include \"spinfoam.h\", define SF_MAIN sf_i64 main(void), call tools with sf_host_call(\"salix.call\", {\"tool\": name, \"args\": {...}}, timeout_ms), set the return value with script.result {\"value\": ...}. See script.sdk."
        },
        "files" => %{
          "type" => "object",
          "description" =>
            "Optional additional headers: a map of relative file name to UTF-8 content (at most 32 files, 128 KiB in total). Never name a file spinfoam.h.",
          "additionalProperties" => %{"type" => "string"}
        }
      },
      "required" => ["source"]
    },
    "fs.edit_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Visible file path of the file to edit"},
        "old" => %{
          "type" => "string",
          "description" => "Existing text to find; only the first occurrence is replaced"
        },
        "new" => %{
          "type" => "string",
          # Without minLength 0 the shared required-param check rejects "".
          "minLength" => 0,
          "description" => "Replacement text (may be empty to delete)"
        }
      },
      "required" => ["path", "old", "new"]
    },
    "fs.copy_file" => %{
      "type" => "object",
      "properties" => %{
        "from" => %{"type" => "string", "description" => "Source visible file path"},
        "to" => %{"type" => "string", "description" => "Destination visible file path"}
      },
      "required" => ["from", "to"]
    },
    "fs.move_file" => %{
      "type" => "object",
      "properties" => %{
        "from" => %{"type" => "string", "description" => "Source visible file path"},
        "to" => %{"type" => "string", "description" => "Destination visible file path"}
      },
      "required" => ["from", "to"]
    },
    "fs.grep" => %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Regex pattern to search file contents for"
        },
        "prefix" => %{
          "type" => "string",
          "description" =>
            "Only search files whose visible path starts with this prefix; empty searches all files"
        }
      },
      "required" => ["pattern"]
    },
    "fs.glob" => %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" =>
            "Glob pattern matched against full visible file paths, e.g. '**/*.md' ('*' = within one segment, '**' = across segments, '?' = one char)"
        }
      },
      "required" => ["pattern"]
    },
    "drive.status" => %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    },
    "fs.stat_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Visible file path to stat; returns metadata"
        }
      },
      "required" => ["path"]
    },
    "web.search" => %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Specific and relevant search query for up-to-date web information"
        }
      },
      "required" => ["query"]
    },
    # ---- async ops ----
    "wait_for" => %{
      "type" => "object",
      "properties" => %{
        "reason" => %{
          "type" => "string",
          "description" =>
            "Clear user-facing description of what information or event has not arrived yet."
        },
        "timeout_seconds" => %{
          "type" => "integer",
          "description" =>
            "How long to wait before the agent is automatically woken to re-evaluate. Defaults to 60. Only use longer waits, up to 1800 seconds, for clearly explained long-running monitoring or background work.",
          "minimum" => 1,
          "maximum" => 1800
        }
      },
      "required" => ["reason"]
    },
    "tool_call.get_status" => %{
      "type" => "object",
      "properties" => %{
        "tool_call_id" => %{
          "type" => "string",
          "description" => "The tool_call_id returned by the original tool call."
        }
      },
      "required" => ["tool_call_id"]
    },
    "tool_call.get_result" => %{
      "type" => "object",
      "properties" => %{
        "tool_call_id" => %{
          "type" => "string",
          "description" =>
            "Legacy lookup key returned by an asynchronous tool call. Provide exactly one of tool_call_id or result_ref."
        },
        "result_ref" => %{
          "type" => "string",
          "description" =>
            "Opaque session-owned reference from a stored-result capsule. Provide exactly one of result_ref or tool_call_id."
        },
        "offset" => %{
          "type" => "integer",
          "description" =>
            "Zero-based character offset into the stored result's JSON encoding. Use result_page.next_offset to continue an oversized result.",
          "minimum" => 0
        },
        "limit" => %{
          "type" => "integer",
          "description" =>
            "Requested maximum JSON characters in result_page.content. Defaults to 120000; the actual page may contain fewer characters so the fully serialized response stays within 120000 bytes.",
          "minimum" => 1,
          "maximum" => 120_000
        }
      },
      "required" => [],
      "oneOf" => [
        %{"required" => ["result_ref"]},
        %{"required" => ["tool_call_id"]}
      ]
    },
    "tool_call.cancel" => %{
      "type" => "object",
      "properties" => %{
        "tool_call_id" => %{
          "type" => "string",
          "description" => "The tool_call_id returned by the original tool call."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Short reason why this tool call is no longer needed."
        }
      },
      "required" => ["tool_call_id"]
    },
    "question.request" => %{
      "type" => "object",
      "properties" => %{
        "locale" => @interaction_locale,
        "question" => %{"type" => "string"},
        "choices" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 8},
        "timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 1800}
      },
      "required" => ["question", "locale"]
    },
    "permission.request" => %{
      "type" => "object",
      "properties" => %{
        "locale" => @interaction_locale,
        "capability" => %{
          "type" => "string",
          "description" =>
            "Protected capability to request, e.g. host_access. The session pauses as waiting until the user grants it."
        },
        "description" => %{
          "type" => "string",
          "description" => "Short description of the action needing approval"
        }
      },
      "required" => ["capability"]
    },
    "location.request" => %{
      "type" => "object",
      "properties" => %{
        "locale" => @interaction_locale,
        "reason" => %{
          "type" => "string",
          "description" => "Short user-facing reason for requesting location."
        },
        "timeout_seconds" => %{
          "type" => "integer",
          "description" => "Validity window. Defaults 600 seconds, max 1800.",
          "minimum" => 1,
          "maximum" => 1800
        }
      },
      "required" => ["reason"]
    },

    # ---- skills ----
    "skill.create" => %{
      "type" => "object",
      "properties" => %{
        "skill_id" => %{
          "type" => "string",
          "description" => "Stable lower-case skill id used in /.runtime/skills/<skill_id>/."
        },
        "name" => %{
          "type" => "string",
          "description" => "Human-readable skill name."
        },
        "description" => %{
          "type" => "string",
          "description" => "Short description shown in the skill index."
        },
        "content" => %{
          "type" => "string",
          "description" =>
            "Optional initial SKILL.md content. If omitted, a minimal SKILL.md is created."
        }
      },
      "required" => ["skill_id", "name"]
    },
    "skill.copy" => %{
      "type" => "object",
      "properties" => %{
        "source_skill_id" => %{
          "type" => "string",
          "description" => "Visible skill id to copy."
        },
        "skill_id" => %{
          "type" => "string",
          "description" => "New lower-case skill id."
        },
        "name" => %{
          "type" => "string",
          "description" => "New display name for the copied editable skill."
        },
        "description" => %{
          "type" => "string",
          "description" => "Optional new description. Defaults to the source description."
        }
      },
      "required" => ["source_skill_id", "skill_id", "name"]
    },
    "skill.delete" => %{
      "type" => "object",
      "properties" => %{
        "skill_id" => %{
          "type" => "string",
          "description" => "Skill id to delete."
        }
      },
      "required" => ["skill_id"]
    },

    # ---- web ----
    "web.read_pages" => %{
      "type" => "object",
      "properties" => %{
        "urls" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Array of URLs to fetch contents from. Maximum 10 URLs per request. A comma-separated string is also accepted."
        },
        "url" => %{
          "type" => "string",
          "description" => "Single URL to fetch; alternative to urls."
        }
      },
      "required" => ["urls"]
    },
    "script.sdk" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{},
      "required" => []
    },
    "script.run_file" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the C source file (main.c) to compile and run"
        },
        "env" => %{
          "type" => "array",
          "description" =>
            "Key-value string entries the program reads from its config: sf_json_get(sf_json_get(sf_config(), \"env\"), name)",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{
                "type" => "string",
                "description" => "Entry name, e.g. USER_ID"
              },
              "value" => %{
                "type" => "string",
                "description" => "String value exposed at config.env[name]"
              }
            },
            "required" => ["name", "value"]
          }
        }
      },
      "required" => ["path"]
    },
    "web.http_request" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" =>
            "Absolute http or https URL of the API endpoint. No user:password part; only public hosts are reachable."
        },
        "method" => %{
          "type" => "string",
          "enum" => ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"],
          "description" => "HTTP method (default GET)."
        },
        "query" => %{
          "type" => "object",
          "description" =>
            "Query parameters appended to the URL, name to string/number/boolean value. Values may contain ${ENV_VAR} placeholders resolved from credential_env.",
          "additionalProperties" => %{"type" => ["string", "number", "boolean"]}
        },
        "headers" => %{
          "type" => "object",
          "description" =>
            "Request headers, name to value (at most 32). host, content-length, transfer-encoding, connection and proxy-* cannot be set. accept defaults to application/json. Values may contain ${ENV_VAR} placeholders resolved from credential_env, e.g. {\"authorization\": \"Bearer ${GH_TOKEN}\"}.",
          "additionalProperties" => %{"type" => ["string", "number", "boolean"]}
        },
        "body" => %{
          "description" =>
            "Request body. An object, array, number or boolean is sent JSON-encoded as application/json. A string is sent verbatim (set content-type in headers for anything but text/plain). Omit or pass null for no body. At most 1 MiB encoded."
        },
        "credential_env" => %{
          "type" => "array",
          "description" =>
            "Group-scoped OAuth credentials this request may use, the same references env.exec takes. Each entry binds one env_var name to a credential; write ${env_var} in a header or query value to insert it. The model never sees secret values.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "env_var" => %{
                "type" => "string",
                "description" => "Placeholder name used in headers or query, e.g. GH_TOKEN"
              },
              "provider" => %{
                "type" => "string",
                "description" => "OAuth provider name, e.g. github, linear, notion"
              },
              "alias" => %{
                "type" => "string",
                "description" => "Group-scoped alias chosen during authorization"
              },
              "value" => %{
                "type" => "string",
                "description" => "Credential value to insert (usually access_token)"
              }
            },
            "required" => ["env_var", "provider", "alias", "value"]
          }
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Time to wait for the response, 1000 to 60000 milliseconds (default 20000)."
        }
      },
      "required" => ["url"]
    },

    # ---- peers / environments ----
    "meeting.preparation.start_research" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "worker_agent_id" => %{"type" => "string"}
      },
      "required" => ["meeting_plan_id", "dispatch_revision"]
    },
    "meeting.preparation.open_trigger" => %{
      "type" => "object",
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "trigger_kind" => %{"type" => "string", "enum" => @meeting_trigger_kinds},
        "dispatch_revision" => %{"type" => "string"}
      },
      "required" => ["meeting_plan_id", "trigger_kind", "dispatch_revision"]
    },
    "meeting.preparation.record_decision" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "decision" => %{"type" => "string", "enum" => ["required", "not_required"]},
        "baseline" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "scope" => %{"type" => "string", "minLength" => 1, "maxLength" => 500},
            "known_facts" => %{
              "type" => "array",
              "maxItems" => 8,
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 500}
            },
            "gaps" => %{
              "type" => "array",
              "maxItems" => 8,
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 500}
            }
          },
          "required" => ["known_facts", "gaps"]
        }
      },
      "required" => ["meeting_plan_id", "dispatch_revision", "decision", "baseline"]
    },
    "meeting.preparation.publish_report" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "report" => %{"type" => "string", "minLength" => 1, "maxLength" => 16_000}
      },
      "required" => ["meeting_plan_id", "dispatch_revision", "report"]
    },
    "meeting.preparation.personal_context" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "cursor" => %{"type" => ["integer", "null"], "minimum" => 0, "maximum" => 2_147_483_647}
      },
      "required" => ["meeting_plan_id", "dispatch_revision"]
    },
    "meeting.preparation.read_status" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"}
      },
      "required" => ["meeting_plan_id", "dispatch_revision"]
    },
    "meeting.preparation.read_recipient" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "user_id" => %{"type" => "string", "pattern" => "^[UW][A-Z0-9]+$"}
      },
      "required" => ["meeting_plan_id", "dispatch_revision", "user_id"]
    },
    "meeting.preparation.publish_personal_report" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "connect_id" => %{"type" => "string"},
        "user_id" => %{"type" => "string"},
        "report" => %{"type" => "string", "minLength" => 0, "maxLength" => 4_000}
      },
      "required" => [
        "meeting_plan_id",
        "dispatch_revision",
        "connect_id",
        "user_id",
        "report"
      ]
    },
    "meeting.preparation.read_shared_source" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_plan_id" => %{"type" => "string"},
        "dispatch_revision" => %{"type" => "string"},
        "channel" => %{"type" => "string", "pattern" => "^C[A-Z0-9]+$"},
        "operation" => %{"type" => "string", "enum" => ["history", "replies", "search", "file"]},
        "file_id" => %{"type" => "string", "pattern" => "^F[A-Z0-9]+$"},
        "query" => %{"type" => "string", "maxLength" => 2000},
        "ts" => %{"type" => "string"},
        "cursor" => %{"type" => ["string", "null"], "maxLength" => 1024},
        "oldest" => %{"type" => "string"},
        "latest" => %{"type" => "string"}
      },
      "required" => ["meeting_plan_id", "dispatch_revision", "channel", "operation"]
    },
    "meeting.preparation.set_personal_reminders" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"enabled" => %{"type" => "boolean"}},
      "required" => ["enabled"]
    },
    "meeting.join" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meet_url" => %{
          "type" => "string",
          "description" =>
            "Optional Google Meet URL copied from the current human message or its exact bounded thread. The server rejects URLs outside that source."
        }
      },
      "required" => []
    },
    "meeting.read_summary_materials" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_id" => %{"type" => "string", "minLength" => 1},
        "request_id" => %{"type" => "string", "minLength" => 1},
        "field" => %{
          "type" => "string",
          "enum" => ["transcript", "captions_transcript", "asr_transcript"]
        },
        "offset" => %{"type" => "integer", "minimum" => 0}
      },
      "required" => ["meeting_id", "request_id"]
    },
    "meeting.submit_summary" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_id" => %{"type" => "string", "minLength" => 1},
        "request_id" => %{"type" => "string", "minLength" => 1},
        "summary" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" =>
            Map.merge(
              Map.new(~w(attendees key_points decisions open_questions blockers), fn field ->
                {field, %{"type" => "array", "maxItems" => 200, "items" => %{"type" => "string"}}}
              end),
              %{
                "title" => %{"type" => "string", "minLength" => 1},
                "timeline" => %{
                  "type" => "array",
                  "maxItems" => 200,
                  "items" => %{
                    "type" => "object",
                    "additionalProperties" => false,
                    "properties" => %{
                      "time" => %{"type" => "string"},
                      "summary" => %{"type" => "string"}
                    },
                    "required" => ["time", "summary"]
                  }
                },
                "action_items" => %{
                  "type" => "array",
                  "maxItems" => 200,
                  "items" => %{
                    "type" => "object",
                    "additionalProperties" => false,
                    "properties" =>
                      Map.new(~w(description owner deadline), &{&1, %{"type" => "string"}}),
                    "required" => ["description", "owner", "deadline"]
                  }
                }
              }
            ),
          "required" =>
            ~w(title attendees timeline key_points action_items decisions open_questions blockers)
        }
      },
      "required" => ["meeting_id", "request_id", "summary"]
    },
    "meeting.get" => %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "meeting_id" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["meeting_id"]
    },
    "calendar.list_items" => %{
      "type" => "object",
      "properties" => %{
        "calendar_id" => %{"type" => "string"},
        "range_start_ms" => %{"type" => "integer", "description" => "Inclusive UTC Unix ms."},
        "range_end_ms" => %{"type" => "integer", "description" => "Exclusive UTC Unix ms."},
        "object_type" => %{"type" => "string", "enum" => ["event", "task"]},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
      },
      "required" => ["calendar_id", "range_start_ms", "range_end_ms"]
    },
    "calendar.get_item" => %{
      "type" => "object",
      "properties" => %{
        "calendar_id" => %{"type" => "string"},
        "calendar_item_id" => %{"type" => "string"},
        "occurrence_ref" => %{"type" => "object", "description" => "Optional OccurrenceRef."}
      },
      "required" => ["calendar_id", "calendar_item_id"]
    },
    "calendar.update_context" => %{
      "type" => "object",
      "properties" => %{
        "calendar_id" => %{"type" => "string"},
        "occurrence_ref" => %{"type" => "object"},
        "expected_revision" => %{"type" => "integer", "minimum" => 0},
        "objective" => %{"type" => "string"},
        "background" => %{"type" => "string"},
        "agenda" => %{"type" => "array", "items" => %{"type" => "string"}},
        "questions" => %{"type" => "array", "items" => %{"type" => "string"}},
        "resource_refs" => %{"type" => "array", "items" => %{"type" => "object"}}
      },
      "required" => ["calendar_id", "occurrence_ref", "expected_revision"]
    },
    "calendar.create_event" => %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Event title."},
        "start" => %{
          "type" => "string",
          "description" => "Local wall time with no offset, e.g. 2026-08-27T19:00:00."
        },
        "time_zone" => %{"type" => "string", "description" => "IANA time zone, e.g. Asia/Tokyo."},
        "duration" => %{
          "type" => "string",
          "description" => "Optional ISO-8601 duration, e.g. PT30M. Defaults to PT30M."
        },
        "attendees" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"display_name" => %{"type" => "string"}},
            "required" => ["display_name"]
          },
          "description" => "Optional attendee display names. Names are not identities or grants."
        }
      },
      "required" => ["title", "start", "time_zone"]
    },
    "calendar.issue_feed_link" => %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    },
    "env.exec" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" => "Stable environment_id from device.get (required)"
        },
        "command" => %{"type" => "string", "description" => "Shell command to execute"},
        "description" => %{
          "type" => "string",
          "description" =>
            "Short status the user sees while the command runs, written in the user's language as an ongoing action, such as \"Checking logs\" (under 20 characters). Chat clients show it instead of a generic label.",
          "maxLength" => @exec_description_max_length
        },
        "working_dir" => %{
          "type" => "string",
          "description" => "Working directory (default: connector root)"
        },
        "timeout" => %{"type" => "integer", "description" => "Timeout in seconds (default: 120)"},
        "credential_env" => %{
          "type" => "array",
          "description" =>
            "Environment variables to inject from group-scoped OAuth credentials. Each item maps one concrete env_var to a credential reference. The model never sees secret values.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "env_var" => %{
                "type" => "string",
                "description" => "Environment variable name to set, e.g. GH_TOKEN"
              },
              "provider" => %{
                "type" => "string",
                "description" => "OAuth provider name, e.g. github, linear, notion"
              },
              "alias" => %{
                "type" => "string",
                "description" => "Group-scoped alias chosen during authorization"
              },
              "value" => %{
                "type" => "string",
                "description" => "Credential value to inject (usually access_token)"
              }
            },
            "required" => ["env_var", "provider", "alias", "value"]
          }
        }
      },
      "required" => ["device_id", "environment", "command", "description"]
    },
    "env.process_list" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" => "Stable environment_id from device.get."
        }
      },
      "required" => ["device_id", "environment"]
    },
    "env.process_write" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" => "Stable environment_id from device.get."
        },
        "process_name" => %{
          "type" => "string",
          "description" => "Name of the long-lived process to write to."
        },
        "data" => %{"type" => "string", "description" => "Text to write to stdin."},
        "append_newline" => %{
          "type" => "boolean",
          "description" => "When true, append a newline after data."
        }
      },
      "required" => ["device_id", "environment", "process_name", "data"]
    },
    "env.process_tail" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" => "Stable environment_id from device.get."
        },
        "process_name" => %{
          "type" => "string",
          "description" => "Name of the long-lived process to read from."
        },
        "from_offset" => %{
          "type" => "integer",
          "description" => "Optional byte offset to resume from."
        },
        "max_bytes" => %{
          "type" => "integer",
          "description" => "Maximum bytes to return."
        },
        "tail_bytes" => %{
          "type" => "integer",
          "description" => "Read from the end when no offset is known."
        },
        "wait_seconds" => %{
          "type" => "integer",
          "description" => "Optional long-poll wait for new output."
        }
      },
      "required" => ["device_id", "environment", "process_name"]
    },
    "env.copy" => %{
      "type" => "object",
      "properties" => %{
        "src_device_id" => %{
          "type" => "string",
          "description" => "Required when src_environment is remote; omit for vfs."
        },
        "dst_device_id" => %{
          "type" => "string",
          "description" => "Required when dst_environment is remote; omit for vfs."
        },
        "src_environment" => %{
          "type" => "string",
          "description" => "Source environment_id; use vfs for agent-owned files"
        },
        "src_path" => %{"type" => "string", "description" => "Source file path"},
        "dst_environment" => %{
          "type" => "string",
          "description" => "Destination environment_id; use vfs for agent-owned files"
        },
        "dst_path" => %{"type" => "string", "description" => "Destination file path"},
        "src_agent_id" => %{
          "type" => "string",
          "description" =>
            "Optional group-local Agent id owning the SOURCE vfs (discover with agent.list). Valid only when src_environment is vfs. Defaults to the calling agent."
        },
        "dst_agent_id" => %{
          "type" => "string",
          "description" =>
            "Optional group-local Agent id owning the DESTINATION vfs (discover with agent.list). Valid only when dst_environment is vfs. Defaults to the calling agent."
        }
      },
      "required" => ["src_environment", "src_path", "dst_environment", "dst_path"]
    },
    "device.list" => %{
      "type" => "object",
      "properties" => %{
        "cursor" => %{
          "type" => "string",
          "description" => "Opaque next_cursor from the previous page."
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 100,
          "description" => "Devices per page; defaults to 20."
        }
      },
      "required" => []
    },
    "device.get" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" => "Stable device_id returned by participant status or device.list."
        }
      },
      "required" => ["device_id"]
    },
    "env.computer_use" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" =>
            "Stable environment_id from device.get. Required for every action except action=help."
        },
        "action" => %{
          "type" => "string",
          "description" =>
            "Computer-use action name. action=help returns optional mode guidance; action=start begins a session."
        },
        "thinking" => %{
          "type" => "string",
          "description" =>
            "Optional concise visible progress text for this same action. Prefer passing this alongside the action instead of making a separate thinking call."
        },
        "args" => %{
          "description" =>
            "Action-specific arguments. The exact keys and types are described by action=help and the active mode."
        }
      },
      "required" => ["action"]
    },
    "env.android" => %{
      "type" => "object",
      "properties" => %{
        "device_id" => %{
          "type" => "string",
          "description" =>
            "Owning device_id from device.list or device.get; required for device operations."
        },
        "environment" => %{
          "type" => "string",
          "description" =>
            "Stable environment_id whose capabilities include android_device_tool=true."
        },
        "profile" => %{
          "type" => "string",
          "description" =>
            "Installed profile id from device.get. Start defaults to the administrator's default profile. Every leased action must retain the profile returned by start."
        },
        "action" => %{
          "type" => "string",
          "enum" =>
            ~w(start status observe tap swipe type key launch clipboard_get clipboard_set install push pull diagnose end)
        },
        "lease_id" => %{"type" => "string"},
        "lease_seconds" => %{
          "type" => "integer",
          "minimum" => 60,
          "maximum" => 3600,
          "description" => "Requested lease duration; the tenant maximum may shorten it."
        },
        "lease_epoch" => %{"type" => "integer", "minimum" => 1},
        "observation_id" => %{"type" => "integer", "minimum" => 1},
        "args" => %{
          "type" => "object",
          "description" =>
            "Bounded action-specific arguments such as ref, coordinates, text, package, staging_name, source_path, or guest_path."
        }
      },
      "required" => ["device_id", "environment", "action"]
    },

    # ---- IM providers ----
    "im.connects_list" => %{
      "type" => "object",
      "properties" => %{
        "provider" => %{
          "type" => "string",
          "description" =>
            "Optional provider id. Omit to list every connect visible to this agent."
        }
      },
      "required" => []
    },
    "im.provider_apis_list" => %{
      "type" => "object",
      "properties" => %{
        "provider" => %{"type" => "string", "description" => "Provider id."},
        "connect_id" => %{
          "type" => "string",
          "description" =>
            "Optional connect_id used to scope returned operation ids to one visible connect."
        }
      },
      "required" => ["provider"]
    },
    # ---- schedules ----
    "schedule.create" => %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" => "Prompt to execute when the schedule fires."
        },
        "interval_minutes" => %{
          "type" => "integer",
          "description" =>
            "Positive integer interval in minutes between runs. " <>
              "Provide exactly one of interval_minutes, cron, or run_at.",
          "minimum" => 1
        },
        "cron" => %{
          "type" => "string",
          "description" =>
            "Standard 5-field cron expression ('min hour day-of-month month day-of-week'), " <>
              "e.g. '0 9 * * 1-5' for 09:00 on weekdays. Evaluated in 'timezone'. " <>
              "Provide exactly one of interval_minutes, cron, or run_at."
        },
        "run_at" => %{
          "type" => "string",
          "format" => "date-time",
          "description" =>
            "RFC3339 timestamp with timezone for one execution, for example 2026-07-20T09:50:00+08:00. The schedule is deleted after successful delivery. Provide exactly one of run_at, interval_minutes, or cron."
        },
        "timezone" => %{
          "type" => "string",
          "description" =>
            "IANA timezone name (e.g. 'America/New_York') the cron expression is evaluated in. " <>
              "Optional, defaults to 'UTC' for cron schedules."
        }
      },
      "required" => ["prompt"],
      "oneOf" => [
        %{
          "required" => ["interval_minutes"],
          "not" => %{"anyOf" => [%{"required" => ["cron"]}, %{"required" => ["run_at"]}]}
        },
        %{
          "required" => ["cron"],
          "not" => %{
            "anyOf" => [%{"required" => ["interval_minutes"]}, %{"required" => ["run_at"]}]
          }
        },
        %{
          "required" => ["run_at"],
          "not" => %{
            "anyOf" => [%{"required" => ["interval_minutes"]}, %{"required" => ["cron"]}]
          }
        }
      ]
    },
    "schedule.list" => %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    },
    "schedule.delete" => %{
      "type" => "object",
      "properties" => %{
        "schedule_id" => %{"type" => "string", "description" => "Schedule ID to delete."}
      },
      "required" => ["schedule_id"]
    },

    # ---- oauth (willow listoauth.go / request_oauth_auth.go /
    # complete_oauth_auth.go Parameters; tool-name references renamed) ----
    "oauth.list_credentials" => %{"type" => "object", "properties" => %{}, "required" => []},
    "oauth.request_authorization" => %{
      "type" => "object",
      "properties" => %{
        "locale" => @interaction_locale,
        "provider" => %{
          "type" => "string",
          "description" =>
            "OAuth provider name. Supported: google, github, linear, notion, slack."
        },
        "alias" => %{
          "type" => "string",
          "description" =>
            "Short label for this connected account, unique within (group, provider). Used later in env.exec.credential_env."
        },
        "scopes" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional scopes to request. Adapter defaults are used when omitted."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Short user-facing explanation of why authorization is needed."
        },
        "timeout_seconds" => %{
          "type" => "integer",
          "description" =>
            "How long the authorization URL remains valid. Defaults to 600 seconds, maximum 1800 seconds.",
          "minimum" => 1,
          "maximum" => 1800
        }
      },
      "required" => ["provider", "alias", "reason"]
    },
    "oauth.complete_authorization" => %{
      "type" => "object",
      "properties" => %{
        "state" => %{
          "type" => "string",
          "description" => "The state value returned by oauth.request_authorization."
        }
      },
      "required" => ["state"]
    },
    "oauth.delete_credential" => %{
      "type" => "object",
      "properties" => %{
        "provider" => %{
          "type" => "string",
          "description" =>
            "OAuth provider name of the credential to delete (as shown by oauth.list_credentials)."
        },
        "alias" => %{
          "type" => "string",
          "description" => "Alias of the credential to delete, unique within (group, provider)."
        }
      },
      "required" => ["provider", "alias"]
    },

    # ---- composio (direct integrations path alongside managed oauth) ----
    "composio.list_connections" => %{"type" => "object", "properties" => %{}, "required" => []},
    "composio.request_connection" => %{
      "type" => "object",
      "properties" => %{
        "toolkit" => %{
          "type" => "string",
          "description" =>
            "Composio toolkit slug to connect, e.g. gmail, googlecalendar, notion, linear, slack, github."
        }
      },
      "required" => ["toolkit"]
    },
    "composio.check_connection" => %{
      "type" => "object",
      "properties" => %{
        "connected_account_id" => %{
          "type" => "string",
          "description" => "The connected_account_id returned by composio.request_connection."
        }
      },
      "required" => ["connected_account_id"]
    },
    "composio.delete_connection" => %{
      "type" => "object",
      "properties" => %{
        "connected_account_id" => %{
          "type" => "string",
          "description" =>
            "The connected_account_id to disconnect (as shown by composio.list_connections)."
        }
      },
      "required" => ["connected_account_id"]
    },
    "composio.list_tools" => %{
      "type" => "object",
      "properties" => %{
        "toolkit" => %{
          "type" => "string",
          "description" => "Toolkit slug to list tools for, e.g. gmail."
        },
        "query" => %{
          "type" => "string",
          "description" =>
            "Full-text search over tool names and descriptions, e.g. \"fetch emails\"."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum tools to return. Defaults to 20, maximum 50.",
          "minimum" => 1,
          "maximum" => 50
        }
      },
      "required" => []
    },
    "composio.get_tool" => %{
      "type" => "object",
      "properties" => %{
        "tool_slug" => %{
          "type" => "string",
          "description" => "Composio tool slug, e.g. GMAIL_FETCH_EMAILS."
        }
      },
      "required" => ["tool_slug"]
    },
    "composio.list_toolkits" => %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" =>
            "Full-text search over toolkit names/slugs, e.g. \"calendar\" or \"hubspot\"."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum toolkits to return. Defaults to 20, maximum 50.",
          "minimum" => 1,
          "maximum" => 50
        }
      },
      "required" => []
    },
    "composio.execute" => %{
      "type" => "object",
      "properties" => %{
        "tool_slug" => %{
          "type" => "string",
          "description" => "Composio tool slug to execute, e.g. GMAIL_FETCH_EMAILS."
        },
        "arguments" => %{
          "type" => "object",
          "description" =>
            "Arguments matching the tool's input_parameters schema (see composio.get_tool). Omit for tools without required parameters."
        },
        "connected_account_id" => %{
          "type" => "string",
          "description" =>
            "Optional: pin the execution to a specific connected account when the group has several for one toolkit."
        }
      },
      "required" => ["tool_slug"]
    },
    # ---- owner email (tools/owner_email.ex) ----
    "email.send_to_owners" => %{
      "type" => "object",
      "properties" => %{
        "subject" => %{
          "type" => "string",
          "description" => "Email subject line. Keep it short and specific."
        },
        "body" => %{
          "type" => "string",
          "description" =>
            "Plain-text email body. Delivered as-is to every configured owner of this agent group."
        }
      },
      "required" => ["subject", "body"]
    },

    # ---- media ----
    "image.generate" => %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{"type" => "string", "description" => "Image generation prompt."},
        "input_image_paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Optional absolute visible file paths to one or more input/reference images to edit or compose. When omitted, the tool generates a new image from text only. The order is significant; refer to them as Image 1, Image 2, etc. in the prompt when using multiple images."
        },
        "output_path" => %{
          "type" => "string",
          "description" =>
            "Absolute visible file path for the generated image. Defaults to /artifacts/generated-image-<id>.jpg. Use a descriptive filename."
        },
        "path" => %{
          "type" => "string",
          "description" => "Alias for output_path; used when output_path is omitted."
        },
        "size" => %{
          "type" => "string",
          "description" => "Provider-specific image size, such as auto, 1024x1024, or 1536x1024."
        },
        "aspect_ratio" => %{
          "type" => "string",
          "description" => "Provider-specific aspect ratio, such as 1:1, 16:9, or 9:16."
        },
        "quality" => %{
          "type" => "string",
          "description" =>
            "Provider-specific quality setting, such as auto, low, medium, or high."
        },
        "format" => %{
          "type" => "string",
          "description" => "Output format hint: jpeg, png, webp, or auto. Defaults to jpeg."
        },
        "image_size" => %{
          "type" => "string",
          "description" => "Gemini image size hint, such as 1K, 2K, or 4K."
        }
      },
      "required" => ["prompt"]
    },
    "video.generate" => %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" =>
            "Video generation prompt. Optional only when input_image_paths is provided."
        },
        "input_image_paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Optional absolute visible file paths to reference images. One path = first frame; two paths = first frame and last frame (in order). Omit for text-to-video."
        },
        "output_path" => %{
          "type" => "string",
          "description" =>
            "Absolute visible file path for the generated video. Defaults to /artifacts/generated-video-<id>.mp4. Use a descriptive filename."
        },
        "path" => %{
          "type" => "string",
          "description" => "Alias for output_path; used when output_path is omitted."
        },
        "resolution" => %{
          "type" => "string",
          "description" =>
            "Video resolution: 480p, 720p, or 1080p. Omit to use the provider default (recommended unless a specific resolution is needed)."
        },
        "ratio" => %{
          "type" => "string",
          "description" =>
            "Aspect ratio, such as 16:9, 9:16, 1:1, or adaptive. Omit to use the provider default."
        },
        "duration" => %{
          "type" => "integer",
          "description" =>
            "Video duration in whole seconds. Omit this field entirely to let the model choose a suitable duration (recommended) rather than guessing a value."
        },
        "seed" => %{"type" => "integer", "description" => "Optional seed for reproducibility."},
        "generate_audio" => %{
          "type" => "boolean",
          "description" =>
            "Whether the generated video should include synchronized audio. Provider default applies when omitted."
        },
        "watermark" => %{
          "type" => "boolean",
          "description" => "Whether to embed a visible AI-generated watermark."
        }
      },
      "required" => []
    },
    "audio.transcribe" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Absolute VFS path to an audio or video file of at most 30 MiB in the current Agent workspace. For a Task attachment, use the reader-local path returned by im_api.internal.read_conversation."
        },
        "output_path" => %{
          "type" => "string",
          "description" =>
            "Optional absolute .txt artifact path. Reuse the same path for retries of the same immutable recording; a .json sidecar preserves ASR metadata. Use a new output for changed source bytes."
        }
      },
      "required" => ["path"],
      "additionalProperties" => false
    },

    # ---- preview (willow PublishHTMLPreview.Parameters) ----
    "preview.publish_html" => %{
      "type" => "object",
      "properties" => %{
        "html" => %{
          "type" => "string",
          "description" =>
            "Complete HTML document to publish as index.html. Used when source_path and source_root are omitted."
        },
        "source_path" => %{
          "type" => "string",
          "description" =>
            "Absolute visible file path to an existing HTML file. Replaces only index.html and preserves the site's other public files."
        },
        "source_root" => %{
          "type" => "string",
          "description" =>
            "Absolute VFS directory containing index.html and the complete site tree. Normally stage it under /.salix/websites/{site_name}/_work; a rollback may use _versions. The public site mirrors this directory, removing public files that are absent."
        },
        "site_name" => %{
          "type" => "string",
          "description" =>
            "Optional DNS-label-safe site name. Reuse the exact canonical name returned by the first publish to update the same website and URL; a different name creates a different website."
        },
        "title" => %{
          "type" => "string",
          "description" => "Optional user-facing title for the preview card."
        }
      },
      "required" => []
    }
  }

  @doc "The input schema for `name`, or nil for unknown tools."
  @spec schema(String.t()) :: map() | nil
  def schema("agent.list"), do: SalixAgent.Tools.AgentManagement.schema(:list)
  def schema("agent.get"), do: SalixAgent.Tools.AgentManagement.schema(:get)
  def schema("agent.create_worker"), do: SalixAgent.Tools.AgentManagement.schema(:create)
  def schema("agent.update"), do: SalixAgent.Tools.AgentManagement.schema(:update)
  def schema("agent.rebind_runtime"), do: SalixAgent.Tools.AgentManagement.schema(:rebind)
  def schema("agent.archive"), do: SalixAgent.Tools.AgentManagement.schema(:archive)
  def schema("env.runtime_targets"), do: SalixAgent.Tools.RuntimeTargets.schema()
  def schema("ui.create"), do: SalixAgent.Tools.DynamicUI.schema()
  def schema("env.ensure_runtime"), do: SalixAgent.Tools.CloudRuntime.schema()
  def schema(name), do: Map.get(@schemas, name)

  @doc false
  @spec exec_description_max_length() :: pos_integer()
  def exec_description_max_length, do: @exec_description_max_length

  @doc false
  @spec normalize_exec_description(term()) :: term()
  def normalize_exec_description(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.graphemes()
    |> Enum.take(@exec_description_max_length)
    |> Enum.join()
  end

  def normalize_exec_description(value), do: value

  @doc "Attach `\"input_schema\"` to a tool spec when one is defined."
  @spec attach(map()) :: map()
  def attach(%{"name" => name} = spec) do
    case schema(name) do
      nil -> spec
      schema -> Map.put(spec, "input_schema", schema)
    end
  end

  @doc "All tool names with a schema (test/coverage helper)."
  @spec names() :: [String.t()]
  def names,
    do:
      Map.keys(@schemas) ++
        ~w(agent.list agent.get agent.create_worker agent.update agent.rebind_runtime agent.archive env.runtime_targets env.ensure_runtime)
end
