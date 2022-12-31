// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <string.h>

#include <errno.h>
#include <poll.h>
#include <time.h>
#include <stdint.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "hal_sysfs.h"

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

struct gpio_monitor_info {
    int pin_number;
    int fd;
    ErlNifPid pid;
    int last_value;
    enum trigger_mode trigger;
    bool suppress_glitches;
};

static void init_listeners(struct gpio_monitor_info *infos)
{
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++)
        infos[i].fd = -1;
}

static void compact_listeners(struct gpio_monitor_info *infos, int count)
{
    int j = -1;
    for (int i = 0; i < count - 1; i++) {
        if (infos[i].fd >= 0) {
            if (j >= 0) {
                memcpy(&infos[j], &infos[i], sizeof(struct gpio_monitor_info));
                infos[i].fd = -1;
                j++;
            }
        } else {
            if (j < 0)
                j = i;
        }
    }
}

static void add_listener(struct gpio_monitor_info *infos, const struct gpio_monitor_info *to_add)
{
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].fd < 0 || infos[i].pin_number == to_add->pin_number) {
            memcpy(&infos[i], to_add, sizeof(struct gpio_monitor_info));
            return;
        }
    }
    error("Too many gpio listeners. Max is %d", MAX_GPIO_LISTENERS);
}

static void remove_listener(struct gpio_monitor_info *infos, int pin_number)
{
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].fd < 0)
            return;

        if (infos[i].pin_number == pin_number) {
            infos[i].fd = -1;
            compact_listeners(infos, MAX_GPIO_LISTENERS);
            return;
        }
    }
}

static int64_t timestamp_nanoseconds()
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;

    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int handle_gpio_update(ErlNifEnv *env,
                              ERL_NIF_TERM atom_gpio,
                              struct gpio_monitor_info *info,
                              int64_t timestamp,
                              int value)
{
    int rc = 1;
    switch (info->trigger) {
    case TRIGGER_NONE:
        // Shouldn't happen.
        rc = 0;
        break;

    case TRIGGER_RISING:
        if (value || !info->suppress_glitches)
            rc = send_gpio_message(env, atom_gpio, info->pin_number, &info->pid, timestamp, 1);
        break;

    case TRIGGER_FALLING:
        if (!value || !info->suppress_glitches)
            rc = send_gpio_message(env, atom_gpio, info->pin_number, &info->pid, timestamp, 0);
        break;

    case TRIGGER_BOTH:
        if (value != info->last_value) {
            rc = send_gpio_message(env, atom_gpio, info->pin_number, &info->pid, timestamp, value);
            info->last_value = value;
        } else if (!info->suppress_glitches) {
            // Send two messages so that the user sees an instantaneous transition
            send_gpio_message(env, atom_gpio, info->pin_number, &info->pid, timestamp, value ? 0 : 1);
            rc = send_gpio_message(env, atom_gpio, info->pin_number, &info->pid, timestamp, value);
        }
        break;
    }
    return rc;
}

void *gpio_poller_thread(void *arg)
{
    struct gpio_monitor_info monitor_info[MAX_GPIO_LISTENERS];
    struct pollfd fdset[MAX_GPIO_LISTENERS + 1];
    int *pipefd = arg;
    debug("gpio_poller_thread started");

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM atom_gpio = enif_make_atom(env, "circuits_gpio");

    init_listeners(monitor_info);
    for (;;) {
        struct pollfd *fds = &fdset[0];
        nfds_t count = 0;

        struct gpio_monitor_info *info = monitor_info;
        while (info->fd >= 0) {
            fds->fd = info->fd;
            fds->events = POLLPRI;
            fds->revents = 0;
            fds++;
            info++;
            count++;
        }

        fds->fd = *pipefd;
        fds->events = POLLIN;
        fds->revents = 0;
        count++;

        int rc = poll(fdset, count, -1);
        if (rc < 0) {
            // Retry if EINTR
            if (errno == EINTR)
                continue;

            error("poll failed. errno=%d", errno);
            break;
        }

        int64_t timestamp = timestamp_nanoseconds();
        // enif_monotonic_time only works in scheduler threads
        //ErlNifTime timestamp = enif_monotonic_time(ERL_NIF_NSEC);

        short revents = fdset[count - 1].revents;
        if (revents & (POLLERR | POLLNVAL)) {
            // Socket closed so quit thread. This happens on NIF unload.
            break;
        }
        if (revents & (POLLIN | POLLHUP)) {
            struct gpio_monitor_info message;
            ssize_t amount_read = read(*pipefd, &message, sizeof(message));
            if (amount_read != sizeof(message)) {
                error("Unexpected return from read: %d, errno=%d", amount_read, errno);
                break;
            }

            if (message.fd >= 0)
                add_listener(monitor_info, &message);
            else
                remove_listener(monitor_info, message.pin_number);
        }

        bool cleanup = false;
        for (nfds_t i = 0; i < count - 1; i++) {
            if (fdset[i].revents) {
                if (fdset[i].revents & POLLPRI) {
                    int value = sysfs_read_gpio(fdset[i].fd);
                    if (value < 0) {
                        error("error reading gpio %d", monitor_info[i].pin_number);
                        monitor_info[i].fd = -1;
                        cleanup = true;
                    } else {
                        if (!handle_gpio_update(env,
                                                atom_gpio,
                                                &monitor_info[i],
                                                timestamp,
                                                value)) {
                            error("send for gpio %d failed, so not listening to it any more", monitor_info[i].pin_number);
                            monitor_info[i].fd = -1;
                            cleanup = true;
                        }
                    }
                } else {
                    error("error listening on gpio %d", monitor_info[i].pin_number);
                    monitor_info[i].fd = -1;
                    cleanup = true;
                }
            }
        }

        if (cleanup) {
            // Compact the listener list
            compact_listeners(monitor_info, count);
        }
    }

    enif_free_env(env);
    debug("gpio_poller_thread ended");
    return NULL;
}

int update_polling_thread(struct gpio_pin *pin)
{
    struct sysfs_priv *priv = (struct sysfs_priv *) pin->hal_priv;

    struct gpio_monitor_info message;
    message.pin_number = pin->pin_number;
    message.fd = (pin->config.trigger == TRIGGER_NONE) ? -1 : pin->fd;
    message.pid = pin->config.pid;
    message.last_value = -1;
    message.trigger = pin->config.trigger;
    message.suppress_glitches = pin->config.suppress_glitches;
    if (write(priv->pipe_fds[1], &message, sizeof(message)) != sizeof(message)) {
        error("Error writing polling thread!");
        return -1;
    }
    return 0;
}
