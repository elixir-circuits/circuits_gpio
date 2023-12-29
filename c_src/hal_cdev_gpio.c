// SPDX-FileCopyrightText: 2023 Frank Hunleth, Connor Rigby
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <string.h>

#include <stdint.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include <sys/ioctl.h>
#include "linux/gpio.h"

#include "hal_cdev_gpio.h"

#define CONSUMER "circuits_gpio"

int get_value_v2(int fd)
{
    struct gpio_v2_line_values vals;
    memset(&vals, 0, sizeof(vals));
    vals.mask = 1;

    if (ioctl(fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &vals) < 0) {
        debug("GPIO_V2_LINE_GET_VALUES_IOCTL failed");
        return -errno;
    }

    return vals.bits & 0x1;
}

static int set_value_v2(int fd, int value)
{
    struct gpio_v2_line_values vals;
    vals.bits = value;
    vals.mask = 1;

    if (ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals) < 0) {
        debug("GPIO_V2_LINE_GET_VALUES_IOCTL failed");
        return -errno;
    }

    return 0;
}

static int set_config_v2(int fd, uint64_t flags)
{
    struct gpio_v2_line_config config;
    memset(&config, 0, sizeof(config));

    config.flags = flags;
    if (ioctl(fd, GPIO_V2_LINE_SET_CONFIG_IOCTL, &config) < 0) {
        debug("GPIO_V2_LINE_SET_CONFIG_IOCTL failed");
        return -errno;
    }

    return 0;
}

static int request_line_v2(int fd, unsigned int offset, uint64_t flags, int val)
{
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof(req));

    req.num_lines = 1;
    req.offsets[0] = offset;
    req.config.flags = flags;
    strcpy(req.consumer, CONSUMER);
    if (flags & GPIO_V2_LINE_FLAG_OUTPUT) {
        if (val >= 0) {
            debug("Initializing %d's value to %d on open", offset, val);
            req.config.num_attrs = 1;
            req.config.attrs[0].mask = 1;
            req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
            req.config.attrs[0].attr.values = (unsigned int) val;
        } else {
            debug("Not initializing %d's value on open", offset);
        }
    }

    if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
        debug("GPIO_V2_GET_LINE_IOCTL failed");
        return -errno;
    }
    return req.fd;
}

size_t hal_priv_size()
{
    return sizeof(struct hal_cdev_gpio_priv);
}

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    enif_make_map_put(env, info, atom_name, enif_make_atom(env, "cdev"), &info);
    (void) hal_priv;
    return info;
}

int hal_load(void *hal_priv)
{
    struct hal_cdev_gpio_priv *priv = hal_priv;
    memset(priv, 0, sizeof(struct hal_cdev_gpio_priv));

    if (pipe(priv->pipe_fds) < 0) {
        error("pipe failed");
        return 1;
    }

    if (enif_thread_create("gpio_poller", &priv->poller_tid, gpio_poller_thread, &priv->pipe_fds[0], NULL) != 0) {
        error("enif_thread_create failed");
        return 1;
    }
    return 0;
}

void hal_unload(void *hal_priv)
{
    debug("hal_unload");
    struct hal_cdev_gpio_priv *priv = hal_priv;

    // Close everything related to the listening thread so that it exits
    close(priv->pipe_fds[0]);
    close(priv->pipe_fds[1]);
    // If the listener thread hasn't exited already, it should do so soon.
    enif_thread_join(priv->poller_tid, NULL);
}

int hal_open_gpio(struct gpio_pin *pin,
                  char *error_str,
                  ErlNifEnv *env)
{
    int gpiochip_fd = open(pin->gpiochip, O_RDWR|O_CLOEXEC);
    if (gpiochip_fd < 0) {
        strcpy(error_str, "open_failed");
        return -1;
    }
    int value = 0;
    uint64_t flags = 0;
    if (pin->config.is_output) {
        flags &= ~GPIO_V2_LINE_FLAG_INPUT;
        flags |= GPIO_V2_LINE_FLAG_OUTPUT;
        value = pin->config.initial_value;
    } else {
        flags = GPIO_V2_LINE_FLAG_INPUT;
        value = 0;
    }

    if (pin->config.pull == PULL_UP) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    } else if (pin->config.pull == PULL_DOWN) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
    } else {
        flags |= GPIO_V2_LINE_FLAG_BIAS_DISABLED;
    }

    pin->fd = request_line_v2(gpiochip_fd, pin->offset, flags, value);
    close(gpiochip_fd);
    debug("requesting pin %s:%d -> %d, errno=%d", pin->gpiochip, pin->offset, pin->fd, errno);
    if(pin->fd < 0) {
        strcpy(error_str, "invalid_pin");
        return -1;
    }

    // Only call hal_apply_interrupts if there's a trigger
    if (pin->config.trigger != TRIGGER_NONE && hal_apply_interrupts(pin, env) < 0) {
        strcpy(error_str, "error_setting_interrupts");
        close(pin->fd);
        return -1;
    }

    *error_str = '\0';
    return 0;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    debug("hal_close_gpio %s:%d", pin->gpiochip, pin->offset);
    if (pin->fd >= 0) {
        // Turn off interrupts if they're on.
        if (pin->config.trigger != TRIGGER_NONE) {
            pin->config.trigger = TRIGGER_NONE;
            update_polling_thread(pin);
        }
        close(pin->fd);
    }
}

int hal_read_gpio(struct gpio_pin *pin)
{
    debug("hal_read_gpio %s:%d", pin->gpiochip, pin->offset);
    return get_value_v2(pin->fd);
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    (void) env;
    debug("hal_write_gpio %s:%d -> %d", pin->gpiochip, pin->offset, value);
    return set_value_v2(pin->fd, value);
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    (void) env;
    debug("hal_apply_interrupts %s:%d", pin->gpiochip, pin->offset);
    // Update the configuration and start or stop polling
    if (hal_apply_direction(pin) < 0 ||
        update_polling_thread(pin) < 0)
        return -1;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    debug("hal_apply_direction %s:%d", pin->gpiochip, pin->offset);
    uint64_t flags = 0;
    if (pin->config.is_output) {
        flags = GPIO_V2_LINE_FLAG_OUTPUT;
    } else {
        flags = GPIO_V2_LINE_FLAG_INPUT;
    }

    if (pin->config.pull == PULL_UP) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    } else if (pin->config.pull == PULL_DOWN) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
    } else {
        flags |= GPIO_V2_LINE_FLAG_BIAS_DISABLED;
    }

    switch (pin->config.trigger) {
    case TRIGGER_RISING:
        flags |= GPIO_V2_LINE_FLAG_EDGE_RISING;
        break;
    case TRIGGER_FALLING:
        flags |= GPIO_V2_LINE_FLAG_EDGE_FALLING;
        break;
    case TRIGGER_BOTH:
        flags |= GPIO_V2_LINE_FLAG_EDGE_RISING | GPIO_V2_LINE_FLAG_EDGE_FALLING;
        break;
    case TRIGGER_NONE:
    default:
        break;
    }

    return set_config_v2(pin->fd, flags);
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    debug("hal_apply_pull_mode %s:%d", pin->gpiochip, pin->offset);
    if (pin->config.pull == PULL_NOT_SET)
        return 0;

    // Exact same handling as applying the direction now.
    return hal_apply_direction(pin);
}

ERL_NIF_TERM hal_enumerate(ErlNifEnv *env, void *hal_priv)
{
    int i;

    ERL_NIF_TERM gpio_list = enif_make_list(env, 0);
    for (i = 15; i >= 0; i--) {
        char path[32];
        sprintf(path, "/dev/gpiochip%d", i);

        int fd = open(path, O_RDONLY|O_CLOEXEC);
        if (fd < 0)
            continue;

        struct gpiochip_info info;
        memset(&info, 0, sizeof(struct gpiochip_info));
        if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &info) < 0)
            continue;

        ERL_NIF_TERM chip_label = make_string_binary(env, info.label);
        ERL_NIF_TERM chip_name = make_string_binary(env, info.name);

        int j;
        for (j = info.lines - 1; j >= 0; j--) {
            struct gpio_v2_line_info line;
            memset(&line, 0, sizeof(struct gpio_v2_line_info));
            line.offset = j;
            if (ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &line) >= 0) {
                ERL_NIF_TERM line_map = enif_make_new_map(env);
                ERL_NIF_TERM line_offset = enif_make_int(env, j);
                ERL_NIF_TERM line_label = line.name[0] == '\0' ? line_offset : make_string_binary(env, line.name);

                enif_make_map_put(env, line_map, atom_struct, atom_circuits_gpio_line, &line_map);
                enif_make_map_put(env, line_map, atom_controller, chip_name, &line_map);
                enif_make_map_put(env, line_map, atom_label, enif_make_tuple2(env, chip_label, line_label), &line_map);
                enif_make_map_put(env, line_map, atom_gpio_spec, enif_make_tuple2(env, chip_name, line_offset), &line_map);

                gpio_list = enif_make_list_cell(env, line_map, gpio_list);
            }
        }
        close(fd);
    }
    return gpio_list;
}
