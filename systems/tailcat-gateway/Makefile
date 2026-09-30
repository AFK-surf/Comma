# Tailcat needs Go 1.27.1. GOTOOLCHAIN=auto fetches it when the installed Go
# is older, as in CI jobs that pin Go for another module.
OUT ?= ../apps/salix_agent/priv/tailcat_gateway
TESTPEER ?= ../apps/salix_agent/priv/tailcat_testpeer
SOURCES := $(shell find . -name '*.go' -print)

$(OUT): $(SOURCES) go.mod go.sum
	mkdir -p $(dir $(OUT))
	GOTOOLCHAIN=auto CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o $(OUT) ./cmd/salix-tailcat-gateway

# Test-only Tailcat server behind a local relay; never in the release image.
testpeer: $(TESTPEER)

$(TESTPEER): $(SOURCES) go.mod go.sum
	mkdir -p $(dir $(TESTPEER))
	GOTOOLCHAIN=auto CGO_ENABLED=0 go build -trimpath -o $(TESTPEER) ./cmd/tailcat-testpeer

.PHONY: testpeer
