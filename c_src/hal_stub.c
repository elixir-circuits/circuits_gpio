// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"
#include <string.h>

#define NUM_GPIOS 64

/**
 * The stub hardware abstraction layer is suitable for some unit testing.
 * It has 64 GPIOs. GPIO 0 is connected to GPIO 1, 2 to 3, and so on.
 */

struct stub_priv {
    int value[NUM_GPIOS / 2];
    ErlNifPid pid[NUM_GPIOS];
    enum trigger_mode mode[NUM_GPIOS];
};

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    (void) hal_priv;

    enif_make_map_put(env, info, enif_make_atom(env, "name"), enif_make_atom(env, "stub"), &info);
    return info;
}

size_t hal_priv_size()
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
    (void) env;
    // For test purposes, pins 0-63 work and everything else fails
    if (pin->pin_number >= 0 && pin->pin_number < NUM_GPIOS) {
        pin->fd = pin->pin_number;

        if (pin->config.is_output && pin->config.initial_value != -1)
            hal_write_gpio(pin, pin->config.initial_value, env);

        *error_str = '\0';
        return 0;
    } else {
        strcpy(error_str, "no_gpio");
        return -1;
    }
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd >= 0) {
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
        send_gpio_message(env, enif_make_atom(env, "circuits_gpio"), pin_number, &hal_priv->pid[pin_number], now, value);
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
