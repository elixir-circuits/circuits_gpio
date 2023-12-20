// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs, Connor Rigby
//
// SPDX-License-Identifier: Apache-2.0

#ifndef HAL_CDEV_GPIO_H
#define HAL_CDEV_GPIO_H

#include <stdint.h>
#include "erl_nif.h"

struct hal_cdev_gpio_priv {
    ErlNifTid poller_tid;
    int pipe_fds[2];
};

struct gpio_pin;

void *gpio_poller_thread(void *arg);
int update_polling_thread(struct gpio_pin *pin);
int get_value_v2(int fd);
int request_line_v2(int fd, unsigned int offset, uint64_t flags, unsigned int val);

#endif // HAL_CDEV_GPIO_H
