#include "erl_nif.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

//#define DEBUG

#ifdef DEBUG
static FILE *log_location;
#define LOG_PATH "/tmp/elixir_ale_gpio.log"
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

struct gpio_priv {
    ERL_NIF_TERM atom_ok;
    ERL_NIF_TERM atom_undefined;

    ErlNifResourceType *gpio_pin_rt;

    void *resource;
};

struct gpio_pin {
    int fd;
    int pin_number;
    char direction[7];
    char value_path[64];
    char direction_path[64];
    bool polling;
};

static void gpio_pin_dtor(ErlNifEnv *env, void *obj)
{
    debug("gpio_pin_dtor called");

    struct gpio_pin *pin = (struct gpio_pin*) obj;
    close(pin->fd);
}

static void gpio_pin_stop(ErlNifEnv *env, void *obj, int fd, int is_direct_call)
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin = (struct gpio_pin*) obj;

    debug("gpio_pin_stop called %s, polling=%d", (is_direct_call ? "DIRECT" : "LATER"), pin->polling);
    #if 0
    if (data->polling && is_direct_call) {
        data->polling = false;
        enif_select(env, fd, ERL_NIF_SELECT_STOP, obj, NULL, data->atom_undefined);
    }
    #endif
}

static void gpio_pin_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *monitor)
{
    debug("gpio_pin_down called");
}

static ErlNifResourceTypeInit gpio_pin_init = {gpio_pin_dtor, gpio_pin_stop, gpio_pin_down};

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
#ifdef DEBUG
    log_location = fopen(LOG_PATH, "w");
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

    *priv = (void *) gpio_priv;
    return 0;
}

static int sysfs_write_file(const char *pathname, const char *value)
{
    int fd = open(pathname, O_WRONLY);

    if (fd < 0) {
        error("Error opening %s", pathname);
        return 0;
    }

    size_t count = strlen(value);
    ssize_t written = write(fd, value, count);
    close(fd);

    if (written < 0 || (size_t) written != count) {
        error("Error writing '%s' to %s", value, pathname);
        return 0;
    }
    return written;
}

static int set_gpio_paths(struct gpio_pin *pin)
{
    sprintf(pin->value_path, "/sys/class/gpio/gpio%d/value", pin->pin_number);
    sprintf(pin->direction_path, "/sys/class/gpio/gpio%d/direction", pin->pin_number);

    return 0;
}

static int export_pin(struct gpio_pin *pin)
{
    if (access(pin->value_path, F_OK) == -1) {
        char pinstr[16];
        sprintf(pinstr, "%d", pin->pin_number);
        if (!sysfs_write_file("/sys/class/gpio/export", pinstr))
            return - 1;
    }

    return 0;
}

static int write_direction(struct gpio_pin *pin)
{
    if (access(pin->direction_path, F_OK) != -1) {
        const char *dir_string = (strcmp(pin->direction,"output") == 0 ? "out" : "in");
        int retries = 1000; /* Allow 1000 * 1ms = 1 second max for retries */
        while (!sysfs_write_file(pin->direction_path, dir_string) && retries > 0) {
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

#if 0
static int setup_polling(ErlNifEnv *env)
{
    struct gpio_priv *priv = enif_priv_data(env);
    int rc = enif_select(env, pin->fd, ERL_NIF_SELECT_READ, pin, NULL, priv->atom_undefined);
    return rc;
}
#endif

static ERL_NIF_TERM poll(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
#if 0
    if (pin->polling)
        return priv->atom_ok;

    int rc = setup_polling(env);

    if (rc < 0)
        return make_error_tuple(env, "enif_select");

    pin->polling = true;
#endif
    return priv->atom_ok;
}


static ERL_NIF_TERM read_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);
    struct gpio_pin *pin;
    if (!enif_get_resource(env, argv[0], priv->gpio_pin_rt, (void**) &pin))
        return enif_make_badarg(env);

    char buf;
    ssize_t amount_read = pread(pin->fd, &buf, sizeof(buf), 0);
    if (amount_read < (ssize_t) sizeof(buf))
        return make_error_tuple(env, "read");

    int value = buf == '1' ? 1 : 0;

#if 0
    if (pin->polling) {
        int rc = setup_polling(env);

        if (rc < 0) {
            pin->polling = false;
            return make_error_tuple(env, "enif_select");
        }
    }
#endif

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

    char buff = value ? '1' : '0';
    ssize_t amount_written = pwrite(pin->fd, &buff, sizeof(buff), 0);
    if (amount_written < (ssize_t) sizeof(buff))
        return make_error_tuple(env, "write");

    return priv->atom_ok;
}

static ERL_NIF_TERM init_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct gpio_priv *priv = enif_priv_data(env);

    struct gpio_pin *pin = enif_alloc_resource(priv->gpio_pin_rt, sizeof(struct gpio_pin));

    if (!enif_get_int(env, argv[0], &pin->pin_number))
        return make_error_tuple(env, "invalid_pin_number");

    if (!enif_get_atom(env, argv[1], pin->direction, 7, ERL_NIF_LATIN1))
        return make_error_tuple(env, "invalid_direction");

    set_gpio_paths(pin);
    export_pin(pin);
    write_direction(pin);

    /* Open the value path file for quick access later */
    pin->fd = open(pin->value_path, O_RDWR);
    if (pin->fd < 0)
        return make_error_tuple(env, "bad_stff");

    return make_ok_tuple(env, enif_make_resource(env, pin));
}

static ErlNifFunc nif_funcs[] = {
    {"init_gpio", 2, init_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write", 2, write_gpio, 0},
    {"read", 1, read_gpio, 0},
    {"poll", 0, poll, 0},
};

ERL_NIF_INIT(Elixir.ElixirALE.GPIO.Nif, nif_funcs, load, NULL, NULL, NULL)
