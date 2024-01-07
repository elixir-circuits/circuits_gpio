// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

ERL_NIF_TERM atom_ok;
ERL_NIF_TERM atom_error;
ERL_NIF_TERM atom_name;
ERL_NIF_TERM atom_label;
ERL_NIF_TERM atom_location;
ERL_NIF_TERM atom_controller;
ERL_NIF_TERM atom_circuits_gpio;
ERL_NIF_TERM atom_consumer;

#ifdef DEBUG
FILE *log_location = NULL;
#endif

static void release_gpio_pin(struct gpio_priv *priv, struct gpio_pin *pin)
{
    if (pin->env) {
        enif_free_env(pin->env);
        pin->env = 0;
    }
    if (pin->fd >= 0) {
        hal_close_gpio(pin);
        priv->pins_open--;
        pin->fd = -1;
    }
}

static void gpio_pin_dtor(ErlNifEnv *env, void *obj)
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin = (struct gpio_pin*) obj;

    debug("gpio_pin_dtor called on pin={%s,%d}", pin->gpiochip, pin->offset);

    release_gpio_pin(priv, pin);
}

static void gpio_pin_stop(ErlNifEnv *env, void *obj, int fd, int is_direct_call)
{
    (void) env;
    (void) obj;
    (void) fd;
    (void) is_direct_call;
    //struct gpio_priv *priv = enif_priv_data(env);
#ifdef DEBUG
    struct gpio_pin *pin = (struct gpio_pin*) obj;
    debug("gpio_pin_stop called %s, pin={%s,%d}", (is_direct_call ? "DIRECT" : "LATER"), pin->gpiochip, pin->offset);
#endif
}

static void gpio_pin_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *monitor)
{
    (void) env;
    (void) obj;
    (void) pid;
    (void) monitor;
#ifdef DEBUG
    struct gpio_pin *pin = (struct gpio_pin*) obj;
    debug("gpio_pin_down called on pin={%s,%d}", pin->gpiochip, pin->offset);
#endif
}

#if (ERL_NIF_MAJOR_VERSION == 2 && ERL_NIF_MINOR_VERSION >= 16)
// OTP-24 and later
static ErlNifResourceTypeInit gpio_pin_init = {gpio_pin_dtor, gpio_pin_stop, gpio_pin_down, 3, NULL};
#else
// Old way
static ErlNifResourceTypeInit gpio_pin_init = {gpio_pin_dtor, gpio_pin_stop, gpio_pin_down};
#endif

int send_gpio_message(ErlNifEnv *env,
                      ERL_NIF_TERM gpio_spec,
                      ErlNifPid *pid,
                      int64_t timestamp,
                      int value)
{
    ERL_NIF_TERM msg = enif_make_tuple4(env,
                                        atom_circuits_gpio,
                                        gpio_spec,
                                        enif_make_int64(env, timestamp),
                                        enif_make_int(env, value));

    return enif_send(env, pid, NULL, msg);
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM info)
{
    (void) info;
#ifdef DEBUG
#ifdef LOG_PATH
    log_location = fopen(LOG_PATH, "w");
#else
    log_location = stderr;
#endif
#endif
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_name = enif_make_atom(env, "name");
    atom_label = enif_make_atom(env, "label");
    atom_location = enif_make_atom(env, "location");
    atom_controller = enif_make_atom(env, "controller");
    atom_circuits_gpio = enif_make_atom(env, "circuits_gpio");
    atom_consumer = enif_make_atom(env, "consumer");

    size_t extra_size = hal_priv_size();
    struct gpio_priv *priv = enif_alloc(sizeof(struct gpio_priv) + extra_size);
    if (!priv) {
        error("Can't allocate gpio_priv");
        return 1;
    }

    priv->pins_open = 0;
    priv->gpio_pin_rt = enif_open_resource_type_x(env, "gpio_pin", &gpio_pin_init, ERL_NIF_RT_CREATE, NULL);

    if (hal_load(&priv->hal_priv) < 0) {
        error("Can't initialize HAL");
        return 1;
    }

    *priv_data = (void *) priv;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data)
{
    (void) env;

    struct gpio_priv *priv = priv_data;
    debug("unload");

    hal_unload(&priv->hal_priv);
}

static ERL_NIF_TERM read_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 1 || !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    int value = hal_read_gpio(pin);
    if (value < 0)
        return enif_raise_exception(env, enif_make_atom(env, strerror(errno)));

    return enif_make_int(env, value);
}

static ERL_NIF_TERM write_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    int value;
    if (argc != 2 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !enif_get_int(env, argv[1], &value))
        return enif_make_badarg(env);

    if (!pin->config.is_output)
        return enif_raise_exception(env, enif_make_atom(env, "pin_not_input"));

    // Make sure value is 0 or 1
    value = !!value;

    if (hal_write_gpio(pin, value, env) < 0)
        return enif_raise_exception(env, enif_make_atom(env, strerror(errno)));

    return atom_ok;
}

static int get_trigger(ErlNifEnv *env, ERL_NIF_TERM term, enum trigger_mode *mode)
{
    char buffer[16];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("none", buffer) == 0) *mode = TRIGGER_NONE;
    else if (strcmp("rising", buffer) == 0) *mode = TRIGGER_RISING;
    else if (strcmp("falling", buffer) == 0) *mode = TRIGGER_FALLING;
    else if (strcmp("both", buffer) == 0) *mode = TRIGGER_BOTH;
    else return false;

    return true;
}

static int get_direction(ErlNifEnv *env, ERL_NIF_TERM term, bool *is_output)
{
    char buffer[8];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("input", buffer) == 0) *is_output = false;
    else if (strcmp("output", buffer) == 0) *is_output = true;
    else return false;

    return true;
}

static int get_resolved_location(ErlNifEnv *env, ERL_NIF_TERM term, char *gpiochip_path, int *offset)
{
    int arity;
    const ERL_NIF_TERM *tuple;
    ErlNifBinary gpiochip_binary;

    if (!enif_get_tuple(env, term, &arity, &tuple) ||
            arity != 2 ||
            !enif_inspect_binary(env, tuple[0], &gpiochip_binary) ||
            gpiochip_binary.size + 1 > MAX_GPIOCHIP_PATH_LEN ||
            !enif_get_int(env, tuple[1], offset))
        return false;

    memcpy(gpiochip_path, gpiochip_binary.data, gpiochip_binary.size);
    gpiochip_path[gpiochip_binary.size] = '\0';
    return true;
}

static int get_value(ErlNifEnv *env, ERL_NIF_TERM term, int *value)
{
    int v;
    if (enif_get_int(env, term, &v)) {
        // Force v to be 0 or 1
        *value = !!v;
    } else {
        // Interpret anything else as 0 for backwards compatibility
        // with Circuit.GPIO v1's ":not_set". 0 is cdev's default.
        *value = 0;
    }
    return true;
}

static int get_pull_mode(ErlNifEnv *env, ERL_NIF_TERM term, enum pull_mode *pull)
{
    char buffer[16];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("not_set", buffer) == 0) *pull = PULL_NOT_SET;
    else if (strcmp("none", buffer) == 0) *pull = PULL_NONE;
    else if (strcmp("pullup", buffer) == 0) *pull = PULL_UP;
    else if (strcmp("pulldown", buffer) == 0) *pull = PULL_DOWN;
    else return false;

    return true;
}

static ERL_NIF_TERM set_interrupts(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 4 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    if (!get_trigger(env, argv[1], &pin->config.trigger) ||
            !enif_get_boolean(env, argv[2], &pin->config.suppress_glitches) ||
            !enif_get_local_pid(env, argv[3], &pin->config.pid)) {
        pin->config = old_config;
        return enif_make_badarg(env);
    }

    int rc = hal_apply_interrupts(pin, env);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM set_direction(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 2 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    if (!get_direction(env, argv[1], &pin->config.is_output))
        return enif_make_badarg(env);

    int rc = hal_apply_direction(pin);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM set_pull_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 2 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    if (!get_pull_mode(env, argv[1], &pin->config.pull))
        return enif_make_badarg(env);

    int rc = hal_apply_pull_mode(pin);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM get_gpio_spec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (argc != 1 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    return pin->gpio_spec;
}

static ERL_NIF_TERM get_pin_number(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (argc != 1 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    return enif_make_int(env, pin->pin_number);
}

static ERL_NIF_TERM open_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    bool is_output;
    int offset;
    int initial_value;
    enum pull_mode pull;
    char gpiochip_path[MAX_GPIOCHIP_PATH_LEN];

    if (argc != 5 ||
            !get_resolved_location(env, argv[1], gpiochip_path, &offset) ||
            !get_direction(env, argv[2], &is_output) ||
            !get_value(env, argv[3], &initial_value) ||
            !get_pull_mode(env, argv[4], &pull))
        return enif_make_badarg(env);

    debug("open {%s, %d}", gpiochip_path, offset);

    struct gpio_pin *pin = enif_alloc_resource(priv->gpio_pin_rt, sizeof(struct gpio_pin));
    pin->fd = -1;
    memcpy(pin->gpiochip, gpiochip_path, MAX_GPIOCHIP_PATH_LEN);
    pin->offset = offset;
    pin->env = enif_alloc_env();
    pin->gpio_spec = enif_make_copy(pin->env, argv[0]);
    pin->pin_number = -1; // Filled in by lower level
    pin->hal_priv = priv->hal_priv;
    pin->config.is_output = is_output;
    pin->config.trigger = TRIGGER_NONE;
    pin->config.pull = pull;
    pin->config.suppress_glitches = false;
    pin->config.initial_value = initial_value;

    int rc = hal_open_gpio(pin, env);
    if (rc < 0) {
        enif_release_resource(pin);
        return make_errno_error(env, rc);
    }

    // Transfer ownership of the resource to Erlang so that it can be garbage collected.
    ERL_NIF_TERM pin_resource = enif_make_resource(env, pin);
    enif_release_resource(pin);

    priv->pins_open++;

    return make_ok_tuple(env, pin_resource);
}

static ERL_NIF_TERM close_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (argc != 1 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    release_gpio_pin(priv, pin);

    return atom_ok;
}
static ERL_NIF_TERM gpio_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    (void) argv;

    struct gpio_priv *priv = enif_priv_data(env);
    ERL_NIF_TERM info = enif_make_new_map(env);

    enif_make_map_put(env, info, enif_make_atom(env, "pins_open"), enif_make_int(env, priv->pins_open), &info);

    return hal_info(env, priv->hal_priv, info);
}

static ERL_NIF_TERM gpio_enumerate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    (void) argv;

    struct gpio_priv *priv = enif_priv_data(env);

    return hal_enumerate(env, priv->hal_priv);
}

static ErlNifFunc nif_funcs[] = {
    {"open", 5, open_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, close_gpio, 0},
    {"read", 1, read_gpio, 0},
    {"write", 2, write_gpio, 0},
    {"set_interrupts", 4, set_interrupts, 0},
    {"set_direction", 2, set_direction, 0},
    {"set_pull_mode", 2, set_pull_mode, 0},
    {"gpio_spec", 1, get_gpio_spec, 0},
    {"pin_number", 1, get_pin_number, 0},
    {"info", 0, gpio_info, 0},
    {"enumerate", 0, gpio_enumerate, 0},
};

ERL_NIF_INIT(Elixir.Circuits.GPIO.Nif, nif_funcs, load, NULL, NULL, unload)
