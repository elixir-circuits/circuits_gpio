# Changelog

## v2.0.0-pre.3 - 2024-1-1

* Changes
  * Add Circuits.GPIO.line_info/2 to simplify getting information about a GPIO
  * Add consumer information to the line information and change the label to
    just be the label rather than a tuple that contains the controller. This
    matches better to what would normally be passed to `Circuits.GPIO.open/3`
  * Add more information to the diagnostics report to simplify debugging
  * Add a read performance measurement to the diagnostics report

## v2.0.0-pre.2 - 2023-12-30

* Changes
  * Fix Beaglebone workaround issues
  * Add Circuits.GPIO version to diagnostics and simplify

## v2.0.0-pre.1 - 2023-12-29

This is a major update over pre.0 that has a significant upgrade to the backend
for Nerves and Linux users.

* Changes
  * Replace the Linux sysfs backend with one that uses the Linux cdev interface
  * Add workaround for reordering of GPIO controllers on Beaglebones with Linux
    5.15 and later.
  * Add `Circuits.GPIO.Diagnostics` to simplify testing runtime capabilities
  * Support pull modes on all targets that support them instead of only
    Raspberry Pis
  * Many documentation updates

## v2.0.0-pre.0 - 2023-05-30

This is a major update to Circuits.GPIO that removes the requirement to use
Nerves or Linux. The API is almost the same and the default is to compile and
use the Linux backend, so changes may not be needed.

This is a prerelease so APIs may still change before the v2.0.0 release.

* Changes
  * Support alternative backends for different operating systems or for
    simulated hardware
  * Defer loading the Linux NIF until `Circuits.GPIO.open/2` is called

## v1.1.0 - 2022-12-31

* Changes
  * Remove Erlang convenience functions since no one used them
  * Require Elixir 1.10 or later. Previous versions probably work, but won't be
    supported. This opens up the possibility of using Elixir 1.10+ features in
    future releases.

## v1.0.1 - 2022-7-26

* Bug fixes
  * On at least one device, the pin direction reported by Linux does not match
    the actual pin direction. This release forces the pin direction for inputs.
    It cannot do this for outputs, since setting a pin to output has a side
    effect on the pin state. This technically is a bug in a Linux driver port,
    but it was harmless to workaround for inputs so that's what's done. Thanks
    to @pojiro for investigating and fixing this issue.

## v1.0.0 - 2021-10-20

This release only changes the version number. No code has changed.

## v0.4.8

This release only has doc and build output cleanup. No code has changed.

## v0.4.7

* Bug fixes
  * Fix hang when unloading the NIF. This bug caused `:init.stop` to never
    return and anything else that would try to unload this module.
  * Fix C compiler warnings with OTP 24

The minimum Elixir version has been changed from 1.4 to 1.6. Elixir 1.4 might
still work, but it's no longer being verified on CI.

## v0.4.6

* Bug fixes
  * Fix quoting issue that was causing failures on Yocto. Thanks to Zander
    Erasmus for this.

## v0.4.5

* Bug fixes
  * Opening a GPIO to read its state won't clear the interrupt status of another
    listener. Registering for interrupts a second time will still clear out the
    first registree, though. That's a limitation of the interface. However, for
    debugging, it can be nice to look at a GPIO without affecting the program
    and this change allows for that.

## v0.4.4

* Bug fixes
  * Add -fPIC to compilation flags to fix build with `nerves_system_x86_64` and
    other environments using the Musl C toolchains

## v0.4.3

* Bug fixes
  * Fix GPIO glitch suppression when interrupts were enabled. Glitch suppression
    filters out transitions on a GPIO line that are too fast for Linux and the
    NIF to see both the rising and falling edges. Turning it off synthesizes
    events. You can identify synthesized events since they have the same
    timestamp to the nanosecond. See `Circuits.GPIO.set_interrupts/3`.

* Improvement
  * It's possible to enable the "stub" on Linux by setting
    `CIRCUITS_MIX_ENV=test`. This can be useful for unit testing code that uses
    Circuits.GPIO. Thanks to Enrico Rivarola for adding this!

## v0.4.2

* Bug fixes
  * Fix pullup/pulldown support for the Raspberry Pi 4

## v0.4.1

* Bug fixes
  * Fix a race condition on Raspbian where Circuits.GPIO would try to open the
    GPIO sysfs file before udev had a chance to fix its permissions.
  * Fix RPi platform detection on Raspbian so that pull-ups/pull-downs work
    without passing any flags.

## v0.4.0

The GPIO interrupt notification messages have been changed for consistency with
other circuits projects. The initial element of the tuple is now
`:circuits_gpio`, so messages will look like:

`{:circuits_gpio, 19, 83268239, 1}`

Please update your project if you call `set_interrupts/2`.

No more backwards incompatible changes are expected until after 1.0.

## v0.3.1

* Bug fixes
  * Build C source under the `_build` directory so that changing targets
    properly rebuilds the C code as well as the Elixir.

## v0.3.0

* New features
  * Support `pull_mode` initializion in `open/3`.

## v0.2.0

* New features
  * Add support for opening GPIOs to an initial value or to not change the
    value. This removes a glitch if you want the GPIO to start out high (the
    default was low) or if you want the GPIO to keep its current value.

## v0.1.0

Initial release to hex.
