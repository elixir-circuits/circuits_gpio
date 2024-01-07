// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"
#include <errno.h>
#include <string.h>

#define NUM_GPIOS 64

/**
 * The stub hardware abstraction layer is suitable for some unit testing.
 *
 * gpiochip0 -> 32 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 * gpiochip1 -> 32 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 */

struct stub_priv {
    int in_use[NUM_GPIOS]; // 0=no; 1=yes
    int value[NUM_GPIOS]; // -1, 0, 1 -> -1=hiZ
    struct gpio_pin *gpio_pins[NUM_GPIOS];
    ErlNifPid pid[NUM_GPIOS];
    enum trigger_mode mode[NUM_GPIOS];
};

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    (void) hal_priv;

    enif_make_map_put(env, info, atom_name, enif_make_atom(env, "stub"), &info);
    return info;
}

size_t hal_priv_size(void)
{
    return sizeof(struct stub_priv);
}

int hal_load(void *hal_priv)
{
    memset(hal_priv, 0, sizeof(struct stub_priv));
    return 0;
}

void hal_unload(void *hal_priv)
{
    (void) hal_priv;
}

int hal_open_gpio(struct gpio_pin *pin,
                  ErlNifEnv *env)
{
    struct stub_priv *hal_priv = pin->hal_priv;
    int pin_base;

    if (strcmp(pin->gpiochip, "gpiochip0") == 0 ||
            strcmp(pin->gpiochip, "/dev/gpiochip0") == 0) {
        pin_base = 0;
    } else if (strcmp(pin->gpiochip, "gpiochip1") == 0 ||
               strcmp(pin->gpiochip, "/dev/gpiochip1") == 0) {
        pin_base = 32;
    } else {
        return -ENOENT;
    }

    if (pin->offset < 0 || pin->offset >= 32)
        return -ENOENT;

    pin->pin_number = pin_base + pin->offset;
    pin->fd = pin->pin_number;
    hal_priv->gpio_pins[pin->pin_number] = pin;

    if (pin->config.is_output) {
        if (pin->config.initial_value >= 0) {
            hal_write_gpio(pin, pin->config.initial_value, env);
        } else if (hal_priv->value[pin->pin_number] == -1) {
            // Default the pin to zero when hi impedance even
            // when no initial value.
            hal_write_gpio(pin, 0, env);
        }
    } else {
        hal_priv->value[pin->pin_number] = -1;
    }
    hal_priv->in_use[pin->pin_number]++;
    return 0;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd >= 0 && pin->fd < NUM_GPIOS) {
        struct stub_priv *hal_priv = pin->hal_priv;
        hal_priv->mode[pin->pin_number] = TRIGGER_NONE;
        hal_priv->gpio_pins[pin->pin_number] = NULL;
        hal_priv->in_use[pin->pin_number]--;
        pin->fd = -1;
    }
}

int hal_read_gpio(struct gpio_pin *pin)
{
    struct stub_priv *hal_priv = pin->hal_priv;
    int our_pin = pin->pin_number;
    int other_pin = our_pin ^ 1;

    if (hal_priv->value[our_pin] != -1)
        return hal_priv->value[our_pin];

    if (hal_priv->value[other_pin] != -1)
        return hal_priv->value[other_pin];

    if (pin->config.pull == PULL_UP)
        return 1;

    if (pin->config.pull == PULL_DOWN)
        return 0;

    // Both the pin and the pin it's connected to are high impedance and pull mode
    // isn't set. This should be random, but that might be more confusing so return 0.
    return 0;
}

static void maybe_send_notification(ErlNifEnv *env, struct gpio_pin *pin, int value)
{
    if (!pin)
        return;

    struct stub_priv *hal_priv = pin->hal_priv;

    int send_it = 0;
    switch (hal_priv->mode[pin->pin_number]) {
    case TRIGGER_BOTH:
        send_it = 1;
        break;
    case TRIGGER_FALLING:
        send_it = (value == 0);
        break;
    case TRIGGER_RISING:
        send_it = (value != 0);
        break;
    case TRIGGER_NONE:
        send_it = 0;
        break;
    }

    if (send_it) {
        ErlNifTime now = enif_monotonic_time(ERL_NIF_NSEC);
        send_gpio_message(env, pin->gpio_spec, &hal_priv->pid[pin->pin_number], now, value);
    }
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    struct stub_priv *hal_priv = pin->hal_priv;
    int our_pin = pin->pin_number;
    int other_pin = our_pin ^ 1;
    if (hal_priv->value[our_pin] != value) {
        hal_priv->value[our_pin] = value;
        maybe_send_notification(env, hal_priv->gpio_pins[our_pin], value);

        // Only notify other pin if it's not outputting a value.
        if (hal_priv->value[other_pin] == -1)
            maybe_send_notification(env, hal_priv->gpio_pins[other_pin], value);
    }
    return 0;
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    struct stub_priv *hal_priv = pin->hal_priv;

    hal_priv->mode[pin->pin_number] = pin->config.trigger;
    hal_priv->pid[pin->pin_number] = pin->config.pid;
    hal_priv->gpio_pins[pin->pin_number] = pin;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    struct stub_priv *hal_priv = pin->hal_priv;

    if (pin->config.is_output) {
        if (hal_priv->value[pin->pin_number] == -1) {
            hal_priv->value[pin->pin_number] = 0;
        }
    } else {
        hal_priv->value[pin->pin_number] = -1;
    }

    return 0;
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

ERL_NIF_TERM hal_enumerate(ErlNifEnv *env, void *hal_priv)
{
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
