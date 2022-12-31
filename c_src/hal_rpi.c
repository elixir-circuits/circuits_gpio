// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "gpio_nif.h"
#include "hal_sysfs.h"

#ifdef TARGET_RPI
#include <bcm_host.h>

#define GPIO_HELPER_DISABLE_PULLUPS 0
#define GPIO_HELPER_ENABLE_PULLDOWN 1
#define GPIO_HELPER_ENABLE_PULLUP 2

#define GPIO_MAP_BLOCK_SIZE (4*1024)

#define GPPUD_OFFSET        37
#define GPPUDCLK0_OFFSET    38
#define DISABLE_PULLUP_DOWN 0
#define ENABLE_PULLDOWN     1
#define ENABLE_PULLUP       2

/* RPi4 (BCM2711) has a different mechanism for pin pull-up/down/enable  */
#define GPPUPPDN0           57        /* Pin pull-up/down for pins 15:0  */
#define GPPUPPDN1           58        /* Pin pull-up/down for pins 31:16 */
#define GPPUPPDN2           59        /* Pin pull-up/down for pins 47:32 */
#define GPPUPPDN3           60        /* Pin pull-up/down for pins 57:48 */

// RPi4 PULL-UP and PUL-DOWN values are reversed from other RPi models.
#define RPI4_ENABLE_PULLDOWN     2
#define RPI4_ENABLE_PULLUP       1


ERL_NIF_TERM rpi_info(ErlNifEnv *env, struct sysfs_priv *priv, ERL_NIF_TERM info)
{
    enif_make_map_put(env, info, enif_make_atom(env, "rpi_using_gpiomem"), priv->gpio_mem ? enif_make_atom(env, "true") : enif_make_atom(env, "false"), &info);

    return info;
}

int rpi_load(struct sysfs_priv *priv)
{
    // Initialize RPI variables so that other function can know whether this worked.
    priv->gpio_mem = NULL;
    priv->gpio_fd = -1;

    int mem_fd = open("/dev/gpiomem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        error("Couldn't open /dev/gpiomem: %s. GPIO pull modes unavailable. Load gpiomem kernel driver to fix.", strerror(errno));
        return -1;
    }

    void *map = mmap(NULL, GPIO_MAP_BLOCK_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, 0);
    if (*((int32_t*) map) < 0) {
        error("Couldn't mmap /dev/gpiomem");
        close(mem_fd);
        return -1;
    }

    debug("rpi_init_gpio() success");

    priv->gpio_mem = (uint32_t *) map;
    priv->gpio_fd = mem_fd;

    return 0;
}

void rpi_unload(struct sysfs_priv *priv)
{
    if (priv->gpio_fd >= 0) {
        close(priv->gpio_fd);
        priv->gpio_fd = -1;
        priv->gpio_mem = NULL;
    }
}

static uint32_t pull_to_rpi(enum pull_mode pull)
{
    switch (pull) {
    default:
    case PULL_NONE:
        return 0;
    case PULL_DOWN:
        return ENABLE_PULLDOWN;
    case PULL_UP:
        return ENABLE_PULLUP;
    }
}

static uint32_t rpi4_pull_to_rpi(enum pull_mode pull)
{
    switch (pull) {
    default:
    case PULL_NONE:
        return 0;
    case PULL_DOWN:
        return RPI4_ENABLE_PULLDOWN;
    case PULL_UP:
        return RPI4_ENABLE_PULLUP;
    }
}

int rpi_apply_pull_mode(struct gpio_pin *pin)
{
    struct sysfs_priv *priv = pin->hal_priv;
    if (priv->gpio_mem == NULL && rpi_load(priv) != 0)
        return -1;

    int32_t is_rpi4 = (*(priv->gpio_mem + GPPUPPDN3) != 0x6770696f);

    if (is_rpi4) {
        int32_t pullreg = GPPUPPDN0 + (pin->pin_number >> 4);
        int32_t pullshift = (pin->pin_number & 0xf) << 1;

        uint32_t pull = rpi4_pull_to_rpi(pin->config.pull);

        uint32_t pullbits = *(priv->gpio_mem + pullreg);
        pullbits &= ~(3 << pullshift);
        pullbits |= (pull << pullshift);
        *(priv->gpio_mem + pullreg) = pullbits;
    }
    else { // RPi 3, 2, 1, Zero, etc
        uint32_t  clk_bit_to_set = 1 << (pin->pin_number % 32);
        uint32_t *gpio_pud_clk = priv->gpio_mem + GPPUDCLK0_OFFSET + (pin->pin_number / 32);
        uint32_t *gpio_pud = priv->gpio_mem + GPPUD_OFFSET;

        // Steps to connect or disconnect pull up/down resistors on a gpio pin:

        // 1. Write to GPPUD to set the required control signal
        *gpio_pud = (*gpio_pud & ~3) | pull_to_rpi(pin->config.pull);

        // 2. Wait 150 cycles  this provides the required set-up time for the control signal
        usleep(1);

        // 3. Write to GPPUDCLK0/1 to clock the control signal into the GPIO pads you wish to modify
        *gpio_pud_clk = clk_bit_to_set;

        // 4. Wait 150 cycles  this provides the required hold time for the control signal
        usleep(1);

        // 5. Write to GPPUD to remove the control signal
        *gpio_pud &= ~3;

        // 6. Write to GPPUDCLK0/1 to remove the clock
        *gpio_pud_clk = 0;
    }
    return 0;
}
#endif // TARGET_RPI
