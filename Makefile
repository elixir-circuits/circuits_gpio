# Makefile for building the NIF
#
# Makefile targets:
#
# all/install   build and install the NIF
# clean         clean build products and intermediates
#
# Variables to override:
#
# BUILD         where to store intermediate files (defaults to src directory)
# PREFIX        path to the installation direction (defaults to ./priv)
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS	compiler flags for compiling all C files
# ERL_CFLAGS	additional compiler flags for files using Erlang header files
# ERL_EI_INCLUDE_DIR include path to ei.h (Required for crosscompile)
# ERL_EI_LIBDIR path to libei.a (Required for crosscompile)
# LDFLAGS	linker flags for linking all binaries
# ERL_LDFLAGS	additional linker flags for projects referencing Erlang libraries

PREFIX ?= priv
BUILD ?= src

NIF = $(PREFIX)/gpio_nif.so

TARGET_CFLAGS = $(shell src/detect_target.sh)
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -pedantic
CFLAGS += $(TARGET_CFLAGS)

# Check that we're on a supported build platform
ifeq ($(CROSSCOMPILE),)
    # Not crosscompiling.
    ifeq ($(shell uname -s),Darwin)
        $(warning Elixir Circuits only works on Nerves and Linux.)
        $(warning Compiling a stub NIF for testing.)
	HAL_SRC = src/hal_stub.c
        LDFLAGS += -undefined dynamic_lookup -dynamiclib
    else
        ifeq ($(MIX_ENV),test)
            $(warning Compiling stub NIF to support 'mix test')
            HAL_SRC = src/hal_stub.c
        endif
        LDFLAGS += -fPIC -shared
        CFLAGS += -fPIC
    endif
else
# Crosscompiled build
LDFLAGS += -fPIC -shared
endif

# Set Erlang-specific compile and linker flags
ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

HAL_SRC ?= src/hal_sysfs.c src/hal_sysfs_interrupts.c src/hal_rpi.c
HAL_SRC += src/nif_utils.c
SRC =$(HAL_SRC) src/gpio_nif.c
HEADERS =$(wildcard src/*.h)
OBJ = $(SRC:src/%.c=$(BUILD)/%.o)

calling_from_make:
	mix compile

all: install

install: $(PREFIX) $(BUILD) $(NIF)

$(OBJ): $(BUILD) $(HEADERS) Makefile

$(BUILD)/%.o: src/%.c
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(NIF): $(OBJ)
	$(CC) -o $@ $(ERL_LDFLAGS) $(LDFLAGS) $^

$(PREFIX):
	mkdir -p $@

$(BUILD):
	mkdir -p $@

clean:
	$(RM) $(NIF) $(BUILD)/*.o

.PHONY: all clean calling_from_make install
