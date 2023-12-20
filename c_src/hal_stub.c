// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"
#include <string.h>

#define NUM_GPIOS 32

/**
 * The stub hardware abstraction layer is suitable for some unit testing.
 * It has 1 bank of 32 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 */

struct stub_priv {
    int value[NUM_GPIOS / 2];
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
                  char *error_str,
                  ErlNifEnv *env)
{
    // For test purposes, pins 0-31 work and everything else fails
    if (strcmp(pin->gpiochip, "gpiochip0") != 0) {
        strcpy(error_str, "open_failed");
        return -1;
    }

    if (pin->pin_number < 0 || pin->pin_number >= NUM_GPIOS) {
        strcpy(error_str, "invalid_pin");
        return -1;
    }

    pin->fd = pin->pin_number;

    if (pin->config.is_output && pin->config.initial_value != -1)
        hal_write_gpio(pin, pin->config.initial_value, env);

    *error_str = '\0';
    return 0;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd >= 0 && pin->fd < NUM_GPIOS) {
        struct stub_priv *hal_priv = pin->hal_priv;
        hal_priv->mode[pin->pin_number] = TRIGGER_NONE;
        pin->fd = -1;
    }
}

static int gpio_value(struct gpio_pin * pin)
{
    struct stub_priv *hal_priv = pin->hal_priv;
    return hal_priv->value[pin->pin_number / 2];
}

int hal_read_gpio(struct gpio_pin *pin)
{
    return gpio_value(pin);
}

static void maybe_send_notification(ErlNifEnv *env, struct stub_priv *hal_priv, int pin_number)
{
    int value = hal_priv->value[pin_number / 2];
    int sendit = 0;
    switch (hal_priv->mode[pin_number]) {
    case TRIGGER_BOTH:
        sendit = 1;
        break;
    case TRIGGER_FALLING:
        sendit = (value == 0);
        break;
    case TRIGGER_RISING:
        sendit = (value != 0);
        break;
    case TRIGGER_NONE:
        sendit = 0;
        break;
    }

    if (sendit) {
        ErlNifTime now = enif_monotonic_time(ERL_NIF_NSEC);
        send_gpio_message(env, enif_make_atom(env, "circuits_gpio2"), pin_number, &hal_priv->pid[pin_number], now, value);
    }
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    struct stub_priv *hal_priv = pin->hal_priv;
    int half_pin = pin->pin_number / 2;
    if (hal_priv->value[half_pin] != value) {
        hal_priv->value[half_pin] = value;
        maybe_send_notification(env, hal_priv, half_pin * 2);
        maybe_send_notification(env, hal_priv, half_pin * 2 + 1);
    }
    return 0;
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    struct stub_priv *hal_priv = pin->hal_priv;

    hal_priv->mode[pin->pin_number] = pin->config.trigger;
    hal_priv->pid[pin->pin_number] = pin->config.pid;

    maybe_send_notification(env, hal_priv, pin->pin_number);

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

ERL_NIF_TERM hal_enum(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM enum_data)
{
    ERL_NIF_TERM chip_map = enif_make_new_map(env);

    ERL_NIF_TERM chip_label = make_string_binary(env, "stub");
    ERL_NIF_TERM chip_name = make_string_binary(env, "gpiochip0");

    unsigned int j;
    for (j = 0; j < NUM_GPIOS; j++) {
        char line_name[32];
        sprintf(line_name, "pair_%d_%d", j / 2, j % 2);

        ERL_NIF_TERM line_map = enif_make_new_map(env);
        ERL_NIF_TERM line_label = make_string_binary(env, line_name);
        ERL_NIF_TERM line_offset = enif_make_int(env, j);

        enif_make_map_put(env, line_map, atom_label, line_label, &line_map);
        enif_make_map_put(env, line_map, atom_line, line_offset, &line_map);
        enif_make_map_put(env, chip_map, line_offset, line_map, &chip_map);
    }
    enif_make_map_put(env, enum_data, enif_make_tuple3(env, enif_make_int(env, 0), chip_label, chip_name), chip_map, &enum_data);

    return enum_data;
}
