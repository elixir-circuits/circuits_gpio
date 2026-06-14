// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2019 Matt Ludwigs
// SPDX-FileCopyrightText: 2023 Connor Rigby
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
    enum trigger_mode emit_trigger;
    int fd;
    int num_lines;
    int offsets[GPIO_MAX_LINES];
    uint64_t shadow;
    bool notify_map;
    ErlNifEnv *env;
    ErlNifPid pid;
    ERL_NIF_TERM gpio_spec;
    ERL_NIF_TERM notify_id;
};

static void init_listeners(struct gpio_monitor_info *infos)
{
    memset(infos, 0, MAX_GPIO_LISTENERS * sizeof(struct gpio_monitor_info));
}

static void clear_listener(struct gpio_monitor_info *info)
{
    if (info->env) {
        enif_free_env(info->env);
        info->env = NULL;
    }

    memset(info, 0, sizeof(struct gpio_monitor_info));
}

static void compact_listeners(struct gpio_monitor_info *infos)
{
    int write_pos = 0;
    int read_pos;
    for (read_pos = 0; read_pos < MAX_GPIO_LISTENERS; read_pos++) {
        if (infos[read_pos].trigger != TRIGGER_NONE) {
            if (write_pos != read_pos) {
                memcpy(&infos[write_pos], &infos[read_pos], sizeof(struct gpio_monitor_info));
            }
            write_pos++;
        }
    }
    int remaining = MAX_GPIO_LISTENERS - write_pos;
    memset(&infos[write_pos], 0, remaining * sizeof(struct gpio_monitor_info));
}

static int handle_gpio_update(ErlNifEnv *msg_env,
                              struct gpio_monitor_info *info,
                              uint64_t timestamp,
                              int event_id,
                              unsigned int offset)
{
    debug("handle_gpio_update offset %u", offset);

    // Map the changed line's offset to its bit position in the group.
    int changed_bit = -1;
    for (int i = 0; i < info->num_lines; i++) {
        if ((unsigned int) info->offsets[i] == offset) {
            changed_bit = i;
            break;
        }
    }
    if (changed_bit < 0)
        return 0;

    // Update the shadow value from the edge direction. The hardware tracks both
    // edges so the aggregate stays accurate; emit_trigger decides what's sent.
    uint64_t previous = info->shadow;
    uint64_t new_value = previous;
    if (event_id == GPIO_V2_LINE_EVENT_RISING_EDGE)
        new_value |= ((uint64_t) 1 << changed_bit);
    else
        new_value &= ~((uint64_t) 1 << changed_bit);
    info->shadow = new_value;

    ERL_NIF_TERM notify_term = info->notify_map ? info->notify_id : info->gpio_spec;

    // Convert true/false return to the typical 0/negative returns of this file
    if (emit_gpio_change(NULL, msg_env, info->notify_map, notify_term, &info->pid,
                         info->emit_trigger, (int64_t) timestamp, new_value, previous, changed_bit))
        return 0;
    else
        return -1;
}

static int process_gpio_events(ErlNifEnv *msg_env,
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
        if (handle_gpio_update(msg_env,
                               info,
                               events[i].timestamp_ns,
                               events[i].id,
                               events[i].offset) < 0) {
            error("send for gpio fd %d failed, so not listening to it any more", info->fd);
            return -1;
        }
    }
    return 0;
}

static void add_listener(struct gpio_monitor_info *infos, const struct gpio_monitor_info *to_add)
{
    // The message owns its term environment (see update_polling_thread). Taking
    // the message by value transfers that ownership to the listener slot, so the
    // poller never dereferences the pin's environment.
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].trigger == TRIGGER_NONE || infos[i].fd == to_add->fd) {
            clear_listener(&infos[i]);
            infos[i] = *to_add;
            return;
        }
    }
    error("Too many gpio listeners. Max is %d", MAX_GPIO_LISTENERS);

    // No slot available, so free the environment that would have been adopted.
    if (to_add->env)
        enif_free_env(to_add->env);
}

static void remove_listener(struct gpio_monitor_info *infos, int fd)
{
    debug("remove_listener fd=%d", fd);
    bool cleanup = false;
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (infos[i].fd == fd) {
            clear_listener(&infos[i]);
            cleanup = true;
        }
    }
    if (cleanup)
        compact_listeners(infos);
}

void *gpio_poller_thread(void *arg)
{
    struct gpio_monitor_info monitor_info[MAX_GPIO_LISTENERS];
    struct pollfd fdset[MAX_GPIO_LISTENERS + 1];
    int *pipefd = arg;
    debug("gpio_poller_thread started");

    // Environment for building messages. It's cleared after each send so it
    // can be allocated once and reused for the life of the thread.
    ErlNifEnv *msg_env = enif_alloc_env();

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

        bool cleanup = false;
        for (nfds_t i = 0; i < count - 1; i++) {
            short gpio_revents = fdset[i].revents;
            if (gpio_revents & POLLIN) {
                if (process_gpio_events(msg_env, &monitor_info[i]) < 0) {
                    error("error processing gpio events for fd %d", monitor_info[i].fd);
                    clear_listener(&monitor_info[i]);
                    cleanup = true;
                }
            } else if (gpio_revents & (POLLERR | POLLHUP | POLLNVAL)) {
                error("error listening on gpio fd %d", monitor_info[i].fd);
                clear_listener(&monitor_info[i]);
                cleanup = true;
            }
        }

        if (revents & (POLLIN | POLLHUP)) {
            struct gpio_monitor_info message;
            ssize_t amount_read = read(*pipefd, &message, sizeof(message));
            if (amount_read != sizeof(message)) {
                error("Unexpected return from read: %d, errno=%d", amount_read, errno);
                break;
            }

            if (message.trigger != TRIGGER_NONE)
                add_listener(monitor_info, &message);
            else
                remove_listener(monitor_info, message.fd);
        }

        // Compact the listener list if any failed
        if (cleanup)
            compact_listeners(monitor_info);
    }

    for (int i = 0; i < MAX_GPIO_LISTENERS; i++)
        clear_listener(&monitor_info[i]);

    enif_free_env(msg_env);
    debug("gpio_poller_thread ended");
    return NULL;
}

int update_polling_thread(struct gpio_pin *pin)
{
    struct hal_cdev_gpio_priv *priv = (struct hal_cdev_gpio_priv *) pin->hal_priv;

    struct gpio_monitor_info message;
    memset(&message, 0, sizeof(message));
    message.trigger = pin->config.trigger;
    message.emit_trigger = pin->config.emit_trigger;
    message.fd = pin->fd;
    message.num_lines = pin->num_lines;
    memcpy(message.offsets, pin->offsets, sizeof(int) * pin->num_lines);
    message.shadow = pin->shadow;
    message.notify_map = pin->notify_map;
    message.pid = pin->config.pid;

    // For an active subscription, copy the term the poller will echo into an
    // environment owned by the message. This happens on the caller's thread
    // while pin->env is valid, so the poller never has to dereference pin->env
    // (which this thread may clear on re-subscribe or free on close).
    if (pin->config.trigger != TRIGGER_NONE) {
        message.env = enif_alloc_env();
        if (pin->notify_map)
            message.notify_id = enif_make_copy(message.env, pin->notify_id);
        else
            message.gpio_spec = enif_make_copy(message.env, pin->gpio_spec);
    }

    if (write(priv->pipe_fds[1], &message, sizeof(message)) != sizeof(message)) {
        error("Error writing polling thread!");
        if (message.env)
            enif_free_env(message.env);
        return -EIO;
    }
    return 0;
}
