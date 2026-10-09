# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

# Builds `bonjex_port`, the libdns_sd client. Driven by `elixir_make`.
#
# On macOS, <dns_sd.h> is in the SDK and the implementation is in libSystem.
# On Linux and Nerves, libdns_sd comes from Apple's mDNSResponder:
# https://github.com/apple-oss-distributions/mDNSResponder
# On Nerves, `CROSSCOMPILE` and `NERVES_SDK_SYSROOT` come from the system's
# environment, and the system must put dns_sd.h and libdns_sd in its sysroot.

PREFIX ?= $(MIX_APP_PATH)/priv
BUILD  ?= $(MIX_APP_PATH)/obj

TARGET = $(PREFIX)/bonjex_port
SRC    = c_src/bonjex_port.c
PROBE  = $(BUILD)/probe.c

CFLAGS  ?= -O2 -Wall -Wextra -std=gnu99
LDFLAGS ?=

# libSystem has the implementation only when building for the macOS host. A
# cross build from a Mac still targets Linux, so key on CROSSCOMPILE, not uname.
ifeq ($(CROSSCOMPILE)$(shell uname -s),Darwin)
    LIBS =
else
    LIBS = -ldns_sd
endif

ifeq ($(CROSSCOMPILE),)
    # Host build. A dev box or CI runner without libdns_sd gets a loud skip
    # rather than a failed build: the library still compiles and its unit
    # tests still run, and a connection retries a missing binary forever.
    # Set BONJEX_REQUIRE_PORT=1 to make a missing library an error instead.
    HAVE_DNSSD := $(shell mkdir -p $(BUILD) && printf '\043include <dns_sd.h>\nint main(void){return 0;}\n' > $(PROBE) && $(CC) $(CFLAGS) -o /dev/null $(PROBE) $(LDFLAGS) $(LIBS) 2>/dev/null && echo yes)
else
    # Cross build. A missing header here means the target system was built
    # without libdns_sd, and skipping would ship firmware with no DNS-SD.
    ifeq ($(wildcard $(NERVES_SDK_SYSROOT)/usr/include/dns_sd.h),)
        $(error bonjex: $(NERVES_SDK_SYSROOT)/usr/include/dns_sd.h is missing. \
          Add mDNSResponder (https://github.com/apple-oss-distributions/mDNSResponder) to the Nerves system)
    endif
    HAVE_DNSSD := yes
    CFLAGS  += -I$(NERVES_SDK_SYSROOT)/usr/include
    LDFLAGS += -L$(NERVES_SDK_SYSROOT)/usr/lib
endif

calling_from_make:
	mix compile

ifeq ($(HAVE_DNSSD),yes)
all: $(TARGET)
else ifeq ($(BONJEX_REQUIRE_PORT),1)
all:
	$(error bonjex: <dns_sd.h>/libdns_sd not found)
else
all:
	@echo "*** bonjex: <dns_sd.h>/libdns_sd not found - skipping bonjex_port."
	@echo "*** Bonjex connections will not reach a responder on this host."
endif

$(TARGET): $(SRC) Makefile | $(PREFIX)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

$(PREFIX):
	mkdir -p $@

clean:
	$(RM) $(TARGET)

.PHONY: all clean calling_from_make
