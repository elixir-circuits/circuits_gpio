// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2019 Matt Ludwigs
// SPDX-FileCopyrightText: 2023 Connor Rigby
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"
#include <errno.h>
#include <stdatomic.h>
#include <string.h>

#define NUM_GPIOS 64

/**
 * The stub hardware abstraction layer is suitable for some unit testing.
 *
 * gpiochip0 -> 32 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 * gpiochip1 -> 32 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 *
 * GPIOs can be opened individually or as a group. The state for each line is
 * tracked globally (indexed by the combined chip+offset) so that loopback and
 * notifications work regardless of how the lines were grouped at open time.
 */

struct stub_priv {
    atomic_int pins_open;
    int in_use[NUM_GPIOS]; // 0=no; >0=yes
    int value[NUM_GPIOS]; // -1, 0, 1 -> -1=hiZ
    struct gpio_pin *owner[NUM_GPIOS]; // group that opened this line, or NULL
};

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    struct stub_priv *stub_priv = (struct stub_priv *) hal_priv;
    int pins_open = atomic_load(&stub_priv->pins_open);

    // %{name: {Circuits.GPIO.Cdev, test: true}, pins_open: 123}}
    enif_make_map_put(env, info, atom_name,
                      enif_make_tuple2(env,
                                       enif_make_atom(env, "Elixir.Circuits.GPIO.CDev"),
                                       enif_make_list1(env, enif_make_tuple2(env, enif_make_atom(env, "test"), enif_make_atom(env, "true")))),
                      &info);
    enif_make_map_put(env, info, enif_make_atom(env, "pins_open"), enif_make_int(env, pins_open), &info);

    return info;
}

size_t hal_priv_size(void)
{
    return sizeof(struct stub_priv);
}

int hal_load(void *hal_priv)
{
    struct stub_priv *stub_priv = (struct stub_priv *) hal_priv;

    memset(stub_priv, 0, sizeof(struct stub_priv));
    stub_priv->pins_open = 0;

    return 0;
}

void hal_unload(void *hal_priv)
{
    (void) hal_priv;
}

// Return the global line index base for a gpiochip, or -1 if unknown.
static int chip_base(const char *gpiochip)
{
    if (strcmp(gpiochip, "gpiochip0") == 0 ||
            strcmp(gpiochip, "/dev/gpiochip0") == 0)
        return 0;
    else if (strcmp(gpiochip, "gpiochip1") == 0 ||
             strcmp(gpiochip, "/dev/gpiochip1") == 0)
        return 32;
    else
        return -1;
}

// Resolve the readable logic level of a single global line, honoring the
// even/odd loopback wiring and the group's pull mode.
static int read_line_value(struct stub_priv *stub_priv, struct gpio_pin *pin, int gidx)
{
    int other = gidx ^ 1;

    if (stub_priv->value[gidx] != -1)
        return stub_priv->value[gidx];

    if (stub_priv->value[other] != -1)
        return stub_priv->value[other];

    if (pin->config.pull == PULL_UP)
        return 1;

    if (pin->config.pull == PULL_DOWN)
        return 0;

    // Both the line and the line it's connected to are high impedance and pull
    // mode isn't set. This should be random, but that might be more confusing
    // so return 0.
    return 0;
}

int hal_read_gpio(struct gpio_pin *pin, uint64_t *value)
{
    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base < 0)
        return -ENOENT;

    uint64_t v = 0;
    for (int i = 0; i < pin->num_lines; i++) {
        int gidx = base + pin->offsets[i];
        if (read_line_value(stub_priv, pin, gidx))
            v |= ((uint64_t) 1 << i);
    }
    *value = v;
    return 0;
}

// A single global line changed. Notify the group that owns it (if any and if
// it's listening), updating that group's shadow value and emitting one message.
static void notify_line_change(ErlNifEnv *env, struct stub_priv *stub_priv, int gidx)
{
    struct gpio_pin *owner = stub_priv->owner[gidx];
    if (!owner || owner->config.trigger == TRIGGER_NONE)
        return;

    int base = chip_base(owner->gpiochip);
    if (base < 0)
        return;

    // Which bit of the owning group does this line correspond to?
    int changed_bit = -1;
    for (int i = 0; i < owner->num_lines; i++) {
        if (base + owner->offsets[i] == gidx) {
            changed_bit = i;
            break;
        }
    }
    if (changed_bit < 0)
        return;

    uint64_t new_value;
    if (hal_read_gpio(owner, &new_value) < 0)
        return;

    uint64_t previous_value = owner->shadow;
    owner->shadow = new_value;

    ErlNifTime now = enif_monotonic_time(ERL_NIF_NSEC);
    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM notify_term = owner->notify_map ? owner->notify_id : owner->gpio_spec;
    emit_gpio_change(env, msg_env, owner->notify_map, notify_term,
                     &owner->config.pid, owner->config.emit_trigger,
                     now, new_value, previous_value, changed_bit);
    enif_free_env(msg_env);
}

int hal_write_gpio(struct gpio_pin *pin, uint64_t value, ErlNifEnv *env)
{
    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base < 0)
        return -ENOENT;

    // When drive_mode is :open_drain or :open_source, a line may be hi-Z
    // (modeled by a value of -1) instead of actively driven.
    bool is_open_drain = pin->config.drive == DRIVE_OPEN_DRAIN;
    bool is_open_source = pin->config.drive == DRIVE_OPEN_SOURCE;

    for (int i = 0; i < pin->num_lines; i++) {
        int gidx = base + pin->offsets[i];
        int bitval = (int) ((value >> i) & 1);

        int target_value;
        if (is_open_drain && bitval == 1)
            target_value = -1;
        else if (is_open_source && bitval == 0)
            target_value = -1;
        else
            target_value = bitval;

        if (stub_priv->value[gidx] != target_value) {
            stub_priv->value[gidx] = target_value;
            notify_line_change(env, stub_priv, gidx);

            // Only notify the loopback partner if it's not driving a value.
            if (stub_priv->value[gidx ^ 1] == -1)
                notify_line_change(env, stub_priv, gidx ^ 1);
        }
    }
    return 0;
}

int hal_open_gpio(struct gpio_pin *pin,
                  ErlNifEnv *env)
{
    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base < 0)
        return -ENOENT;

    for (int i = 0; i < pin->num_lines; i++) {
        if (pin->offsets[i] < 0 || pin->offsets[i] >= 32)
            return -ENOENT;
    }

    for (int i = 0; i < pin->num_lines; i++) {
        int gidx = base + pin->offsets[i];
        stub_priv->owner[gidx] = pin;
        stub_priv->in_use[gidx]++;
        atomic_fetch_add(&stub_priv->pins_open, 1);
        if (!pin->config.is_output)
            stub_priv->value[gidx] = -1;
    }

    // Mark the group as open (fd is only used as an "is open" flag in the stub).
    pin->fd = base + pin->offsets[0];

    if (pin->config.is_output)
        hal_write_gpio(pin, pin->config.initial_value, env);

    return 0;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd < 0)
        return;

    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base >= 0) {
        for (int i = 0; i < pin->num_lines; i++) {
            int gidx = base + pin->offsets[i];
            if (stub_priv->owner[gidx] == pin)
                stub_priv->owner[gidx] = NULL;
            if (stub_priv->in_use[gidx] > 0)
                stub_priv->in_use[gidx]--;
            atomic_fetch_sub(&stub_priv->pins_open, 1);
        }
    }

    pin->config.trigger = TRIGGER_NONE;
    pin->fd = -1;
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    (void) env;
    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base < 0)
        return -ENOENT;

    // Notification settings live on pin->config and are read live when a line
    // changes; just (re)assert ownership of the lines.
    for (int i = 0; i < pin->num_lines; i++)
        stub_priv->owner[base + pin->offsets[i]] = pin;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    struct stub_priv *stub_priv = pin->hal_priv;
    int base = chip_base(pin->gpiochip);
    if (base < 0)
        return -ENOENT;

    for (int i = 0; i < pin->num_lines; i++) {
        int gidx = base + pin->offsets[i];
        if (pin->config.is_output) {
            if (stub_priv->value[gidx] == -1)
                stub_priv->value[gidx] = 0;
        } else {
            stub_priv->value[gidx] = -1;
        }
    }

    return 0;
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

int hal_apply_drive_mode(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

ERL_NIF_TERM hal_enumerate(ErlNifEnv *env, void *hal_priv)
{
    (void) hal_priv;
    ERL_NIF_TERM gpio_list = enif_make_list(env, 0);

    ERL_NIF_TERM chip_name0 = make_string_binary(env, "gpiochip0");
    ERL_NIF_TERM chip_name1 = make_string_binary(env, "gpiochip1");
    ERL_NIF_TERM chip_label0 = make_string_binary(env, "stub0");
    ERL_NIF_TERM chip_label1 = make_string_binary(env, "stub1");

    int j;
    for (j = NUM_GPIOS - 1; j >= 0; j--) {
        char line_name[32];
        sprintf(line_name, "pair_%d_%d", j / 2, j % 2);

        ERL_NIF_TERM chip_name = (j >= 32) ? chip_name1 : chip_name0;
        ERL_NIF_TERM chip_label = (j >= 32) ? chip_label1 : chip_label0;
        ERL_NIF_TERM line_map = enif_make_new_map(env);
        ERL_NIF_TERM line_label = make_string_binary(env, line_name);
        ERL_NIF_TERM line_offset = enif_make_int(env, j % 32);

        enif_make_map_put(env, line_map, atom_controller, chip_label, &line_map);
        enif_make_map_put(env, line_map, atom_label, line_label, &line_map);
        enif_make_map_put(env, line_map, atom_location, enif_make_tuple2(env, chip_name, line_offset), &line_map);

        gpio_list = enif_make_list_cell(env, line_map, gpio_list);
    }

    return gpio_list;
}

int hal_get_status(void *hal_priv, ErlNifEnv *env, const char *gpiochip, int offset, ERL_NIF_TERM *result)
{
    struct stub_priv *stub_priv = hal_priv;
    int base = chip_base(gpiochip);
    if (base < 0)
        return -ENOENT;

    if (offset < 0 || offset >= 32)
        return -ENOENT;
    int pin_index = base + offset;

    ERL_NIF_TERM map = enif_make_new_map(env);

    int in_use = stub_priv->in_use[pin_index];
    ERL_NIF_TERM consumer = make_string_binary(env, in_use > 0 ? "stub" : "");

    struct gpio_pin *pin = stub_priv->owner[pin_index];
    const char *pull_mode_str;
    const char *drive_mode_str;
    int is_output;
    if (pin) {
        switch (pin->config.pull) {
        case PULL_DOWN:
            pull_mode_str = "pulldown";
            break;
        case PULL_UP:
            pull_mode_str = "pullup";
            break;
        default:
            pull_mode_str = "none";
            break;
        }

        switch (pin->config.drive) {
        case DRIVE_OPEN_DRAIN:
            drive_mode_str = "open_drain";
            break;
        case DRIVE_OPEN_SOURCE:
            drive_mode_str = "open_source";
            break;
        default:
            drive_mode_str = "push_pull";
            break;
        }

        is_output = pin->config.is_output;
    } else {
        is_output = 0;
        pull_mode_str = "none";
        drive_mode_str = "push_pull";
    }

    enif_make_map_put(env, map, atom_consumer, consumer, &map);
    enif_make_map_put(env, map, enif_make_atom(env, "direction"), enif_make_atom(env, is_output ? "output" : "input"), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "pull_mode"), enif_make_atom(env, pull_mode_str), &map);
    enif_make_map_put(env, map, enif_make_atom(env, "drive_mode"), enif_make_atom(env, drive_mode_str), &map);

    *result = map;
    return 0;
}
