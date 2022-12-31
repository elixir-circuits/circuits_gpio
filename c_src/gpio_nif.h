// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#ifndef GPIO_NIF_H
#define GPIO_NIF_H

#include "erl_nif.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>

//#define DEBUG

#ifdef DEBUG
#define log_location stderr
//#define LOG_PATH "/tmp/circuits_gpio.log"
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

#define MAX_GPIO_LISTENERS 32

enum trigger_mode {
    TRIGGER_NONE,
    TRIGGER_RISING,
    TRIGGER_FALLING,
    TRIGGER_BOTH
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

    int pins_open;

    uint32_t hal_priv[1];
};

struct gpio_config {
    bool is_output;
    enum trigger_mode trigger;
    enum pull_mode pull;
    bool suppress_glitches;
    int initial_value;
    ErlNifPid pid;
};

struct gpio_pin {
    int pin_number;
    int fd;
    void *hal_priv;
    struct gpio_config config;
};

// HAL

/**
 * Return information about the HAL.
 *
 * This should return a map with the name of the HAL and any info that
 * would help debug issues with it.
 */
ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info);

/**
 * Return the additional number of bytes of private data to allocate
 * for the HAL.
 */
size_t hal_priv_size(void);

/**
 * Initialize the HAL
 *
 * @param hal_priv where to store state
 * @return 0 on success
 */
int hal_load(void *hal_priv);

/**
 * Release all resources held by the HAL
 *
 * @param hal_priv private state
 */
void hal_unload(void *hal_priv);

/**
 * Open up and initialize a GPIO.
 *
 * @param pin information about the GPIO
 * @param error_str helpful text if something goes wrong
 * @param env a NIF environment in case a message is sent
 * @return 0 on success
 */
int hal_open_gpio(struct gpio_pin *pin,
                  char *error_str,
                  ErlNifEnv *env);

/**
 * Free up resources for the specified GPIO
 *
 * @param pin GPIO pin information
 */
void hal_close_gpio(struct gpio_pin *pin);

/**
 * Read the current value of a GPIO
 *
 * @param pin which one
 * @return 0 if low; 1 if high
 */
int hal_read_gpio(struct gpio_pin *pin);

/**
 * Change the value of a GPIO
 *
 * @param pin which one
 * @param value 0 or 1
 * @param env ErlNifEnv if this causes an event to be sent
 * @return 0 on success
 */
int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env);

/**
 * Apply GPIO direction settings
 *
 * This should set the GPIO to an input or an output. If setting
 * as an output, it should check the initial_value. If the
 * initial_value is < 0 then the GPIO should retain its value
 * if already an output. If set to 0 or 1, the GPIO should be
 * initialized to that value.
 *
 * @param pin which one
 * @return 0 on success
 */
int hal_apply_direction(struct gpio_pin *pin);

/**
 * Apply GPIO interrupt settings
 *
 * @param pin the pin and notification trigger info
 * @return 0 on success
 */
int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env);

/**
 * Apply GPIO pull mode settings
 *
 * @param pin which one
 * @return 0 on success
 */
int hal_apply_pull_mode(struct gpio_pin *pin);

// nif_utils.c
ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value);
ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason);
int enif_get_boolean(ErlNifEnv *env, ERL_NIF_TERM term, bool *v);

int send_gpio_message(ErlNifEnv *env,
                      ERL_NIF_TERM atom_gpio,
                      int pin_number,
                      ErlNifPid *pid,
                      int64_t timestamp,
                      int value);

#endif // GPIO_NIF_H
