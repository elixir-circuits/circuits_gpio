// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2018 Mark Sebald
// SPDX-FileCopyrightText: 2018 Matt Ludwigs
// SPDX-FileCopyrightText: 2023 Connor Rigby
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
ERL_NIF_TERM atom_ref;
ERL_NIF_TERM atom_timestamp;
ERL_NIF_TERM atom_value;
ERL_NIF_TERM atom_previous_value;

#ifdef DEBUG
FILE *log_location = NULL;
#endif

static void release_gpio_pin(struct gpio_priv *priv, struct gpio_pin *pin)
{
    hal_close_gpio(pin);
    if (pin->env) {
        enif_free_env(pin->env);
        pin->env = NULL;
    }
}

static void register_gpio_pin(struct gpio_priv *priv, struct gpio_pin *pin)
{
    enif_mutex_lock(priv->gpio_pins_lock);
    pin->next = priv->gpio_pins;
    priv->gpio_pins = pin;
    pin->registered = true;
    enif_mutex_unlock(priv->gpio_pins_lock);
}

static void unregister_gpio_pin(struct gpio_priv *priv, struct gpio_pin *pin)
{
    enif_mutex_lock(priv->gpio_pins_lock);

    if (pin->registered) {
        struct gpio_pin **current = &priv->gpio_pins;

        while (*current && *current != pin)
            current = &(*current)->next;

        if (*current == pin)
            *current = pin->next;

        pin->registered = false;
        pin->next = NULL;
    }

    enif_mutex_unlock(priv->gpio_pins_lock);
}

// Reset the pin's environment to hold exactly the terms it needs. Without this,
// repeated subscribe calls would accumulate copies in pin->env and grow it
// without bound.
static void set_pin_terms(struct gpio_pin *pin,
                          ERL_NIF_TERM gpio_spec,
                          bool notify_map,
                          ERL_NIF_TERM notify_id)
{
    enif_clear_env(pin->env);
    pin->gpio_spec = enif_make_copy(pin->env, gpio_spec);
    pin->notify_id = notify_map ? enif_make_copy(pin->env, notify_id) : 0;
}

static void gpio_pin_dtor(ErlNifEnv *env, void *obj)
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin = (struct gpio_pin*) obj;

    debug("gpio_pin_dtor called on pin={%s,%d+%d}", pin->gpiochip, pin->offsets[0], pin->num_lines);

    unregister_gpio_pin(priv, pin);
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
    debug("gpio_pin_stop called %s, pin={%s,%d}", (is_direct_call ? "DIRECT" : "LATER"), pin->gpiochip, pin->offsets[0]);
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
    debug("gpio_pin_down called on pin={%s,%d}", pin->gpiochip, pin->offsets[0]);
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
                      ErlNifEnv *msg_env,
                      ERL_NIF_TERM gpio_spec,
                      ErlNifPid *pid,
                      int64_t timestamp,
                      int value)
{
    // gpio_spec lives in the pin's environment, so it has to be copied to
    // msg_env before it can be used in a term created there.
    ERL_NIF_TERM msg = enif_make_tuple4(msg_env,
                                        atom_circuits_gpio,
                                        enif_make_copy(msg_env, gpio_spec),
                                        enif_make_int64(msg_env, timestamp),
                                        enif_make_int(msg_env, value));

    int rc = enif_send(env, pid, msg_env, msg);

    // Clear msg_env so that it can be reused. Not clearing it would leak the
    // message terms until the environment is freed.
    enif_clear_env(msg_env);

    return rc;
}

int send_gpio_change(ErlNifEnv *env,
                     ErlNifEnv *msg_env,
                     ERL_NIF_TERM notify_id,
                     ErlNifPid *pid,
                     int64_t timestamp,
                     uint64_t value,
                     uint64_t previous_value)
{
    // notify_id lives in the pin's environment, so it has to be copied to
    // msg_env before it can be used in a term created there.
    ERL_NIF_TERM map = enif_make_new_map(msg_env);
    enif_make_map_put(msg_env, map, atom_ref, enif_make_copy(msg_env, notify_id), &map);
    enif_make_map_put(msg_env, map, atom_timestamp, enif_make_int64(msg_env, timestamp), &map);
    enif_make_map_put(msg_env, map, atom_value, enif_make_uint64(msg_env, value), &map);
    enif_make_map_put(msg_env, map, atom_previous_value, enif_make_uint64(msg_env, previous_value), &map);

    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, atom_circuits_gpio, map);

    int rc = enif_send(env, pid, msg_env, msg);

    enif_clear_env(msg_env);

    return rc;
}

bool emit_gpio_change(ErlNifEnv *env,
                      ErlNifEnv *msg_env,
                      bool notify_map,
                      ERL_NIF_TERM notify_term,
                      ErlNifPid *pid,
                      enum trigger_mode emit_trigger,
                      int64_t timestamp,
                      uint64_t new_value,
                      uint64_t previous_value,
                      int changed_bit)
{
    int new_bit = (int) ((new_value >> changed_bit) & 1);
    bool rising = new_bit != 0;

    bool want;
    switch (emit_trigger) {
    case TRIGGER_BOTH:
        want = true;
        break;
    case TRIGGER_RISING:
        want = rising;
        break;
    case TRIGGER_FALLING:
        want = !rising;
        break;
    case TRIGGER_NONE:
    default:
        want = false;
        break;
    }

    if (!want)
        return true;

    if (notify_map)
        return send_gpio_change(env, msg_env, notify_term, pid, timestamp, new_value, previous_value);
    else
        return send_gpio_message(env, msg_env, notify_term, pid, timestamp, new_bit);
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
    atom_ref = enif_make_atom(env, "ref");
    atom_timestamp = enif_make_atom(env, "timestamp");
    atom_value = enif_make_atom(env, "value");
    atom_previous_value = enif_make_atom(env, "previous_value");

    size_t extra_size = hal_priv_size();
    struct gpio_priv *priv = enif_alloc(sizeof(struct gpio_priv) + extra_size);
    if (!priv) {
        error("Can't allocate gpio_priv");
        return 1;
    }

    priv->gpio_pin_rt = enif_open_resource_type_x(env, "gpio_pin", &gpio_pin_init, ERL_NIF_RT_CREATE, NULL);
    priv->gpio_pins_lock = enif_mutex_create("gpio_pins");
    priv->gpio_pins = NULL;

    if (!priv->gpio_pins_lock) {
        error("Can't create GPIO pin lock");
        enif_free(priv);
        return 1;
    }

    if (hal_load(&priv->hal_priv) < 0) {
        error("Can't initialize HAL");
        enif_mutex_destroy(priv->gpio_pins_lock);
        enif_free(priv);
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

    uint64_t value;
    int rc = hal_read_gpio(pin, &value);
    if (rc < 0)
        return enif_raise_exception(env, make_errno_atom(env, rc));

    return enif_make_uint64(env, value);
}

static ERL_NIF_TERM write_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    ErlNifUInt64 value;
    if (argc != 2 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !enif_get_uint64(env, argv[1], &value))
        return enif_make_badarg(env);

    if (!pin->config.is_output)
        return enif_raise_exception(env, enif_make_atom(env, "pin_not_output"));

    int rc = hal_write_gpio(pin, value, env);
    if (rc < 0)
        return enif_raise_exception(env, make_errno_atom(env, rc));

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

// Parse a resolved group location: {gpiochip_binary, [offset, ...]}. All lines
// in a group live on the same controller.
static int get_resolved_group(ErlNifEnv *env, ERL_NIF_TERM term, char *gpiochip_path, int *offsets, int *num_lines)
{
    int arity;
    const ERL_NIF_TERM *tuple;
    ErlNifBinary gpiochip_binary;

    if (!enif_get_tuple(env, term, &arity, &tuple) ||
            arity != 2 ||
            !enif_inspect_binary(env, tuple[0], &gpiochip_binary) ||
            gpiochip_binary.size + 1 > MAX_GPIOCHIP_PATH_LEN)
        return false;

    memcpy(gpiochip_path, gpiochip_binary.data, gpiochip_binary.size);
    gpiochip_path[gpiochip_binary.size] = '\0';

    unsigned int len;
    if (!enif_get_list_length(env, tuple[1], &len) || len == 0 || len > GPIO_MAX_LINES)
        return false;

    ERL_NIF_TERM list = tuple[1];
    ERL_NIF_TERM head, tail;
    int i = 0;
    while (enif_get_list_cell(env, list, &head, &tail)) {
        if (!enif_get_int(env, head, &offsets[i]))
            return false;
        i++;
        list = tail;
    }

    *num_lines = (int) len;
    return true;
}

static int get_value(ErlNifEnv *env, ERL_NIF_TERM term, uint64_t *value)
{
    ErlNifUInt64 v;
    if (enif_get_uint64(env, term, &v)) {
        *value = v;
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

static int get_drive_mode(ErlNifEnv *env, ERL_NIF_TERM term, enum drive_mode *drive)
{
    char buffer[16];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("push_pull", buffer) == 0) *drive = DRIVE_PUSH_PULL;
    else if (strcmp("open_drain", buffer) == 0) *drive = DRIVE_OPEN_DRAIN;
    else if (strcmp("open_source", buffer) == 0) *drive = DRIVE_OPEN_SOURCE;
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

    // Groups have no single-line tuple representation; they must use subscribe/3.
    if (pin->num_lines != 1)
        return enif_make_tuple2(env, atom_error, enif_make_atom(env, "group_handle"));

    struct gpio_config old_config = pin->config;
    if (!get_trigger(env, argv[1], &pin->config.trigger) ||
            !enif_get_boolean(env, argv[2], &pin->config.suppress_glitches) ||
            !enif_get_local_pid(env, argv[3], &pin->config.pid)) {
        pin->config = old_config;
        return enif_make_badarg(env);
    }

    // Legacy notifications emit on exactly the hardware-detected edge and use
    // the {:circuits_gpio, spec, ts, value} tuple format.
    pin->config.emit_trigger = pin->config.trigger;
    pin->notify_map = false;

    int rc = hal_apply_interrupts(pin, env);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM subscribe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    // subscribe(resource, notify_id, trigger, pid)
    if (argc != 4 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    bool old_notify_map = pin->notify_map;
    ERL_NIF_TERM old_gpio_spec = enif_make_copy(env, pin->gpio_spec);
    ERL_NIF_TERM old_notify_id = old_notify_map ? enif_make_copy(env, pin->notify_id) : 0;
    enum trigger_mode emit_trigger;
    ErlNifPid pid;
    if (!get_trigger(env, argv[2], &emit_trigger) ||
            !enif_get_local_pid(env, argv[3], &pid)) {
        return enif_make_badarg(env);
    }

    // Seed the shadow with the current value so the first notification's
    // previous_value is well defined.
    uint64_t seed;
    if (hal_read_gpio(pin, &seed) >= 0)
        pin->shadow = seed;

    // The hardware tracks both edges so the shadow stays accurate even when the
    // caller only wants one direction; emit_trigger filters what's sent.
    pin->config.trigger = (emit_trigger == TRIGGER_NONE) ? TRIGGER_NONE : TRIGGER_BOTH;
    pin->config.emit_trigger = emit_trigger;
    pin->config.pid = pid;
    pin->notify_map = true;
    set_pin_terms(pin, old_gpio_spec, true, argv[1]);

    int rc = hal_apply_interrupts(pin, env);
    if (rc < 0) {
        pin->config = old_config;
        pin->notify_map = old_notify_map;
        set_pin_terms(pin, old_gpio_spec, old_notify_map, old_notify_id);
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM unsubscribe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 1 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    pin->config.trigger = TRIGGER_NONE;
    pin->config.emit_trigger = TRIGGER_NONE;

    int rc = hal_apply_interrupts(pin, env);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    pin->notify_map = false;
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

static ERL_NIF_TERM set_drive_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    if (argc != 2 ||
            !enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    struct gpio_config old_config = pin->config;
    if (!get_drive_mode(env, argv[1], &pin->config.drive))
        return enif_make_badarg(env);

    int rc = hal_apply_drive_mode(pin);
    if (rc < 0) {
        pin->config = old_config;
        return make_errno_error(env, rc);
    }

    return atom_ok;
}

static ERL_NIF_TERM get_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    char gpiochip_path[MAX_GPIOCHIP_PATH_LEN];
    int offset;

    if (argc != 1 || !get_resolved_location(env, argv[0], gpiochip_path, &offset))
        return enif_make_badarg(env);

    ERL_NIF_TERM result;
    int rc = hal_get_status(priv->hal_priv, env, gpiochip_path, offset, &result);
    if (rc >= 0)
        return make_ok_tuple(env, result);
    else
        return make_errno_error(env, rc);
}

static ERL_NIF_TERM open_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    bool is_output;
    int offsets[GPIO_MAX_LINES];
    int num_lines;
    uint64_t initial_value;
    enum pull_mode pull;
    enum drive_mode drive;
    char gpiochip_path[MAX_GPIOCHIP_PATH_LEN];

    if (argc != 6 ||
            !get_resolved_group(env, argv[1], gpiochip_path, offsets, &num_lines) ||
            !get_direction(env, argv[2], &is_output) ||
            !get_value(env, argv[3], &initial_value) ||
            !get_pull_mode(env, argv[4], &pull) ||
            !get_drive_mode(env, argv[5], &drive))
        return enif_make_badarg(env);

    debug("open {%s, %d lines}", gpiochip_path, num_lines);

    struct gpio_pin *pin = enif_alloc_resource(priv->gpio_pin_rt, sizeof(struct gpio_pin));
    pin->fd = -1;
    memcpy(pin->gpiochip, gpiochip_path, MAX_GPIOCHIP_PATH_LEN);
    pin->num_lines = num_lines;
    memcpy(pin->offsets, offsets, sizeof(int) * num_lines);
    pin->shadow = 0;
    pin->env = enif_alloc_env();
    pin->gpio_spec = enif_make_copy(pin->env, argv[0]);
    pin->notify_id = 0;
    pin->notify_map = false;
    pin->next = NULL;
    pin->registered = false;
    pin->hal_priv = priv->hal_priv;
    pin->config.is_output = is_output;
    pin->config.trigger = TRIGGER_NONE;
    pin->config.emit_trigger = TRIGGER_NONE;
    pin->config.pull = pull;
    pin->config.drive = drive;
    pin->config.suppress_glitches = false;
    pin->config.initial_value = initial_value;

    int rc = hal_open_gpio(pin, env);
    if (rc < 0) {
        enif_release_resource(pin);
        return make_errno_error(env, rc);
    }

    register_gpio_pin(priv, pin);

    // Transfer ownership of the resource to Erlang so that it can be garbage collected.
    ERL_NIF_TERM pin_resource = enif_make_resource(env, pin);
    enif_release_resource(pin);

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

static bool pin_references_gpio(struct gpio_pin *pin, const char *gpiochip_path, int offset)
{
    if (strcmp(pin->gpiochip, gpiochip_path) != 0)
        return false;

    for (int i = 0; i < pin->num_lines; i++) {
        if (pin->offsets[i] == offset)
            return true;
    }

    return false;
}

static ERL_NIF_TERM force_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    char gpiochip_path[MAX_GPIOCHIP_PATH_LEN];
    int offset;

    if (argc != 1 || !get_resolved_location(env, argv[0], gpiochip_path, &offset))
        return enif_make_badarg(env);

    enif_mutex_lock(priv->gpio_pins_lock);
    for (struct gpio_pin *pin = priv->gpio_pins; pin; pin = pin->next) {
        if (pin_references_gpio(pin, gpiochip_path, offset)) {
            // Close the GPIO, but don't free up everything until the pin
            // has been properly closed.
            hal_close_gpio(pin);
        }
    }
    enif_mutex_unlock(priv->gpio_pins_lock);

    return atom_ok;
}

static ERL_NIF_TERM backend_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    (void) argv;

    struct gpio_priv *priv = enif_priv_data(env);
    ERL_NIF_TERM info = enif_make_new_map(env);

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
    {"open", 6, open_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, close_gpio, 0},
    {"force_close", 1, force_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read", 1, read_gpio, 0},
    {"write", 2, write_gpio, 0},
    {"set_interrupts", 4, set_interrupts, 0},
    {"subscribe", 4, subscribe, 0},
    {"unsubscribe", 1, unsubscribe, 0},
    {"set_direction", 2, set_direction, 0},
    {"set_pull_mode", 2, set_pull_mode, 0},
    {"set_drive_mode", 2, set_drive_mode, 0},
    {"status", 1, get_status, 0},
    {"backend_info", 0, backend_info, 0},
    {"enumerate", 0, gpio_enumerate, 0}
};

ERL_NIF_INIT(Elixir.Circuits.GPIO.Nif, nif_funcs, load, NULL, NULL, unload)
