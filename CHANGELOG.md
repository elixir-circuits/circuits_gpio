# Changelog

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
