# tsnet pins the same Tailscale module as the Tailcat gateway, which needs Go
# 1.27.1. GOTOOLCHAIN=auto fetches it when the installed Go is older.
OUT ?= ../apps/salix_agent/priv/tailnet_gateway
SOURCES := $(shell find . -name '*.go' -print)

$(OUT): $(SOURCES) go.mod go.sum
	mkdir -p $(dir $(OUT))
	GOTOOLCHAIN=auto CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o $(OUT) ./cmd/salix-tailnet-gateway

# Test-only tailnet (relay, coordination server and one device); never in the
# release image.
TESTPEER ?= ../apps/salix_agent/priv/tailnet_testpeer
testpeer: $(TESTPEER)

$(TESTPEER): $(SOURCES) go.mod go.sum
	mkdir -p $(dir $(TESTPEER))
	GOTOOLCHAIN=auto CGO_ENABLED=0 go build -trimpath -o $(TESTPEER) ./cmd/tailnet-testpeer

.PHONY: testpeer
