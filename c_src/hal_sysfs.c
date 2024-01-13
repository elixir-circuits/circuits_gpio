// SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
//
// SPDX-License-Identifier: Apache-2.0

#include "gpio_nif.h"

#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "hal_sysfs.h"

/* Some time between Linux 5.10 and Linux 5.15, GPIO numbering changed on
 * AM335x devices (Beaglebone, etc.). These devices have 4 banks of 32 GPIOs.
 * They used to be alphabetically sorted for file names which mirrored the
 * order they showed up in the I/O address map. Now they show up. Now they show
 * up with the bank at address 0x44c00000 coming after all of the 0x48000000
 * banks.
 *
 * To get the original mapping, GPIO numbers between 0 and 127 need to be
 * rotated by 32. I.e., x' = (x + 32) % 128.
 *
 * The real fix would be to embrace cdev and stop using GPIO numbers and the
 * sysfs interface, but that requires changing a lot of code, so work around
 * it.
 */
static int bbb_rotate_gpio = 0;

static void check_bbb_linux_5_15_gpio_change()
{
    // Check for the gpiochip ordering that has the 0x44c00000 controller
    // ordered AFTER the 0x48000000.
    //
    // These are ordered so that the for loop fails as soon as possible on
    // non-AM335x platforms. Since few devices get up to gpiochip3, the
    // readlink(2) call should fail and there shouldn't even be a string
    // compare.
    static const char *symlink_value[] = {
        "/sys/bus/gpio/devices/gpiochip3",
        "../../../devices/platform/ocp/44c00000.interconnect/44c00000.interconnect:segment@200000/44e07000.target-module/44e07000.gpio/gpiochip3",
        "/sys/bus/gpio/devices/gpiochip0",
        "../../../devices/platform/ocp/48000000.interconnect/48000000.interconnect:segment@0/4804c000.target-module/4804c000.gpio/gpiochip0",
        "/sys/bus/gpio/devices/gpiochip1",
        "../../../devices/platform/ocp/48000000.interconnect/48000000.interconnect:segment@100000/481ac000.target-module/481ac000.gpio/gpiochip1",
        "/sys/bus/gpio/devices/gpiochip2",
        "../../../devices/platform/ocp/48000000.interconnect/48000000.interconnect:segment@100000/481ae000.target-module/481ae000.gpio/gpiochip2"
    };

    char path[PATH_MAX];
    int i;

    bbb_rotate_gpio = 0;
    for (i = 0; i < 8; i += 2) {
        ssize_t path_len = readlink(symlink_value[i], path, sizeof(path) - 1);
        if (path_len < 0)
            return;

        path[path_len] = '\0';
        if (strcmp(symlink_value[i + 1], path) != 0)
            return;
    }
    bbb_rotate_gpio = 1;
}

static int fix_gpio_number(int pin_number)
{
    if (!bbb_rotate_gpio || pin_number >= 128)
        return pin_number;

    return (pin_number + 32) & 0x7f;
}

size_t hal_priv_size()
{
    return sizeof(struct sysfs_priv);
}

/* This is a workaround for a first-time initialization issue where the file doesn't appear
 * quickly after export.
 */
static int retry_open(const char *pathname, int flags, int retries)
{
    do {
        int fd = open(pathname, flags);
        if (fd >= 0)
            return fd;

        retries--;
        debug("Error opening %s. Retrying %d times", pathname, retries);
        usleep(1000);
    } while (retries > 0);

    return -1;
}

static ssize_t sysfs_write_file(const char *pathname, const char *value, int retries)
{
    int fd = retry_open(pathname, O_WRONLY, retries);
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

static ssize_t sysfs_read_file(const char *pathname, char *value, size_t len, int retries)
{
    int fd = retry_open(pathname, O_RDONLY, retries);
    if (fd < 0) {
        error("Error opening %s", pathname);
        return -1;
    }

    ssize_t amount_read = read(fd, value, len);
    close(fd);

    if (amount_read <= 0) {
        error("Error writing '%s' to %s", value, pathname);
        return -1;
    }
    return amount_read;
}

static int export_pin(int pin_number)
{
    char pinstr[16];
    sprintf(pinstr, "%d", pin_number);
    if (sysfs_write_file("/sys/class/gpio/export", pinstr, 0) <= 0)
        return - 1;

    return 0;
}

static const char *edge_mode_string(enum trigger_mode mode)
{
    switch (mode) {
    default:
    case TRIGGER_NONE:
        return "none";
    case TRIGGER_FALLING:
        return "falling";
    case TRIGGER_RISING:
        return "rising";
    case TRIGGER_BOTH:
        return "both";
    }
}

ERL_NIF_TERM hal_info(ErlNifEnv *env, void *hal_priv, ERL_NIF_TERM info)
{
    enif_make_map_put(env, info, enif_make_atom(env, "name"), enif_make_atom(env, "sysfs"), &info);

    if (bbb_rotate_gpio < 0)
        check_bbb_linux_5_15_gpio_change();

    enif_make_map_put(env, info, enif_make_atom(env, "remap_bbb_gpios"), bbb_rotate_gpio ? enif_make_atom(env, "true") : enif_make_atom(env, "false"), &info);

#ifdef TARGET_RPI
    return rpi_info(env, hal_priv, info);
#else
    (void) hal_priv;
    return info;
#endif
}

int hal_load(void *hal_priv)
{
    struct sysfs_priv *priv = hal_priv;
    memset(priv, 0, sizeof(struct sysfs_priv));

    if (pipe(priv->pipe_fds) < 0) {
        error("pipe failed");
        return 1;
    }

    if (enif_thread_create("gpio_poller", &priv->poller_tid, gpio_poller_thread, &priv->pipe_fds[0], NULL) != 0) {
        error("enif_thread_create failed");
        return 1;
    }

    check_bbb_linux_5_15_gpio_change();

    return 0;
}

void hal_unload(void *hal_priv)
{
    struct sysfs_priv *priv = hal_priv;

    // Close everything related to the listening thread so that it exits
    close(priv->pipe_fds[0]);
    close(priv->pipe_fds[1]);

    // If the listener thread hasn't exited already, it should do so soon.
    enif_thread_join(priv->poller_tid, NULL);

#ifdef TARGET_RPI
    rpi_unload(priv);
#endif
    // TODO free everything else!
}

int hal_open_gpio(struct gpio_pin *pin,
                  char *error_str,
                  ErlNifEnv *env)
{
    *error_str = '\0';

    int pin_number = fix_gpio_number(pin->pin_number);
    char value_path[64];
    sprintf(value_path, "/sys/class/gpio/gpio%d/value", pin_number);
    pin->fd = open(value_path, O_RDWR);
    if (pin->fd < 0) {
        if (export_pin(pin_number) < 0) {
            strcpy(error_str, "export_failed");
            return -1;
        }

        // wait up to 1000ms for the gpio symlink to be created
        pin->fd = retry_open(value_path, O_RDWR, 1000);
        if (pin->fd < 0) {
            strcpy(error_str, "access_denied");
            return -1;
        }
    }
    if (hal_apply_direction(pin) < 0) {
        strcpy(error_str, "error_setting_direction");
        goto error;
    }
    if (hal_apply_pull_mode(pin) < 0) {
        strcpy(error_str, "error_setting_pull_mode");
        goto error;
    }
    // Only call hal_apply_interrupts if there's a trigger. While sysfs limits
    // users to one "interrupt" handler, it's still nice to be able to check a
    // a GPIO's state.
    if (pin->config.trigger != TRIGGER_NONE && hal_apply_interrupts(pin, env) < 0) {
        strcpy(error_str, "error_setting_interrupts");
        goto error;
    }

    return 0;

error:
    close(pin->fd);
    pin->fd = -1;
    return -1;
}

void hal_close_gpio(struct gpio_pin *pin)
{
    if (pin->fd >= 0) {
        // Turn off interrupts if they're on.
        if (pin->config.trigger != TRIGGER_NONE) {
            pin->config.trigger = TRIGGER_NONE;
            update_polling_thread(pin);
        }
        close(pin->fd);
        pin->fd = -1;
    }
}

int sysfs_read_gpio(int fd)
{
    char buf;
    ssize_t amount_read = pread(fd, &buf, sizeof(buf), 0);
    if (amount_read == sizeof(buf))
        return buf == '1';
    else
        return -1;
}

int hal_read_gpio(struct gpio_pin *pin)
{
    return sysfs_read_gpio(pin->fd);
}

int hal_write_gpio(struct gpio_pin *pin, int value, ErlNifEnv *env)
{
    (void) env;

    char buff = value ? '1' : '0';
    return (int) pwrite(pin->fd, &buff, sizeof(buff), 0);
}

int hal_apply_interrupts(struct gpio_pin *pin, ErlNifEnv *env)
{
    (void) env;

    char edge_path[64];
    int pin_number = fix_gpio_number(pin->pin_number);
    sprintf(edge_path, "/sys/class/gpio/gpio%d/edge", pin_number);

    /* Allow 1000 * 1ms = 1 second max for retries. This is a workaround
     * for a first-time initialization issue where the file doesn't appear
     * quickly after export */
    if (sysfs_write_file(edge_path, edge_mode_string(pin->config.trigger), 1000) < 0)
        return -1;

    // Tell polling thread to wait for notifications
    if (update_polling_thread(pin) < 0)
        return -1;

    return 0;
}

int hal_apply_direction(struct gpio_pin *pin)
{
    char direction_path[64];
    int pin_number = fix_gpio_number(pin->pin_number);
    sprintf(direction_path, "/sys/class/gpio/gpio%d/direction", pin_number);

    /* Allow 1000 * 1ms = 1 second max for retries. See hal_apply_interrupts too. */
    char current_dir[16];
    if (sysfs_read_file(direction_path, current_dir, sizeof(current_dir), 1000) < 0)
        return -1;

    /* Linux only reports "in" and "out". (current_dir is NOT null terminated here) */
    int current_is_output = (current_dir[0] == 'o');

    if (pin->config.is_output == 0) {
        // Input
        return sysfs_write_file(direction_path, "in", 0);
    } else {
        // Output
        if (pin->config.initial_value < 0) {
            // Output, don't set
            if (current_is_output)
                return 0;
            else
                return sysfs_write_file(direction_path, "out", 0);
        } else if (pin->config.initial_value == 0) {
            // Set as output and initialize low
            return sysfs_write_file(direction_path, "low", 0);
        } else {
            // Set as output and initialize high
            return sysfs_write_file(direction_path, "high", 0);
        }
    }
}

int hal_apply_pull_mode(struct gpio_pin *pin)
{
    if (pin->config.pull == PULL_NOT_SET)
        return 0;

    // Setting the pull mode is platform-specific, so delegate.
    int rc = -1;
#ifdef TARGET_RPI
    rc = rpi_apply_pull_mode(pin);
#endif

    return rc;
}