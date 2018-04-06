#include "erl_nif.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <err.h>

#ifdef DEBUG
#define debug(...) do { fprintf(stderr, __VA_ARGS); fprintf(stderr, "\r\n"); } while (0)
#else
#define debug(...)
#endif

typedef struct gpio {
    int fd;
    int pin_number;
    char direction[7];
    char value_path[64];
    char direction_path[64];
} GPIO;

int sysfs_write_file(const char *pathname, const char *value)
{
    int fd = open(pathname, O_WRONLY);

    if (fd < 0) {
        debug("Error opening %s", pathname);
        return 0; 
    }

    size_t count = strlen(value);
    ssize_t written = write(fd, value, count);
    close(fd);

    if (written < 0 || (size_t) written != count) {
        debug("Error writing '%s' to %s", value, pathname);
        return 0;
    }
    return written;
}

int set_value_path(GPIO *pin)
{
    if (!pin->pin_number)
        return -1;

    return sprintf(pin->value_path, "/sys/class/gpio/gpio%d/value", pin->pin_number);
}

int set_gpio_paths(GPIO *pin)
{
    if (!pin->pin_number)
        return -1;

    set_value_path(pin);
    sprintf(pin->direction_path, "/sys/class/gpio/gpio%d/direction", pin->pin_number);

    return 0;
}

int export_pin(GPIO *pin)
{
    if (!pin->value_path)
        return -1;

    if (access(pin->value_path, F_OK) == -1) {
        char pinstr[24];
        sprintf(pinstr, "%d", pin->pin_number);
        if (!sysfs_write_file("/sys/class/gpio/export", pinstr))
                return - 1;
    }

    return 0;
}

int write_direction(GPIO *pin)
{
    if (access(pin->direction_path, F_OK) != -1) {
        int retries = 1000; /* Allow 1000 * 1ms = 1 second max for retries */
        while (!sysfs_write_file(pin->direction_path, pin->direction) && retries > 0) {
            usleep(1000);
            retries--;
        }
        if (retries == 0)
            return -1;
    }
    return 0;
}

int gpio_write(GPIO *pin, unsigned int val)
{
    char buff = val ? '1' : '0';

    ssize_t amount_written = pwrite(pin->fd, &buff, sizeof(buff), 0);
    if (amount_written < (ssize_t) sizeof(buff))
        err(EXIT_FAILURE, "pwrite");

    return 1;
}


ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value)
{
    ERL_NIF_TERM ok_atom = enif_make_atom(env, "ok");

    return enif_make_tuple2(env, ok_atom, value);
}


ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    ERL_NIF_TERM error_atom = enif_make_atom(env, "error");

    return enif_make_tuple2(env, error_atom, reason);
}

static ERL_NIF_TERM read_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    GPIO pin;

    enif_get_int(env, argv[0], &pin.pin_number);
    enif_get_int(env, argv[1], &pin.fd);
    set_value_path(&pin);

    char buf;
    ssize_t amount_read = pread(pin.fd, &buf, sizeof(buf), 0);

    if (amount_read < (ssize_t) sizeof(buf)) {
        return enif_make_atom(env, "error");
    }

    int value = buf == '1' ? 1 : 0;

    return enif_make_int(env, value);
}

static ERL_NIF_TERM write_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    GPIO pin;
    int value;

    enif_get_int(env, argv[0], &pin.pin_number);
    enif_get_int(env, argv[1], &value);
    enif_get_int(env, argv[2], &pin.fd);

    gpio_write(&pin, value);

    return enif_make_atom(env, "ok");

}

static ERL_NIF_TERM init_gpio(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    GPIO pin;

    if (!enif_get_int(env, argv[0], &pin.pin_number)) {
        char pin_error[] = "pin_number_invalid_type";
        return make_error_tuple(env, enif_make_atom(env, pin_error));
    }

    if (!enif_get_atom(env, argv[1], pin.direction, 7, ERL_NIF_LATIN1)) {
        char direction_error[] = "direction_invalid";
        return make_error_tuple(env, enif_make_atom(env, direction_error));
    }

    set_gpio_paths(&pin);
    export_pin(&pin);
    write_direction(&pin);

    printf("value path: %s\n", pin.value_path);

    /* Open the value path file for quick access later */
    pin.fd = open(pin.value_path, O_RDWR);

    if (pin.fd < 0)
        return make_error_tuple(env, enif_make_atom(env, "bad_stff"));

    
    return make_ok_tuple(env, enif_make_int(env, pin.fd));
}

static ErlNifFunc nif_funcs[] = {
    {"init_gpio", 2, init_gpio, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write_nif", 3, write_gpio, 0},
    {"read_nif", 2, read_gpio, 0},
};

ERL_NIF_INIT(Elixir.ElixirALE.GPIO, nif_funcs, NULL, NULL, NULL, NULL)
