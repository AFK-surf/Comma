.PHONY: storybook dev dev-backend dev-web dev-electron dev-real-llm dev-backend-real-llm dev-electron-real-llm dev-container-rebuild dev-container-restart dev-container-status dev-container-shell dev-systems-up dev-systems-up-recommendation-mock dev-systems-up-real-llm dev-systems-seed dev-systems-logs dev-systems-down salix-dev-up salix-dev-rebuild salix-dev-status salix-dev-logs salix-dev-down salix-dev-reset salix-dev-psql salix-dev-shell salix-dev-config salix-dev-info test-clients test-clients-smoke test-comma-telegram-ui-local test-systems test-comma-release-kubernetes-e2e test-comma-release-database-e2e test-bft-cli test-policy
.PHONY: test-devtools test-resources test-systems-static test-all-local

DEV_COMPOSE = docker compose -f systems/docker-compose.dev.yml -f systems/docker-compose.devcontainer.yml
DEV_COMPOSE_REAL = $(DEV_COMPOSE) -f systems/docker-compose.devcontainer.real-llm.yml

storybook:
	pnpm --dir clients/packages/ui storybook

dev: dev-web

dev-backend: dev-systems-up

dev-web: dev-backend
	pnpm --dir clients dev:web

dev-electron: dev-systems-up
	node systems/scripts/comma-local-dev-electron.mjs

dev-real-llm: dev-backend-real-llm
	pnpm --dir clients dev:web

dev-backend-real-llm: dev-systems-up-real-llm

dev-electron-real-llm: dev-systems-up-real-llm
	node systems/scripts/comma-local-dev-electron.mjs

dev-systems-up:
	$(DEV_COMPOSE) up -d --wait --wait-timeout 600 devcontainer

dev-systems-up-recommendation-mock:
	@echo "Recommendation mock is now toggled at runtime in Settings > Debug."
	$(MAKE) dev-systems-up

dev-systems-up-real-llm:
	@test -f .local/comma-real-llm.env || (echo "Missing .local/comma-real-llm.env; see systems/README.md" >&2; exit 1)
	@test -f .local/compose-dev-real-llm.json || (echo "Missing .local/compose-dev-real-llm.json; see systems/README.md" >&2; exit 1)
	$(DEV_COMPOSE_REAL) up -d --wait --wait-timeout 600 devcontainer

dev-systems-seed:
	node systems/scripts/comma-local-dev-seed.mjs

dev-systems-logs:
	$(DEV_COMPOSE) logs -f devcontainer llm-mock

dev-systems-down:
	$(DEV_COMPOSE) down

dev-container-rebuild:
	$(DEV_COMPOSE) build --pull devcontainer
	$(DEV_COMPOSE) up -d --force-recreate --wait --wait-timeout 600 devcontainer

dev-container-restart:
	$(DEV_COMPOSE) restart devcontainer
	$(DEV_COMPOSE) up -d --no-recreate --wait --wait-timeout 600 devcontainer

dev-container-status:
	$(DEV_COMPOSE) ps

dev-container-shell:
	$(DEV_COMPOSE) exec devcontainer bash

salix-dev-up:
	node systems/scripts/salix-dev.mjs up

salix-dev-rebuild:
	node systems/scripts/salix-dev.mjs rebuild

salix-dev-status:
	node systems/scripts/salix-dev.mjs status

salix-dev-logs:
	node systems/scripts/salix-dev.mjs logs

salix-dev-down:
	node systems/scripts/salix-dev.mjs down

salix-dev-reset:
	node systems/scripts/salix-dev.mjs reset

salix-dev-psql:
	node systems/scripts/salix-dev.mjs psql

salix-dev-shell:
	node systems/scripts/salix-dev.mjs shell

salix-dev-config:
	node systems/scripts/salix-dev.mjs config

salix-dev-info:
	node systems/scripts/salix-dev.mjs info

test-clients:
	cd clients && pnpm ci:static && pnpm ci:unit && pnpm test:e2e

test-clients-smoke:
	cd clients && pnpm smoke:web && pnpm smoke:electron

test-comma-telegram-ui-local:
	cd clients && pnpm smoke:telegram:local

.PHONY: prototype-proactive-chat
PROACTIVE_PROTOTYPE_ARGS ?= --serve
prototype-proactive-chat:
	bash systems/scripts/proactive-chat-prototype/run.sh $(PROACTIVE_PROTOTYPE_ARGS)

test-systems:
	cd systems && mix test --seed 0
	systems/account-proxy/bootstrap.sh
	go test -C systems/account-proxy -race ./...
	GOTOOLCHAIN=auto go test -C systems/tailcat-gateway -race ./...
	go test -C systems/gateway/salix-vmm-gateway ./...
	go test -C systems/ops/comma-release -race ./...
	go test -C systems/connector/salix-connect -race ./...
	CGO_ENABLED=0 go test -C systems/voice/comma-voice -tags nodevice ./...

test-comma-release-kubernetes-e2e:
	./scripts/comma-release-kubernetes-e2e.sh

test-comma-release-database-e2e:
	./scripts/comma-release-database-e2e.sh

test-bft-cli:
	go test -C systems/cli/bft ./...

test-policy:
	python3 -m unittest discover -s selfhost
	node scripts/check-docs.mjs
	node scripts/generate-model-catalog.mjs --check
	go test -C systems/ops/comma-release ./...
	node --test systems/apps/bridge_for_teams_core/priv/repo/migrations/organization_icon_migration.test.ts
	node --test scripts/bridge-staging-bootstrap-invite.test.cjs
	node --test systems/scripts/comma-local-dev-electron.test.mjs systems/scripts/comma-local-dev-seed.test.mjs systems/scripts/local-llm-mock.test.mjs systems/scripts/local-telegram-mock.test.mjs systems/scripts/salix-dev.test.mjs
	node --test systems/apps/salix_web/test/assets/command_draft.test.mjs
	node --test scripts/server-release-descriptor.test.mjs
	node --test scripts/publish-runtime-bundles.test.mjs
	k8s/comma/cloud-monitoring/tests/terraform-import-contract-test.sh
	k8s/comma/cloud-monitoring/tests/terraform-plan-test.sh
	k8s/comma/cloud-monitoring/tests/terraform-release-test.sh
	k8s/comma/cloud-monitoring/tests/terraform-workspace-guard-test.sh
	node --test scripts/require-tests-for-code-changes.test.ts
	node scripts/require-tests-for-code-changes.ts

test-devtools:
	npm --prefix devtools/e2e-reports run check
	npm --prefix devtools/e2e-reports run build
	npm --prefix devtools/salix-web-ui run check
	npm --prefix devtools/salix-web-ui run build

test-resources:
	node scripts/validate-salix-system-files.ts
	node scripts/validate-recommendation-template-catalog.mjs

test-systems-static:
	@if command -v mix >/dev/null 2>&1; then \
		cd systems && mix format --check-formatted; \
	elif [ "$${CI:-}" = "true" ]; then \
		echo "mix is required for test-systems-static in CI" >&2; \
		exit 1; \
	else \
		echo "mix not found; skipping Elixir format check"; \
	fi

test-all-local: test-policy test-resources test-devtools test-systems-static test-systems test-bft-cli test-clients

# Bounded system-core formal suite; see tla/README.md. Java 11+ required.
.PHONY: tla tla-salix tla-other tla-billing tla-oauth-idp-key-rotation
tla: tla-salix tla-other

tla-salix:
	tla/salix/check.sh

tla-other:
	python3 tla/check-budget.py
	tla/oauth_idp_key_rotation/check.sh
	tla/agent_vmm/check.sh
	tla/billing/check.sh

tla-billing:
	tla/billing/check.sh

tla-oauth-idp-key-rotation:
	tla/oauth_idp_key_rotation/check.sh

# Throwaway UI with fictional data. No backend or provider writes.
.PHONY: prototype-proactive-ui
prototype-proactive-ui:
	node node_modules/vite/bin/vite.js --config clients/packages/app/vite.proactive-prototype.config.ts
