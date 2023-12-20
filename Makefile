# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for building the NIF
#
# Makefile targets:
#
# all/install   build and install the NIF
# clean         clean build products and intermediates
#
# Variables to override:
#
# MIX_APP_PATH  path to the build directory
# CIRCUITS_GPIO_BACKEND Backend to build - `"normal"`, `"test"`, or `"disabled"` will build a NIF
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS	compiler flags for compiling all C files
# ERL_CFLAGS	additional compiler flags for files using Erlang header files
# ERL_EI_INCLUDE_DIR include path to ei.h (Required for crosscompile)
# ERL_EI_LIBDIR path to libei.a (Required for crosscompile)
# LDFLAGS	linker flags for linking all binaries
# ERL_LDFLAGS	additional linker flags for projects referencing Erlang libraries

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

NIF = $(PREFIX)/gpio_nif.so

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -pedantic

$(info "**** CIRCUITS_GPIO_BACKEND set to [$(CIRCUITS_GPIO_BACKEND)] ****")

# Check that we're on a supported build platform
ifeq ($(CROSSCOMPILE),)
# Not crosscompiling, so check that we're on Linux for whether to compile the NIF.
ifeq ($(shell uname -s),Linux)
CFLAGS += -fPIC
LDFLAGS += -fPIC -shared
else
LDFLAGS += -undefined dynamic_lookup -dynamiclib
ifeq ($(CIRCUITS_GPIO_BACKEND),normal)
$(error Circuits.GPIO2 Linux cdev backend is not supported on non-Linux platforms. Review circuits_gpio2 backend configuration or report an issue if improperly detected.)
endif
endif
else
# Crosscompiled build
LDFLAGS += -fPIC -shared
CFLAGS += -fPIC
endif

ifeq ($(CIRCUITS_GPIO_BACKEND),normal)
# Enable real GPIO calls. This is the default and works with Nerves
else
ifeq ($(CIRCUITS_GPIO_BACKEND),test)
# Stub out ioctls and send back test data
HAL_SRC = c_src/hal_stub.c
else
# Don't build NIF
NIF =
endif
endif

# Set Erlang-specific compile and linker flags
ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

HAL_SRC ?= c_src/hal_cdev_gpio.c c_src/hal_cdev_gpio_interrupts.c
HAL_SRC += c_src/nif_utils.c
SRC = $(HAL_SRC) c_src/gpio_nif.c
HEADERS =$(wildcard c_src/*.h)
OBJ = $(SRC:c_src/%.c=$(BUILD)/%.o)

calling_from_make:
	mix compile

all: install

install: $(PREFIX) $(BUILD) $(NIF)

$(OBJ): $(HEADERS) Makefile

$(BUILD)/%.o: c_src/%.c
	@echo " CC $(notdir $@)"
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(NIF): $(OBJ)
	@echo " LD $(notdir $@)"
	$(CC) -o $@ $(ERL_LDFLAGS) $(LDFLAGS) $^

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	$(RM) $(NIF) $(OBJ)

.PHONY: all clean calling_from_make install

# Don't echo commands unless the caller exports "V=1"
${V}.SILENT:
