// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs, Connor Rigby
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

#include <sys/ioctl.h>
#include "linux/gpio.h"

#include "hal_cdev_gpio.h"

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

struct gpio_monitor_info {
    enum trigger_mode trigger;
    int fd;
    int offset;
    ErlNifPid pid;
    ERL_NIF_TERM gpio_spec;
};

static void init_listeners(struct gpio_monitor_info *infos)
{
    memset(infos, 0, MAX_GPIO_LISTENERS * sizeof(struct gpio_monitor_info));
}

static void compact_listeners(struct gpio_monitor_info *infos, int count)
{
    int j = -1;
    for (int i = 0; i < count - 1; i++) {
        if (infos[i].trigger == TRIGGER_NONE) {
            if (j >= 0) {
                memcpy(&infos[j], &infos[i], sizeof(struct gpio_monitor_info));
                memset(&infos[i], 0, sizeof(struct gpio_monitor_info));
                j++;
            }
        } else {
            if (j < 0)
                j = i;
        }
    }
}

static uint64_t timestamp_nanoseconds()
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;

    return (uint64_t) ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static int handle_gpio_update(ErlNifEnv *env,
                              struct gpio_monitor_info *info,
                              uint64_t timestamp,
                              int event_id)
{
    debug("handle_gpio_update %d", info->offset);
    int value = event_id == GPIO_V2_LINE_EVENT_RISING_EDGE ? 1 : 0;

    return send_gpio_message(env, info->gpio_spec, &info->pid, timestamp, value);
}

static int force_gpio_update(ErlNifEnv *env,
                             struct gpio_monitor_info *info)
{
    debug("force_gpio_update %d", info->offset);
    int value = get_value_v2(info->fd);
    if (value < 0) {
        error("error reading gpio %d", info->offset);
        info->trigger = TRIGGER_NONE;
        return -1;
    }

    if (info->trigger == TRIGGER_BOTH ||
        (info->trigger == TRIGGER_RISING && value == 1) ||
        (info->trigger == TRIGGER_FALLING && value == 0)) {
        uint64_t timestamp = timestamp_nanoseconds();
        if (!send_gpio_message(env,
                                info->gpio_spec,
                                &info->pid,
                                timestamp,
                                value)) {
            error("send for gpio %d failed, so not listening to it any more", info->offset);
            info->trigger = TRIGGER_NONE;
            return -1;
        }
    }
    return 0;
}

static int process_gpio_events(ErlNifEnv *env,
                               struct gpio_monitor_info *info)
{
    struct gpio_v2_line_event events[16];
    ssize_t amount_read = read(info->fd, events, sizeof(events));
    if (amount_read < 0) {
        error("Unexpected return from reading gpio events: %d, errno=%d", amount_read, errno);
        return -1;
    }

    int num_events = amount_read / sizeof(struct gpio_v2_line_event);
    for (int i = 0; i < num_events; i++) {
        if (!handle_gpio_update(env,
                                info,
                                events[i].timestamp_ns,
                                events[i].id)) {
            error("send for gpio %d failed, so not listening to it any more", info->offset);
            return -1;
        }
    }
    return 0;
}

static void add_listener(ErlNifEnv *env, struct gpio_monitor_info *infos, const struct gpio_monitor_info *to_add)
{
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].trigger == TRIGGER_NONE || infos[i].fd == to_add->fd) {
            memcpy(&infos[i], to_add, sizeof(struct gpio_monitor_info));
            force_gpio_update(env, &infos[i]);
            return;
        }
    }
    error("Too many gpio listeners. Max is %d", MAX_GPIO_LISTENERS);
}

static void remove_listener(struct gpio_monitor_info *infos, int fd)
{
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].trigger == TRIGGER_NONE)
            return;

        if (infos[i].fd == fd) {
            infos[i].trigger = TRIGGER_NONE;
            compact_listeners(infos, MAX_GPIO_LISTENERS);
            return;
        }
    }
}

void *gpio_poller_thread(void *arg)
{
    struct gpio_monitor_info monitor_info[MAX_GPIO_LISTENERS];
    struct pollfd fdset[MAX_GPIO_LISTENERS + 1];
    int *pipefd = arg;
    debug("gpio_poller_thread started");

    ErlNifEnv *env = enif_alloc_env();

    init_listeners(monitor_info);
    for (;;) {
        struct pollfd *fds = &fdset[0];
        nfds_t count = 0;

        struct gpio_monitor_info *info = &monitor_info[0];
        while (info->trigger != TRIGGER_NONE) {
            debug("adding fd %d to poll list", info->fd);
            fds->fd = info->fd;
            fds->events = POLLIN;
            fds->revents = 0;
            fds++;
            info++;
            count++;
        }

        fds->fd = *pipefd;
        fds->events = POLLIN;
        fds->revents = 0;
        count++;

        debug("poll waiting on %d handles", count);
        int rc = poll(fdset, count, -1);
        if (rc < 0) {
            // Retry if EINTR
            if (errno == EINTR)
                continue;

            error("poll failed. errno=%d", errno);
            break;
        }
        debug("poll returned rc=%d", rc);

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

            if (message.trigger != TRIGGER_NONE)
                add_listener(env, monitor_info, &message);
            else
                remove_listener(monitor_info, message.fd);
        }

        bool cleanup = false;
        for (nfds_t i = 0; i < count - 1; i++) {
            if (fdset[i].revents) {
                if (fdset[i].revents) {
                    debug("interrupt on %d", monitor_info[i].offset);
                    if (process_gpio_events(env, &monitor_info[i]) < 0) {
                        monitor_info[i].trigger = TRIGGER_NONE;
                        cleanup = true;
                    }
                } else {
                    error("error listening on gpio %d", monitor_info[i].offset);
                    monitor_info[i].trigger = TRIGGER_NONE;
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
    struct hal_cdev_gpio_priv *priv = (struct hal_cdev_gpio_priv *) pin->hal_priv;

    struct gpio_monitor_info message;
    message.trigger = pin->config.trigger;
    message.fd = pin->fd;
    message.offset = pin->offset;
    message.gpio_spec = pin->gpio_spec;
    message.pid = pin->config.pid;
    if (write(priv->pipe_fds[1], &message, sizeof(message)) != sizeof(message)) {
        error("Error writing polling thread!");
        return -1;
    }
    return 0;
}
