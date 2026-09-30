defmodule SystemsObservability.ClassifierTest do
  use ExUnit.Case, async: true
  alias SystemsObservability.Classifier

  test "finite classifiers normalize known values and reject dynamic values" do
    hostile = "tenant-123?token=secret/model-custom/error boom"

    cases = [
      {:surface, hostile, "other"},
      {:component, hostile, "other"},
      {:endpoint, hostile, "other"},
      {:provider, hostile, "other"},
      {:outcome, hostile, "other"},
      {:error_class, hostile, "other"},
      {:repo, hostile, "other"},
      {:trace_operation, hostile, "other"},
      {:job_kind, hostile, "other"},
      {:async_kind, hostile, "other"},
      {:surface, :bft, "bft"},
      {:surface, "schedule", "schedule"},
      {:surface, :auto_title, "auto_title"},
      {:component, "SALIX_LLM", "salix_llm"},
      {:trace_operation, :provider_request, "provider_request"},
      {:job_kind, "tool_completion", "tool_completion"},
      {:async_kind, "tool_completion", "tool_completion"},
      {:method, :get, "GET"},
      {:status_class, 503, "5xx"}
    ]

    for {function, input, expected} <- cases do
      assert apply(Classifier, function, [input]) == expected,
             "expected #{function}(#{inspect(input)}) to classify as #{inspect(expected)}"
    end

    assert Classifier.model_key(hostile, ["approved-model"]) == "other"
  end

  test "route families are bounded independently from method and status" do
    cases = [
      {:bft_dashboard, "/login", "/dashboard/*"},
      {:bft_dashboard, "/orgs/:org_id/projects", "/dashboard/*"},
      {:bft_dashboard, "/tasks/:tenant_id/:group_id/:conversation_id", "/dashboard/*"},
      {:bft_dashboard, "/unknown", "unmatched"},
      {:bft_dashboard, "/orgs/550e8400-e29b-41d4-a716-446655440000", "unmatched"},
      {:bft_dashboard, "/login?token=secret", "unmatched"},
      {:comma_product_api, "/health", "/health"},
      {:comma_product_api, "/v1/comma/me/bootstrap", "/v1/comma/me/*"},
      {:comma_product_api, "/v1/comma/workspaces", "/v1/comma/workspaces"},
      {:comma_product_api, "/v1/comma/workspaces/:workspace_id", "/v1/comma/workspaces/*"},
      {:comma_product_api, "/v1/comma/admin/users", "/v1/comma/admin/*"},
      {:salix_api, "/_site/api", "/site-api/*"},
      {:salix_api, "/_site/content", "/site-content/*"},
      {:salix_api, "/site/123/assets/logo.png", "/site/:id/*"},
      {:salix_api, "/dash/agents/:id", "/dash/*"},
      {:salix_api, "/v1/runtime/agents/:id", "/v1/runtime/*"},
      {:salix_api, "/v1/im/channels/:id", "/v1/im/*"},
      {:comma_product_api, "/users/123?token=secret", "unmatched"},
      {:comma_product_api, "/v1/comma/workspaces?token=secret", "unmatched"},
      {:salix_api, "/v1/unknown/550e8400-e29b-41d4-a716-446655440000", "unmatched"},
      {:other, "/health", "unmatched"}
    ]

    for {endpoint, route, expected} <- cases do
      assert Classifier.route_template(endpoint, route) == expected
    end
  end

  test "application component attribution is bounded" do
    cases = [
      {:comma_web, "comma_product"},
      {"COMMA_WEB", "comma_product"},
      {"tenant-123?token=secret", "other"},
      {:unknown_application, "other"},
      {nil, "other"}
    ]

    for {application, expected} <- cases do
      assert Classifier.component_for_application(application) == expected
    end
  end
end
