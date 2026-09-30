# Builds the salix_signal_proto NIF. elixir_make runs `make all` with
# MIX_APP_PATH and ERTS_INCLUDE_DIR set. `make sanitize-test` builds and runs
# the C core under AddressSanitizer and UndefinedBehaviorSanitizer.
#
# Requires the libsodium headers and pkg-config (Debian/Ubuntu: libsodium-dev
# pkg-config; macOS: brew install libsodium pkg-config).

MIX_APP_PATH ?= $(CURDIR)/../../_build/dev/lib/salix_signal_proto
PRIV_DIR := $(MIX_APP_PATH)/priv
NIF := $(PRIV_DIR)/salix_signal_proto_nif.so
BUILD_DIR := $(CURDIR)/c_build

ifeq ($(ERTS_INCLUDE_DIR),)
ERTS_INCLUDE_DIR := $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
endif

SODIUM_CFLAGS := $(shell pkg-config --cflags libsodium)
SODIUM_LIBS := $(shell pkg-config --libs libsodium)

CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -fPIC -fvisibility=hidden $(SODIUM_CFLAGS)
NIF_CFLAGS := $(CFLAGS) -I"$(ERTS_INCLUDE_DIR)"

ifeq ($(shell uname -s),Darwin)
NIF_LDFLAGS := -dynamiclib -undefined dynamic_lookup
else
NIF_LDFLAGS := -shared
endif

CORE_SOURCES := c_src/signal_curve.c
HEADERS := c_src/signal_curve.h

.PHONY: all clean sanitize-test

all: $(NIF)

$(NIF): $(CORE_SOURCES) c_src/salix_signal_proto_nif.c $(HEADERS)
	@mkdir -p "$(PRIV_DIR)"
	$(CC) $(NIF_CFLAGS) $(CORE_SOURCES) c_src/salix_signal_proto_nif.c -o "$@" $(NIF_LDFLAGS) $(LDFLAGS) $(SODIUM_LIBS)

sanitize-test: $(CORE_SOURCES) c_src/signal_curve_test.c $(HEADERS)
	@mkdir -p "$(BUILD_DIR)"
	$(CC) -std=c11 -Wall -Wextra -Werror -g -O1 -fno-omit-frame-pointer \
	  -fsanitize=address,undefined -fno-sanitize-recover=all $(SODIUM_CFLAGS) \
	  $(CORE_SOURCES) c_src/signal_curve_test.c -o "$(BUILD_DIR)/signal_curve_test" $(SODIUM_LIBS)
	"$(BUILD_DIR)/signal_curve_test"

clean:
	rm -f "$(NIF)"
	rm -rf "$(BUILD_DIR)"
