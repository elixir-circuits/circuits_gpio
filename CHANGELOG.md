# Changelog

## v2.1.2 - 2024-09-08

* Bug fixes
  * Fix compilation when Erlang has been installed to a directory with spaces

## v2.1.1 - 2024-08-19

* Changes
  * Show if GPIO number remapping is happening for AM335x platforms via
    `backend_info/0`.
  * Drop support for Elixir 1.11 and 1.12.

## v2.1.0 - 2024-04-08

* Changes
  * Show backend options via `backend_info/0` so that it's possible to see
    whether you're using CDev test mode or not.

  ```elixir
  iex> Circuits.GPIO.backend_info()
  %{name: {Circuits.GPIO.CDev, [test: true]}, pins_open: 0}
  ```

## v2.0.2 - 2024-01-17

* Bug fixes
  * Remove lazy NIF loading. There's an unexplained segfault in a small example
    program that uses the same strategy. Even though it wasn't reproducible
    here, it's not worth the risk. Thanks to @pojiro for investigating.

* Changes
  * Add example Livebook. Thanks to @mnishiguchi.

## v2.0.1 - 2024-01-13

* Bug fixes
  * Fix race condition when loading NIF. If two processes caused the NIF to be
    loaded at the same time, then it was possible for one to return an error.
  * Remove tracking of the number of open pins from the cdev backend to not need
    to synchronize access to the count. This feature really was only used for
    the unit tests.

## v2.0.0 - 2024-01-11

This is a major update to Circuits.GPIO that modernizes the API, restricts usage
to Nerves and Linux, and updates the Linux/Nerves backend to the Linux GPIO cdev
interface.

It is mostly backwards compatible with Circuits.GPIO v1. Please see `PORTING.md`
for upgrade instructions.

* New features
  * Support alternative backends for different operating systems or for
    simulated hardware. The Linux cdev backend can be compiled out.

  * `Circuits.GPIO.open/3` is much more flexible in how GPIOs are identified.
    Specifying GPIOs by number still works, but it's now possible to specify
    GPIOs by string labels and by tuples that contain the GPIO controller name
    and index. See `t:gpio_spec/0` and the `README.md` for details.

  * List out available GPIOs with `Circuits.GPIO.enumerate/0`. Other helper
    functions are available for getting more information about each GPIO too.

  * Specify pull modes in general rather than only Raspberry Pis on Linux and
    Nerves

  * Easily do one-off reads and writes with `Circuits.GPIO.read_one/2` and
    `Circuits.GPIO.write_one/3`

  * Improved performance on Nerves and Linux; kernel-applied timestamping of
    GPIO input events

  * Add `Circuits.GPIO.Diagnostics` to automate runtime testing

* Changes
  * More consistent error returns. Unexpected errors return `{:errno, value}`
    tuples to help correlate errors to low level docs
  * Deferred loading of the NIF to simplify debugging of GPIO backends.
    Segfaults crash on first use of `Circuits.GPIO` rather than on load.

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
  * Support `pull_mode` initialization in `open/3`.

## v0.2.0

* New features
  * Add support for opening GPIOs to an initial value or to not change the
    value. This removes a glitch if you want the GPIO to start out high (the
    default was low) or if you want the GPIO to keep its current value.

## v0.1.0

Initial release to hex.
