# Changelog

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
