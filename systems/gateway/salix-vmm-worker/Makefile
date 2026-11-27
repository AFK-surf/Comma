# The node's Agent VMM worker (SalixStore.AgentVMM.Worker) and its test Host.
# The release image builds the worker in its own stage (systems/Dockerfile).
OUT ?= ../../apps/salix_store/priv/salix_vmm_worker
TESTHOST ?= ../../apps/salix_store/priv/salix_vmm_test_host
PROFILE ?= release
TARGET := target/$(if $(filter dev,$(PROFILE)),debug,$(PROFILE))
SOURCES := $(shell find src proto -type f) Cargo.toml Cargo.lock build.rs

worker: $(OUT)

$(OUT): $(SOURCES)
	mkdir -p $(dir $(OUT))
	cargo build --profile $(PROFILE) --locked --bin salix_vmm_worker
	cp $(TARGET)/salix_vmm_worker $(OUT).new && mv $(OUT).new $(OUT)

# For tests (PROFILE=dev): the worker and its test Host from one build of the
# crate. The test Host is never in the release image.
testhost: $(TESTHOST)
	@test -x $(OUT) || $(MAKE) --no-print-directory -B $(TESTHOST)

$(TESTHOST): $(SOURCES)
	mkdir -p $(dir $(OUT)) $(dir $(TESTHOST))
	cargo build --profile $(PROFILE) --locked --features test-host --bin salix_vmm_worker --bin salix_vmm_test_host
	cp $(TARGET)/salix_vmm_worker $(OUT).new && mv $(OUT).new $(OUT)
	cp $(TARGET)/salix_vmm_test_host $(TESTHOST).new && mv $(TESTHOST).new $(TESTHOST)

.PHONY: worker testhost
