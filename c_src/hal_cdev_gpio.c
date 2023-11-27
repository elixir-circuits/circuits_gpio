// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <string.h>

#include <stdint.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "hal_cdev_gpio.h"

size_t hal_priv_size()
{
    return sizeof(struct hal_cdev_gpio_priv);
}

static int gpio_get_chipinfo_ioctl(int fd, gpiochip_info_t* info) {
    return ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, info);
}

static int get_value_v2(int fd)
{
	struct gpio_v2_line_values vals;
	int ret;

	memset(&vals, 0, sizeof(vals));
	vals.mask = 1;
	ret = ioctl(fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &vals);
	if (ret == -1)
		return -errno;
	return vals.bits & 0x1;
}

static int request_line_v2(int fd, unsigned int offset,
			   uint64_t flags, unsigned int val)
{
	struct gpio_v2_line_request req;
	int ret;

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
	ret = ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req);
	if (ret == -1)
		return -errno;
	return req.fd;
}

static const char *edge_mode_string(enum trigger_mode mode)
{
    switch (mode) {
    default:
    case TRIGGER_NONE:
        return "none";
    case TRIGGER_FALLING:
        return "falling";
    case TRIGGER_RISING:
        return "rising";
    case TRIGGER_BOTH:
        return "both";
    }
}

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    enif_make_map_put(env, info, enif_make_atom(env, "name"), enif_make_atom(env, "cdev_gpio"), &info);
    (void) hal_priv;
    return info;
}

int hal_load(void *hal_priv)
{
    struct hal_gpio_priv *priv = hal_priv;
    memset(priv, 0, sizeof(struct hal_gpio_priv));

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
    struct hal_gpio_priv *priv = hal_priv;

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
    *error_str = '\0';

    gpiochip_info_t info
    memset(&info, 0, sizeof(gpiochip_info_t));

    char gpiochip_path[64];
    sprintf(gpiochip_path, "/dev/gpiochip%d", pin->gpiochip_number);
    pin->fd = open(path, O_RDWR|O_CLOEXEC);

    if (pin->fd < 0) {
        strcpy(error_str, "open_failed");
        goto error;
    }
    int value = 0;
    uint64_t flags;
    if (pin->config.is_output) {
        flags &= ~GPIO_V2_LINE_FLAG_INPUT;
        flags |= GPIO_V2_LINE_FLAG_OUTPUT;
        value = pin->config.initial_value;
    } else {
        flags = GPIO_V2_LINE_FLAG_INPUT;
        value = 0;
    }

    if (pin->config.pull_mode == PULL_UP) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    } else if (pin->config.pull_mode == PULL_DOWN) {
        flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
    } else {
        flags |= GPIO_V2_LINE_FLAG_BIAS_DISABLED;
    }

    if(get_chipinfo_ioctl(pin->fd, &info)) {
        strcpy(error_str, "get_chipinfo_failed");
        close(pin->fd);
        return -1;
    }
    int lfd = request_line_v2(cfd, pin->pin_number, flags, value);
    if(lfd < 0) {
        strcpy(error_str, "request_line_v2_failed");
        goto error;
    }
    close(lfd);

    // Only call hal_apply_interrupts if there's a trigger
    // if (pin->config.trigger != TRIGGER_NONE && hal_apply_interrupts(pin, env) < 0) {
    //     strcpy(error_str, "error_setting_interrupts");
    //     goto error;
    // }

    return 0;

error:
    close(pin->fd);
    close(pin->gpioline_fd);
    return -1;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd >= 0 && pin->gpioline_fd >= 0) {
        // Turn off interrupts if they're on.
        if (pin->config.trigger != TRIGGER_NONE) {
            pin->config.trigger = TRIGGER_NONE;
            update_polling_thread(pin);
        }
        close(pin->fd);
        close(pin->fd);
    }
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    (void) env;

    int value = 0;
    uint64_t flags;
    flags &= ~GPIO_V2_LINE_FLAG_INPUT;
    flags |= GPIO_V2_LINE_FLAG_OUTPUT;
    int lfd = request_line_v2(cfd, pin->pin_number, flags, value);
    close(lfd);

    if(lfd < 0) return lfd;
    return 0;
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    (void) env;
    #error "implement me"
    // Tell polling thread to wait for notifications
    if (update_polling_thread(pin) < 0)
        return -1;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    char direction_path[64];
    sprintf(direction_path, "/sys/class/gpio/gpio%d/direction", pin->pin_number);

    /* Allow 1000 * 1ms = 1 second max for retries. See hal_apply_interrupts too. */
    char current_dir[16];
    if (sysfs_read_file(direction_path, current_dir, sizeof(current_dir), 1000) < 0)
        return -1;

    /* Linux only reports "in" and "out". (current_dir is NOT null terminated here) */
    int current_is_output = (current_dir[0] == 'o');

    if (pin->config.is_output == 0) {
        // Input
        return sysfs_write_file(direction_path, "in", 0);
    } else {
        // Output
        if (pin->config.initial_value < 0) {
            // Output, don't set
            if (current_is_output)
                return 0;
            else
                return sysfs_write_file(direction_path, "out", 0);
        } else if (pin->config.initial_value == 0) {
            // Set as output and initialize low
            return sysfs_write_file(direction_path, "low", 0);
        } else {
            // Set as output and initialize high
            return sysfs_write_file(direction_path, "high", 0);
        }
    }
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    if (pin->config.pull == PULL_NOT_SET)
        return 0;

    #error "complete me"

    return rc;
}
