#ifndef GPIO_NIF_H
#define GPIO_NIF_H

#include "erl_nif.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>

#define MAX_GPIO_LISTENERS 32

#define DEBUG

#ifdef DEBUG
#define log_location stderr
//#define LOG_PATH "/tmp/elixir_circuits_gpio.log"
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

enum edge_mode {
    EDGE_NONE,
    EDGE_RISING,
    EDGE_FALLING,
    EDGE_BOTH
};

enum pull_mode {
    PULL_NOT_SET,
    PULL_NONE,
    PULL_UP,
    PULL_DOWN
};

struct gpio_priv {
    ERL_NIF_TERM atom_ok;

    ErlNifResourceType *gpio_pin_rt;

    ErlNifTid poller_tid;
    int pipe_fds[2];
    uint32_t *gpio_map;
};

struct gpio_pin {
    int fd;
    int pin_number;
    bool is_output;
};

#define GPIO_MAP_BLOCK_SIZE (4*1024)
#define PAGE_SIZE  (4*1024)
#define GPIO_BASE_OFFSET    0x200000

// sysfs_utils.c
int sysfs_write_file(const char *pathname, const char *value);
int get_gpio_map(uint32_t **gpio_map);

// nif_utils.c
ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value);
ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason);
int enif_get_boolean(ErlNifEnv *env, ERL_NIF_TERM term, bool *v);

#endif // GPIO_NIF_H
