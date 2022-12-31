// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#ifndef HAL_SYSFS_H
#define HAL_SYSFS_H

#include <stdint.h>
#include "erl_nif.h"

struct sysfs_priv {
    ErlNifTid poller_tid;
    int pipe_fds[2];

#ifdef TARGET_RPI
    uint32_t *gpio_mem;
    int gpio_fd;
#endif
};

struct gpio_pin;

int sysfs_read_gpio(int fd);
void *gpio_poller_thread(void *arg);
int update_polling_thread(struct gpio_pin *pin);

#ifdef TARGET_RPI
ERL_NIF_TERM rpi_info(ErlNifEnv *env, struct sysfs_priv *priv, ERL_NIF_TERM info);
int rpi_load(struct sysfs_priv *priv);
void rpi_unload(struct sysfs_priv *priv);
int rpi_apply_pull_mode(struct gpio_pin *pin);
#endif

#endif // HAL_SYSFS_H
