/*
 *  Copyright 2018 Frank Hunleth, Mark Sebald
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "gpio_nif.h"
#include <string.h>

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    (void) hal_priv;

    enif_make_map_put(env, info, enif_make_atom(env, "name"), enif_make_atom(env, "stub"), &info);
    return info;
}

size_t hal_priv_size()
{
    return 0;
}

int hal_load(void *hal_priv)
{
    (void) hal_priv;
    return 0;
}

void hal_unload(void *hal_priv)
{
    (void) hal_priv;
}

int hal_open_gpio(struct gpio_pin *pin,
                  char *error_str)
{
    (void) pin;

    pin->fd = 100;
    *error_str = '\0';
    return 0;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    pin->fd = -1;
}

int hal_read_gpio(struct gpio_pin *pin)
{
    (void) pin;
    return 0;
}

int hal_write_gpio(struct gpio_pin *pin, int value)
{
    (void) pin;
    (void) value;
    return 0;
}

int hal_apply_edge_mode(struct gpio_pin *pin)
{
    (void) pin;
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
