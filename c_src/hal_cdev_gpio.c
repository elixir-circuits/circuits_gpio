// SPDX-FileCopyrightText: 2023 Connor Rigby, Frank Hunleth
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

#define CONSUMER	"circuits_gpio"

typedef struct gpiochip_info gpiochip_info_t;

size_t hal_priv_size()
{
    return sizeof(struct hal_cdev_gpio_priv);
}

int gpio_get_chipinfo_ioctl(int fd, gpiochip_info_t* info) {
    return ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, info);
}

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

int request_line_v2(int fd, unsigned int offset,
                    uint64_t flags, unsigned int val)
{
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof(req));

    req.num_lines = 1;
    req.offsets[0] = offset;
    req.config.flags = flags;
    strcpy(req.consumer, CONSUMER);
    if (flags & GPIO_V2_LINE_FLAG_OUTPUT) {
        req.config.num_attrs = 1;
        req.config.attrs[0].mask = 1;
        req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
        if (val)
            req.config.attrs[0].attr.values = 1;
    }

    if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
        debug("GPIO_V2_GET_LINE_IOCTL failed");
        return -errno;
    }
    return req.fd;
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
    gpiochip_info_t info;
    memset(&info, 0, sizeof(gpiochip_info_t));

    pin->fd = open(pin->gpiochip, O_RDWR|O_CLOEXEC);
    debug("pin->fd = %d", pin->fd);

    if (pin->fd < 0) {
        strcpy(error_str, "open_failed");
        goto error;
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

    if(gpio_get_chipinfo_ioctl(pin->fd, &info)) {
        strcpy(error_str, "get_chipinfo_failed");
        close(pin->fd);
        return -1;
    }
    int lfd = request_line_v2(pin->fd, pin->pin_number, flags, value);
    if(lfd < 0) {
        strcpy(error_str, "invalid_pin");
        goto error;
    }
    close(lfd);

    // Only call hal_apply_interrupts if there's a trigger
    if (pin->config.trigger != TRIGGER_NONE && hal_apply_interrupts(pin, env) < 0) {
        strcpy(error_str, "error_setting_interrupts");
        goto error;
    }

    *error_str = '\0';
    return 0;

error:
    close(pin->fd);
    return -1;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    debug("hal_close_gpio");
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
    debug("hal_read_gpio");
    uint64_t flags = GPIO_V2_LINE_FLAG_INPUT;
    debug("request_line_v2 %d %d", pin->fd, pin->pin_number);
    int lfd = request_line_v2(pin->fd, pin->pin_number, flags, 0);
    if (lfd < 0)
        return lfd;

    debug("get_value_v2(%d)", lfd);
    int value = get_value_v2(lfd);
    close(lfd);
    return value;
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    (void) env;
    uint64_t flags = GPIO_V2_LINE_FLAG_OUTPUT;
    int lfd = request_line_v2(pin->fd, pin->pin_number, flags, value);
    close(lfd);

    if(lfd < 0) return lfd;
    return 0;
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    (void) env;
    // Tell polling thread to wait for notifications
    if (update_polling_thread(pin) < 0) return -1;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
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

    int lfd = request_line_v2(pin->fd, pin->pin_number, flags, value);
    close(lfd);

    if(lfd < 0) return lfd;
    return 0;
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    if (pin->config.pull == PULL_NOT_SET)
        return 0;

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

    int lfd = request_line_v2(pin->fd, pin->pin_number, flags, value);
    close(lfd);

    if(lfd < 0) return lfd;
    return 0;
}

ERL_NIF_TERM hal_enum(ErlNifEnv *env, void *hal_priv)
{
    int i;

    ERL_NIF_TERM gpio_list = enif_make_list(env, 0);
    for (i = 15; i >= 0; i--) {
        char path[32];
        sprintf(path, "/dev/gpiochip%d", i);

        int fd = open(path, O_RDONLY|O_CLOEXEC);
        if (fd < 0) {
            debug("could not open gpiochip %d %s", errno, strerror(errno));
            break;
        }

        struct gpiochip_info info;
        memset(&info, 0, sizeof(struct gpiochip_info));
        if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &info) < 0)
            break;

        ERL_NIF_TERM chip_label = make_string_binary(env, info.label);
        ERL_NIF_TERM chip_name = make_string_binary(env, info.name);

        int j;
        for (j = info.lines - 1; j >= 0; j--) {
            struct gpio_v2_line_info line;
            memset(&line, 0, sizeof(struct gpio_v2_line_info));
            line.offset = j;
            if (ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &line) >= 0) {
                debug("  {:cdev, \"%s\", %d} -> {\"%s\", \"%s\"}", info.name, j, info.label, line.name);
                ERL_NIF_TERM line_map = enif_make_new_map(env);
                ERL_NIF_TERM line_label = make_string_binary(env, line.name);
                ERL_NIF_TERM line_offset = enif_make_int(env, j);

                enif_make_map_put(env, line_map, atom_struct, atom_circuits_gpio_line, &line_map);
                enif_make_map_put(env, line_map, atom_struct, atom_circuits_gpio_line, &line_map);
                enif_make_map_put(env, line_map, atom_label, enif_make_tuple2(env, chip_label, line_label), &line_map);
                enif_make_map_put(env, line_map, atom_line_spec, enif_make_tuple2(env, chip_name, line_offset), &line_map);
                gpio_list = enif_make_list_cell(env, line_map, gpio_list);
            }
        }
        close(fd);
    }
    return gpio_list;
}
