#include "gpio_nif.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

struct gpio_monitor_info {
    int pin_number;
    int fd;
    ErlNifPid pid;
    int last_value;
    enum edge_mode mode;
    bool suppress_glitches;
};

static void gpio_pin_dtor(ErlNifEnv *env, void *obj)
{
    struct gpio_pin *pin = (struct gpio_pin*) obj;
    debug("gpio_pin_dtor called on pin=%d", pin->pin_number);

    close(pin->fd);
    pin->fd = -1;
}

static void gpio_pin_stop(ErlNifEnv *env, void *obj, int fd, int is_direct_call)
{
    //struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin = (struct gpio_pin*) obj;

    debug("gpio_pin_stop called %s, pin=%d", (is_direct_call ? "DIRECT" : "LATER"), pin->pin_number);
}

static void gpio_pin_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *monitor)
{
    struct gpio_pin *pin = (struct gpio_pin*) obj;
    debug("gpio_pin_down called on pin=%d", pin->pin_number);
}

static ErlNifResourceTypeInit gpio_pin_init = {gpio_pin_dtor, gpio_pin_stop, gpio_pin_down};

static int sysfs_read_gpio(int fd)
{
    char buf;
    ssize_t amount_read = pread(fd, &buf, sizeof(buf), 0);
    if (amount_read == sizeof(buf))
        return buf == '1';
    else
        return -1;
}

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

static int send_gpio_message(ErlNifEnv *env,
                             ERL_NIF_TERM atom_gpio,
                             struct gpio_monitor_info *info,
                             int64_t timestamp,
                             int value)
{
    ERL_NIF_TERM msg = enif_make_tuple4(env,
                                        atom_gpio,
                                        enif_make_int(env, info->pin_number),
                                        enif_make_int64(env, timestamp),
                                        enif_make_int(env, value));

    return enif_send(env, &info->pid, NULL, msg);
}

static int handle_gpio_update(ErlNifEnv *env,
                              ERL_NIF_TERM atom_gpio,
                              struct gpio_monitor_info *info,
                              int64_t timestamp,
                              int value)
{
    int rc = 1;
    switch (info->mode) {
    default:
    case EDGE_NONE:
        // Shouldn't happen.
        rc = 0;
        break;

    case EDGE_RISING:
        if (value || !info->suppress_glitches)
            rc = send_gpio_message(env, atom_gpio, info, timestamp, 1);
        break;

    case EDGE_FALLING:
        if (!value || !info->suppress_glitches)
            rc = send_gpio_message(env, atom_gpio, info, timestamp, 0);
        break;

    case EDGE_BOTH:
        if (value != info->last_value) {
            rc = send_gpio_message(env, atom_gpio, info, timestamp, value);
            info->last_value = value;
        } else if (!info->suppress_glitches) {
            // Send two messages so that the user sees an instantaneous transition
            send_gpio_message(env, atom_gpio, info, timestamp, value ? 0 : 1);
            rc = send_gpio_message(env, atom_gpio, info, timestamp, value);
        }
        break;
    }
    return rc;
}

static void *gpio_poller_thread(void *arg)
{
    struct gpio_monitor_info monitor_info[MAX_GPIO_LISTENERS];
    struct pollfd fdset[MAX_GPIO_LISTENERS + 1];
    int *pipefd = arg;
    debug("gpio_poller_thread started");

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM atom_gpio = enif_make_atom(env, "gpio");

    init_listeners(monitor_info);
    for (;;) {
        struct pollfd *fds = &fdset[0];
        int count = 0;

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

            error("poll failed. errno=%d", rc);
            break;
        }

        int64_t timestamp = timestamp_nanoseconds();
        // enif_monotonic_time only works in scheduler threads
        //ErlNifTime timestamp = enif_monotonic_time(ERL_NIF_NSEC);

        if (fdset[count - 1].revents & (POLLIN | POLLHUP)) {
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
        for (int i = 0; i < count - 1; i++) {
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

static int send_polling_thread(int pipefd, struct gpio_pin *pin, enum edge_mode mode, ErlNifPid pid)
{
    struct gpio_monitor_info message;
    message.pin_number = pin->pin_number;
    message.fd = (mode == EDGE_NONE) ? -1 : pin->fd;
    message.pid = pid;
    message.last_value = -1;
    message.mode = mode;
    if (write(pipefd, &message, sizeof(message)) != sizeof(message)) {
        error("Error writing polling thread!");
        return -1;
    }
    return 0;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM info)
{
#ifdef DEBUG
#ifdef LOG_PATH
    log_location = fopen(LOG_PATH, "w");
#endif
#endif
    debug("load");

    struct gpio_priv *priv = enif_alloc(sizeof(struct gpio_priv));
    if (!priv) {
        error("Can't allocate gpio_priv");
        return 1;
    }

    priv->atom_ok = enif_make_atom(env, "ok");

    priv->gpio_pin_rt = enif_open_resource_type_x(env, "gpio_pin", &gpio_pin_init, ERL_NIF_RT_CREATE, NULL);

    if (pipe(priv->pipe_fds) < 0) {
        error("pipe failed");
        return 1;
    }

    if (enif_thread_create("gpio_poller", &priv->poller_tid, gpio_poller_thread, &priv->pipe_fds[0], NULL) != 0) {
        error("enif_thread_create failed");
        return 1;
    }

    // TODO: get_gpio_map is only for Raspberry Pi's so it shouldn't be called
    //       on any other board. Ignore the return value seems to work, but
    //       isn't a long-term solution.
    if (get_gpio_map(&priv->gpio_map) != 0) {
        debug("get_gpio_map failed");
        //return 1;
    }

    *priv_data = (void *) priv;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data)
{
    struct gpio_priv *priv = priv_data;
    debug("unload");

    // Close everything related to the listening thread so that it exits
    close(priv->pipe_fds[0]);
    close(priv->pipe_fds[1]);

    // If the listener thread hasn't exited already, it should do so soon.
    enif_thread_join(priv->poller_tid, NULL);

    munmap((void *)priv->gpio_map, GPIO_MAP_BLOCK_SIZE);

    // TODO free everything else!
}

static int export_pin(int pin_number)
{
    char pinstr[16];
    sprintf(pinstr, "%d", pin_number);
    if (sysfs_write_file("/sys/class/gpio/export", pinstr) <= 0)
        return - 1;

    return 0;
}

static int write_pin_direction(int pin_number, bool is_output)
{
    char direction_path[64];

    sprintf(direction_path, "/sys/class/gpio/gpio%d/direction", pin_number);
    if (access(direction_path, F_OK) != -1) {
        const char *dir_string = (is_output ? "out" : "in");
        int retries = 1000; /* Allow 1000 * 1ms = 1 second max for retries */
        while (sysfs_write_file(direction_path, dir_string) <= 0 && retries > 0) {
            usleep(1000);
            retries--;
        }
        if (retries == 0)
            return -1;
    }
    return 0;
}

static const char *mode_string(enum edge_mode mode)
{
    switch (mode) {
    default:
    case EDGE_NONE:
        return "none";
    case EDGE_FALLING:
        return "falling";
    case EDGE_RISING:
        return "rising";
    case EDGE_BOTH:
        return "both";
    }
}

static int write_edge_mode(int pin_number, enum edge_mode mode)
{
    char edge_path[64];

    sprintf(edge_path, "/sys/class/gpio/gpio%d/edge", pin_number);
    if (access(edge_path, F_OK) != -1) {
        int retries = 1000; /* Allow 1000 * 1ms = 1 second max for retries */
        while (sysfs_write_file(edge_path, mode_string(mode)) <= 0 && retries > 0) {
            usleep(1000);
            retries--;
        }
        if (retries == 0)
            return -1;
    }
    return 0;
}

static int get_edgemode(ErlNifEnv *env, ERL_NIF_TERM term, enum edge_mode *mode)
{
    char buffer[16];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("none", buffer) == 0) *mode = EDGE_NONE;
    else if (strcmp("rising", buffer) == 0) *mode = EDGE_RISING;
    else if (strcmp("falling", buffer) == 0) *mode = EDGE_FALLING;
    else if (strcmp("both", buffer) == 0) *mode = EDGE_BOTH;
    else return false;

    return true;
}

static int get_direction(ErlNifEnv *env, ERL_NIF_TERM term, bool *is_output)
{
    char buffer[8];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("input", buffer) == 0) *is_output = false;
    else if (strcmp("output", buffer) == 0) *is_output = true;
    else return false;

    return true;
}


#define GPPUD_OFFSET        37
#define GPPUDCLK0_OFFSET    38
#define DISABLE_PULLUP_DOWN 0
#define ENABLE_PULLDOWN     1
#define ENABLE_PULLUP       2

static int write_pull_mode(uint32_t *gpio_map, int pin_number, enum pull_mode pull)
{
    uint32_t  clk_bit_to_set = 1 << (pin_number%32);
    uint32_t *gpio_pud_clk = gpio_map + GPPUDCLK0_OFFSET + (pin_number/32);
    uint32_t *gpio_pud = gpio_map + GPPUD_OFFSET;

    if (pull == PULL_NOT_SET)
        return 0;

    // Steps to connect or disconnect pull up/down resistors on a gpio pin:

    // 1. Write to GPPUD to set the required control signal
    if (pull == PULL_DOWN)
        *gpio_pud = (*gpio_pud & ~3) | ENABLE_PULLDOWN;
    else if (pull == PULL_UP)
        *gpio_pud = (*gpio_pud & ~3) | ENABLE_PULLUP;
    else  // pull == PULL_NONE
        *gpio_pud &= ~3;  //DISABLE_PULLUP_DOWN

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

    return 0;
}

static int get_pull_mode(ErlNifEnv *env, ERL_NIF_TERM term, enum pull_mode *pull)
{
    char buffer[16];
    if (!enif_get_atom(env, term, buffer, sizeof(buffer), ERL_NIF_LATIN1))
        return false;

    if (strcmp("not_set", buffer) == 0) *pull = PULL_NOT_SET;
    else if (strcmp("none", buffer) == 0) *pull = PULL_NONE;
    else if (strcmp("pullup", buffer) == 0) *pull = PULL_UP;
    else if (strcmp("pulldown", buffer) == 0) *pull = PULL_DOWN;
    else return false;

    return true;
}


static ERL_NIF_TERM read_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    int value = sysfs_read_gpio(pin->fd);
    if (value < 0)
        return enif_raise_exception(env, enif_make_atom(env, strerror(errno)));

    return enif_make_int(env, value);
}

static ERL_NIF_TERM write_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    int value;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !enif_get_int(env, argv[1], &value))
        return enif_make_badarg(env);

    if (!pin->is_output)
        return enif_raise_exception(env, enif_make_atom(env, "pin_not_input"));

    char buff = value ? '1' : '0';
    ssize_t amount_written = pwrite(pin->fd, &buff, sizeof(buff), 0);
    if (amount_written < (ssize_t) sizeof(buff))
        return enif_raise_exception(env, enif_make_atom(env, strerror(errno)));

    return priv->atom_ok;
}

static ERL_NIF_TERM set_edge_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    enum edge_mode mode;
    bool suppress_glitches;
    ErlNifPid pid;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !get_edgemode(env, argv[1], &mode) ||
            !enif_get_boolean(env, argv[2], &suppress_glitches) ||
            !enif_get_local_pid(env, argv[3], &pid))
        return enif_make_badarg(env);

    if (write_edge_mode(pin->pin_number, mode) < 0)
        return make_error_tuple(env, "write_int_edge");

    // Tell polling thread to wait for notifications
    if (send_polling_thread(priv->pipe_fds[1], pin, mode, pid) < 0)
        return make_error_tuple(env, "polling_thread_error");

    return priv->atom_ok;
}

static ERL_NIF_TERM set_direction(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    bool is_output;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !get_direction(env, argv[1], &is_output))
        return enif_make_badarg(env);

    if (write_pin_direction(pin->pin_number, is_output) < 0)
        return make_error_tuple(env, "write_pin_direction");

    pin->is_output = is_output;

    return priv->atom_ok;
}

static ERL_NIF_TERM set_pull_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    enum pull_mode pull;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !get_pull_mode(env, argv[1], &pull))
        return enif_make_badarg(env);

    if (write_pull_mode(priv->gpio_map, pin->pin_number, pull) < 0)
        return make_error_tuple(env, "write_pull_mode");

    return priv->atom_ok;
}

static ERL_NIF_TERM pin_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    return enif_make_int(env, pin->pin_number);
}

static ERL_NIF_TERM open_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);

    bool is_output;
    int pin_number;
    if (!enif_get_int(env, argv[0], &pin_number) ||
            !get_direction(env, argv[1], &is_output))
        return enif_make_badarg(env);

    char value_path[64];
    sprintf(value_path, "/sys/class/gpio/gpio%d/value", pin_number);
    int fd = open(value_path, O_RDWR);
    if (fd < 0) {
        if (export_pin(pin_number) < 0)
            return make_error_tuple(env, "export_failed");

        fd = open(value_path, O_RDWR);
        if (fd < 0)
            return make_error_tuple(env, "access_denied");
    }

    struct gpio_pin *pin = enif_alloc_resource(priv->gpio_pin_rt, sizeof(struct gpio_pin));
    pin->fd = fd;
    pin->pin_number = pin_number;
    pin->is_output = is_output;

    if (write_pin_direction(pin_number, pin->is_output) < 0) {
        enif_release_resource(pin);
        return make_error_tuple(env, "error_setting_direction");
    }
    if (write_edge_mode(pin_number, EDGE_NONE) < 0) {
        enif_release_resource(pin);
        return make_error_tuple(env, "error_setting_edge_mode");
    }

    // Transfer ownership of the resource to Erlang so that it can be garbage collected.
    ERL_NIF_TERM pin_resource = enif_make_resource(env, pin);
    enif_release_resource(pin);

    return make_ok_tuple(env, pin_resource);
}

static ErlNifFunc nif_funcs[] = {
    {"open", 2, open_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read", 1, read_gpio, 0},
    {"write", 2, write_gpio, 0},
    {"set_edge_mode", 4, set_edge_mode, 0},
    {"set_direction", 2, set_direction, 0},
    {"set_pull_mode", 2, set_pull_mode, 0},
    {"pin", 1, pin_gpio, 0}
};

ERL_NIF_INIT(Elixir.ElixirCircuits.GPIO.Nif, nif_funcs, load, NULL, NULL, unload)
