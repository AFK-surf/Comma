OUT ?= ../apps/salix_agent/priv/subscription_worker
SOURCES := $(shell find . -path './.upstream' -prune -o -name '*.go' -print)

$(OUT): $(SOURCES) go.mod go.sum patches/embedded-sdk.patch .upstream/go.mod
	mkdir -p $(dir $(OUT))
	CGO_ENABLED=0 go build -trimpath -o $(OUT) ./cmd/salix-account-proxy

.upstream/go.mod:
	./bootstrap.sh
