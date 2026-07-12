// SPDX-FileCopyrightText: 2018 Frank Hunleth
// SPDX-FileCopyrightText: 2018 Mark Sebald
// SPDX-FileCopyrightText: 2023 Connor Rigby
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
extern FILE *log_location;
#define LOG_PATH "/tmp/circuits_gpio.log"
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

#define MAX_GPIOCHIP_PATH_LEN 32
#define MAX_GPIO_LISTENERS 32

// Maximum number of GPIO lines that can be opened together as a group.
// The Linux gpio-cdev v2 API caps a single line request at 64 lines, and the
// group value is carried as a 64-bit integer (one bit per line).
#define GPIO_MAX_LINES 64

enum trigger_mode {
    TRIGGER_NONE = 0,
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

enum drive_mode {
    DRIVE_PUSH_PULL,
    DRIVE_OPEN_DRAIN,
    DRIVE_OPEN_SOURCE
};

struct gpio_priv {
    ErlNifResourceType *gpio_pin_rt;

    uint32_t hal_priv[1];
};

struct gpio_config {
    bool is_output;

    // trigger is the edge(s) the hardware is configured to detect. For a
    // subscription this is forced to TRIGGER_BOTH so the shadow value stays
    // accurate; emit_trigger holds the edge(s) the caller actually wants
    // notifications for.
    enum trigger_mode trigger;
    enum trigger_mode emit_trigger;
    enum pull_mode pull;
    enum drive_mode drive;
    bool suppress_glitches;

    // Initial output values as an integer. Bit i corresponds to offsets[i].
    uint64_t initial_value;
    ErlNifPid pid;
};

struct gpio_pin {
    char gpiochip[MAX_GPIOCHIP_PATH_LEN];

    // Lines in this group. A single GPIO is just num_lines == 1. offsets[i] is
    // bit i of the value, with offsets[0] the least significant bit.
    int num_lines;
    int offsets[GPIO_MAX_LINES];

    // cdev: the file descriptor for the whole line request. stub: >= 0 marks
    // the group as open.
    int fd;
    void *hal_priv;
    struct gpio_config config;

    // Last known value. Used to compute the running aggregate and
    // previous_value for change notifications.
    uint64_t shadow;

    // NIF environment for holding on to terms across calls
    ErlNifEnv *env;

    // Echoed in legacy set_interrupts notifications ({:circuits_gpio, spec, ...})
    ERL_NIF_TERM gpio_spec;

    // Echoed in subscribe notifications ({:circuits_gpio, %{ref: ..., ...}}).
    // This is the make_ref() (or caller-supplied tag) returned by subscribe/2.
    ERL_NIF_TERM notify_id;

    // true  -> subscribe map format using notify_id
    // false -> legacy set_interrupts tuple format using gpio_spec
    bool notify_map;
};

// Atoms
extern ERL_NIF_TERM atom_ok;
extern ERL_NIF_TERM atom_error;
extern ERL_NIF_TERM atom_name;
extern ERL_NIF_TERM atom_label;
extern ERL_NIF_TERM atom_location;
extern ERL_NIF_TERM atom_controller;
extern ERL_NIF_TERM atom_circuits_gpio;
extern ERL_NIF_TERM atom_consumer;
extern ERL_NIF_TERM atom_ref;
extern ERL_NIF_TERM atom_timestamp;
extern ERL_NIF_TERM atom_value;
extern ERL_NIF_TERM atom_previous_value;

// HAL

/**
 * Return information about the HAL.
 *
 * This should return a map with the name of the HAL and any info that
 * would help debug issues with it.
 */
ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info);

/**
 * Enumerate all GPIO pins
 *
 * Returns a list of Circuits.GPIO.identifiers maps
 */
ERL_NIF_TERM hal_enumerate(ErlNifEnv *env, void *hal_priv);

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
 * @param env a NIF environment in case a message is sent
 * @return 0 on success, -errno on failure
 */
int hal_open_gpio(struct gpio_pin *pin,
                  ErlNifEnv *env);

/**
 * Free up resources for the specified GPIO
 *
 * This can be called more than once.
 *
 * @param pin GPIO pin information
 */
void hal_close_gpio(struct gpio_pin *pin);

/**
 * Read the current value of a GPIO group
 *
 * @param pin which group
 * @param value where to store the value (bit i == offsets[i])
 * @return 0 on success, -errno on failure
 */
int hal_read_gpio(struct gpio_pin *pin, uint64_t *value);

/**
 * Change the value of a GPIO group
 *
 * @param pin which group
 * @param value the value to drive (bit i == offsets[i])
 * @param env ErlNifEnv if this causes an event to be sent
 * @return 0 on success, -errno on failure
 */
int hal_write_gpio(struct gpio_pin *pin, uint64_t value, ErlNifEnv *env);

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
 * @return 0 on success, -errno on failure
 */
int hal_apply_direction(struct gpio_pin *pin);

/**
 * Apply GPIO interrupt settings
 *
 * @param pin the pin and notification trigger info
 * @return 0 on success, -errno on failure
 */
int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env);

/**
 * Apply GPIO pull mode settings
 *
 * @param pin which one
 * @return 0 on success, -errno on failure
 */
int hal_apply_pull_mode(struct gpio_pin *pin);

/**
 * Apply GPIO drive mode settings
 *
 * @param pin which one
 * @return 0 on success, -errno on failure
 */
int hal_apply_drive_mode(struct gpio_pin *pin);

/**
 * Return a map that has runtime information about a GPIO
 *
 * @param env a NIF environment for making the map
 * @param gpiochip which controller
 * @param offset the offset on the controller
 * @param result where to store the result when successful
 * @return 0 on success, -errno on failure
 */
int hal_get_status(void *hal_priv, ErlNifEnv *env, const char *gpiochip, int offset, ERL_NIF_TERM *result);

// nif_utils.c
ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value);
ERL_NIF_TERM make_errno_atom(ErlNifEnv *env, int errno_value);
ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int errno_value);
ERL_NIF_TERM make_string_binary(ErlNifEnv *env, const char *str);
int enif_get_boolean(ErlNifEnv *env, ERL_NIF_TERM term, bool *v);

/**
 * Send a GPIO interrupt message to a process
 *
 * @param env the caller's environment: the process bound environment when
 *            called from a NIF or NULL when called from a custom thread
 * @param msg_env a process independent environment for building the message.
 *                It is cleared before this function returns so that it can be
 *                reused.
 * @param gpio_spec the GPIO spec term (may be from another environment)
 * @param pid who to notify
 * @param timestamp event timestamp in nanoseconds
 * @param value the new GPIO value
 * @return true on success (see enif_send)
 */
int send_gpio_message(ErlNifEnv *env,
                      ErlNifEnv *msg_env,
                      ERL_NIF_TERM gpio_spec,
                      ErlNifPid *pid,
                      int64_t timestamp,
                      int value);

/**
 * Send a GPIO change notification (subscribe/2 map format) to a process
 *
 * Builds {:circuits_gpio, %{ref: notify_id, timestamp: ts, value: value,
 * previous_value: previous_value}}.
 *
 * @param env the caller's environment: the process bound environment when
 *            called from a NIF or NULL when called from a custom thread
 * @param msg_env a process independent environment for building the message.
 *                It is cleared before this function returns so that it can be
 *                reused.
 * @param notify_id the ref/tag term to echo (may be from another environment)
 * @param pid who to notify
 * @param timestamp event timestamp in nanoseconds
 * @param value the new group value
 * @param previous_value the group value before this change
 * @return true on success (see enif_send)
 */
int send_gpio_change(ErlNifEnv *env,
                     ErlNifEnv *msg_env,
                     ERL_NIF_TERM notify_id,
                     ErlNifPid *pid,
                     int64_t timestamp,
                     uint64_t value,
                     uint64_t previous_value);

/**
 * Decide whether a single-line edge should produce a notification and, if so,
 * send it in the right format.
 *
 * Shared by the stub HAL (which has the gpio_pin) and the cdev poller thread
 * (which has copied monitor state). The caller is responsible for tracking the
 * shadow value and passing new/previous values.
 *
 * @param env caller env (NULL from a custom thread)
 * @param msg_env reusable message environment
 * @param notify_map true => subscribe map format; false => legacy tuple format
 * @param notify_term gpio_spec (legacy) or ref/tag (map) to echo
 * @param pid who to notify
 * @param emit_trigger which edge(s) the caller wants notifications for
 * @param timestamp event timestamp in nanoseconds
 * @param new_value the new group value
 * @param previous_value the group value before this change
 * @param changed_bit index of the bit that changed
 * @return true on success or when no message was needed; false on send failure
 */
bool emit_gpio_change(ErlNifEnv *env,
                      ErlNifEnv *msg_env,
                      bool notify_map,
                      ERL_NIF_TERM notify_term,
                      ErlNifPid *pid,
                      enum trigger_mode emit_trigger,
                      int64_t timestamp,
                      uint64_t new_value,
                      uint64_t previous_value,
                      int changed_bit);

#endif // GPIO_NIF_H
