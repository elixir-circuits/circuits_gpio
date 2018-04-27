#include "erl_nif.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_GPIO_LISTENERS 32

#define DEBUG

#ifdef DEBUG
#define log_location stderr
//#define LOG_PATH "/tmp/elixir_ale_gpio.log"
#define debug(...) do { enif_fprintf(log_location, __VA_ARGS__); enif_fprintf(log_location, "\r\n"); fflush(log_location); } while(0)
#define error(...) do { debug(__VA_ARGS__); } while (0)
#define start_timing() ErlNifTime __start = enif_monotonic_time(ERL_NIF_USEC)
#define elapsed_microseconds() (enif_monotonic_time(ERL_NIF_USEC) - __start)
#else
#define debug(...)
#define error(...) do { enif_fprintf(stderr, __VA_ARGS__); enif_fprintf(stderr, "\n"); } while(0)
#define start_timing()
#define elapsed_microseconds() 0
#endif

struct gpio_monitor_info {
    int pin_number;
    int fd;
    ErlNifPid pid;
};

struct gpio_priv {
    ERL_NIF_TERM atom_ok;
    ERL_NIF_TERM atom_undefined;

    ErlNifResourceType *gpio_pin_rt;

    ErlNifTid poller_tid;
    int pipe_fds[2];

    struct gpio_monitor_info monitor_info[MAX_GPIO_LISTENERS];
};

struct gpio_pin {
    int fd;
    int pin_number;
    bool is_output;
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

static int sysfs_write_file(const char *pathname, const char *value)
{
    int fd = open(pathname, O_WRONLY);
    if (fd < 0) {
        error("Error opening %s", pathname);
        return -1;
    }

    size_t count = strlen(value);
    ssize_t written = write(fd, value, count);
    close(fd);

    if (written < 0 || (size_t) written != count) {
        error("Error writing '%s' to %s", value, pathname);
        return -1;
    }
    return written;
}

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

int64_t timestamp_nanoseconds()
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;

    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void *gpio_poller_thread(void *arg)
{
    struct pollfd fdset[MAX_GPIO_LISTENERS + 1];
    struct gpio_priv *gpio_priv = arg;
    debug("gpio_poller_thread started");

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM atom_elixir_ale = enif_make_atom(env, "elixir_ale");

    init_listeners(gpio_priv->monitor_info);
    for (;;) {
        struct pollfd *fds = &fdset[0];
        int count = 0;

        struct gpio_monitor_info *info = gpio_priv->monitor_info;
        while (info->fd >= 0) {
            fds->fd = info->fd;
            fds->events = POLLPRI;
            fds->revents = 0;
            fds++;
            info++;
            count++;
        }

        fds->fd = gpio_priv->pipe_fds[0];
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
            ssize_t amount_read = read(gpio_priv->pipe_fds[0], &message, sizeof(message));
            if (amount_read != sizeof(message)) {
                error("Unexpected return from read: %d, errno=%d", amount_read, errno);
                break;
            }

            if (message.fd >= 0)
                add_listener(gpio_priv->monitor_info, &message);
            else
                remove_listener(gpio_priv->monitor_info, message.pin_number);
        }

        bool cleanup = false;
        for (int i = 0; i < count - 1; i++) {
            if (fdset[i].revents) {
                if (fdset[i].revents & POLLPRI) {
                    int value = sysfs_read_gpio(fdset[i].fd);
                    if (value < 0) {
                        error("error reading gpio %d", gpio_priv->monitor_info[i].pin_number);
                        gpio_priv->monitor_info[i].fd = -1;
                        cleanup = true;
                    } else {
                        ERL_NIF_TERM msg = enif_make_tuple4(env,
                                atom_elixir_ale,
                                enif_make_int(env, gpio_priv->monitor_info[i].pin_number),
                                enif_make_int64(env, timestamp),
                                enif_make_int(env, value));

                        if (!enif_send(env, &gpio_priv->monitor_info[i].pid, NULL, msg)) {
                            error("send for gpio %d failed, so not listening to it any more", gpio_priv->monitor_info[i].pin_number);
                            gpio_priv->monitor_info[i].fd = -1;
                            cleanup = true;
                        }
                    }
                } else {
                    error("error listening on gpio %d", gpio_priv->monitor_info[i].pin_number);
                    gpio_priv->monitor_info[i].fd = -1;
                    cleanup = true;
                }
            }
        }

        if (cleanup) {
            // Compact the listener list
            compact_listeners(gpio_priv->monitor_info, count);
        }
    }

    enif_free_env(env);
    debug("gpio_poller_thread ended");
    return NULL;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM info)
{
#ifdef DEBUG
#ifdef LOG_PATH
    log_location = fopen(LOG_PATH, "w");
#endif
#endif
    debug("load");

    struct gpio_priv *gpio_priv = enif_alloc(sizeof(struct gpio_priv));
    if (!gpio_priv) {
        error("Can't allocate gpio_priv");
        return 1;
    }

    gpio_priv->atom_ok = enif_make_atom(env, "ok");
    gpio_priv->atom_undefined = enif_make_atom(env, "undefined");

    gpio_priv->gpio_pin_rt = enif_open_resource_type_x(env, "gpio_pin", &gpio_pin_init, ERL_NIF_RT_CREATE, NULL);

    if (pipe(gpio_priv->pipe_fds) < 0) {
        error("pipe failed");
        return 1;
    }

    if (enif_thread_create("gpio_poller", &gpio_priv->poller_tid, gpio_poller_thread, gpio_priv, NULL) != 0) {
        error("enif_thread_create failed");
        return 1;
    }

    *priv_data = (void *) gpio_priv;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data)
{
    struct gpio_priv *priv = priv_data;
    debug("unload");

    // Close everything related to the listening thread so that it exits
    close(priv->pipe_fds[0]);
    close(priv->pipe_fds[1]);
    for (int i = 0; i < MAX_GPIO_LISTENERS; i++) {
        if (priv->monitor_info[i].fd >= 0) {
            close(priv->monitor_info[i].fd);
            priv->monitor_info[i].fd = -1;
        } else {
            break;
        }
    }

    // If the listener thread hasn't exited already, it should do so soon.
    enif_thread_join(priv->poller_tid, NULL);

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

static int write_int_edge(int pin_number, const char *mode)
{
    char edge_path[64];

    sprintf(edge_path, "/sys/class/gpio/gpio%d/edge", pin_number);
    if (access(edge_path, F_OK) != -1) {
        int retries = 1000; /* Allow 1000 * 1ms = 1 second max for retries */
        while (sysfs_write_file(edge_path, mode) <= 0 && retries > 0) {
            usleep(1000);
            retries--;
        }
        if (retries == 0)
            return -1;
    }
    return 0;
}

static ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value)
{
    struct gpio_priv *priv = enif_priv_data(env);

    return enif_make_tuple2(env, priv->atom_ok, value);
}

static ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason)
{
    ERL_NIF_TERM error_atom = enif_make_atom(env, "error");
    ERL_NIF_TERM reason_atom = enif_make_atom(env, reason);

    return enif_make_tuple2(env, error_atom, reason_atom);
}

static ERL_NIF_TERM read_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    int value = sysfs_read_gpio(pin->fd);
    if (value < 0) {
        error("Error reading GPIO %d: rc=%d, fd=%d, errno=%d", pin->pin_number, value, pin->fd, errno);
        return make_error_tuple(env, "read");
    }

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
        return make_error_tuple(env, "pin_not_input");

    char buff = value ? '1' : '0';
    ssize_t amount_written = pwrite(pin->fd, &buff, sizeof(buff), 0);
    if (amount_written < (ssize_t) sizeof(buff)) {
        error("Error writing GPIO %d: rc=%d, fd=%d, errno=%d", pin->pin_number, amount_written, pin->fd, errno);
        return make_error_tuple(env, "write");
    }

    return priv->atom_ok;
}

static ERL_NIF_TERM set_int_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;

    char edge[16];
    ErlNifPid pid;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin) ||
            !enif_get_atom(env, argv[1], edge, sizeof(edge), ERL_NIF_LATIN1) ||
            !enif_get_local_pid(env, argv[2], &pid))
        return enif_make_badarg(env);

    if (write_int_edge(pin->pin_number, edge) < 0)
        return make_error_tuple(env, "write_int_edge");

    // Tell polling thread to wait for notifications
    struct gpio_monitor_info message;
    message.pin_number = pin->pin_number;
    message.fd = strcmp(edge, "none") == 0 ? -1 : pin->fd;
    message.pid = pid;
    if (write(priv->pipe_fds[1], &message, sizeof(message)) != sizeof(message)) {
        error("Error writing polling thread!");
        return make_error_tuple(env, "polling_thread_error");
    }

    return priv->atom_ok;
}

static ERL_NIF_TERM open_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);

    char direction[8];
    int pin_number;
    if (!enif_get_int(env, argv[0], &pin_number) ||
            !enif_get_atom(env, argv[1], direction, sizeof(direction), ERL_NIF_LATIN1))
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
    pin->is_output = (strcmp(direction, "output") == 0);

    if (write_pin_direction(pin_number, pin->is_output) < 0) {
        enif_release_resource(pin);
        return make_error_tuple(env, "error_setting_direction");
    }
    if (write_int_edge(pin_number, "none") < 0) {
        enif_release_resource(pin);
        return make_error_tuple(env, "error_setting_direction");
    }

    // Transfer ownership of the resource to Erlang so that it can be garbage collected.
    ERL_NIF_TERM pin_resource = enif_make_resource(env, pin);
    enif_release_resource(pin);

    return make_ok_tuple(env, pin_resource);
}

static ErlNifFunc nif_funcs[] = {
    {"open", 2, open_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write", 2, write_gpio, 0},
    {"read", 1, read_gpio, 0},
    {"set_int", 3, set_int_gpio, 0},
};

ERL_NIF_INIT(Elixir.ElixirALE.GPIO.Nif, nif_funcs, load, NULL, NULL, unload)
