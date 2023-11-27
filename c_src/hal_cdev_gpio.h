// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#ifndef HAL_CDEV_GPIO_H
#define HAL_CDEV_GPIO_H

#include <stdint.h>
#include "erl_nif.h"

#include <linux/gpio.h>
#include <errno.h>

struct hal_cdev_gpio_priv {
    ErlNifTid poller_tid;
    int pipe_fds[2];

#ifdef TARGET_RPI
    uint32_t *gpio_mem;
    int gpio_fd;
#endif
};

struct gpio_pin;

typedef struct gpiochip_info gpiochip_info_t;

int hal_gpio_read_gpio(int fd);
void *gpio_poller_thread(void *arg);
int update_polling_thread(struct gpio_pin *pin);

#endif // HAL_CDEV_GPIO_H
