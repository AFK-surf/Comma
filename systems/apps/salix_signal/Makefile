# Builds the salix_signal NIF (Opus codec over libopus). elixir_make runs
# `make all` with MIX_APP_PATH and ERTS_INCLUDE_DIR set.
#
# Requires the libopus headers and pkg-config (Debian/Ubuntu: libopus-dev
# pkg-config; macOS: brew install opus pkg-config).

MIX_APP_PATH ?= $(CURDIR)/../../_build/dev/lib/salix_signal
PRIV_DIR := $(MIX_APP_PATH)/priv
NIF := $(PRIV_DIR)/salix_signal_opus.so

ifeq ($(ERTS_INCLUDE_DIR),)
ERTS_INCLUDE_DIR := $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
endif

OPUS_CFLAGS := $(shell pkg-config --cflags opus)
OPUS_LIBS := $(shell pkg-config --libs opus)

CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -fPIC -fvisibility=hidden $(OPUS_CFLAGS)
NIF_CFLAGS := $(CFLAGS) -I"$(ERTS_INCLUDE_DIR)"

ifeq ($(shell uname -s),Darwin)
NIF_LDFLAGS := -dynamiclib -undefined dynamic_lookup
else
NIF_LDFLAGS := -shared
endif

.PHONY: all clean

all: $(NIF)

$(NIF): c_src/salix_signal_opus.c
	@mkdir -p "$(PRIV_DIR)"
	$(CC) $(NIF_CFLAGS) c_src/salix_signal_opus.c -o "$@" $(NIF_LDFLAGS) $(LDFLAGS) $(OPUS_LIBS)

clean:
	rm -f "$(NIF)"
