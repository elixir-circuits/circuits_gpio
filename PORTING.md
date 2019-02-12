# Porting Elixir/ALE to Circuits.GPIO

The `Circuits.GPIO` package is the next version of Elixir/ALE's GPIO support.
If you're currently using Elixir/ALE, you're encouraged to switch. Here are some
benefits:

1. Supported by both the maintainer of Elixir/ALE and a couple others. They'd
   prefer to support `Circuits.GPIO` issues.
2. Much faster than Elixir/ALE - like it's not even close. The guideline is
   still to use GPIOs for buttons, LEDs, and other low frequency devices and use
   specialized device drivers for the rest. However, we know that's not always easy
   and the extra performance is really nice to have.
3. Included pull up/pull down support for Raspberry Pi. We'd like to include
   this for other platforms as well. This was the single-most requested feature
   for Elixir/ALE.
4. Timestamped interrupt reports - This is makes it possible to measure time
   deltas between GPIO changes with higher accuracy by removing variability from
   messages sitting in queues and passing between processes
5. Interrupt glitch detection  - When the GPIO toggles faster than
   `Circuits.GPIO` can handle, it can either synthesize an interrupt event or
   suppress the event.
6. Lower resource usage - Elixir/ALE created a GenServer and OS process for each
   GPIO. `Circuits.GPIO` creates a NIF resource (Elixir Reference) for each
   GPIO.

`Circuits.GPIO` uses Erlang's NIF interface. NIFs have the downside of being
able to crash the Erlang VM. Experience with Elixir/ALE has given many of us
confidence that this won't be a problem.

## Code modifications

`Circuits.GPIO` is not a `GenServer`, so if you've added `ElixirALE.GPIO` to a
supervision tree, you'll have to take it out and manually call
`Circuits.GPIO.open` to obtain a reference. A common pattern is to create a
`GenServer` that wraps the GPIO and is descriptive of what the GPIO controls or
signals. Put the `Circuits.GPIO.open` call in your `init/1` callback.

The remain modifications should mostly be mechanical:

1. Rename references to `ElixirALE.GPIO` to `Circuits.GPIO` and `elixir_ale`
   to `circuits_gpio`
2. Change calls to `ElixirALE.GPIO.start_link/2` to `Circuits.GPIO.open/2`.
   While you're at it, review the arguments to open to not include any
   `GenServer` options.
3. Change calls to `ElixirALE.GPIO.set_int/2` to
   `Circuits.GPIO.set_interrupts/3`.
4. Change the pattern match for the GPIO interrupt events to match 4 tuples.
   They have the form `{:circuits_gpio, <pin_number>, <timestamp>, <value>}`
5. Review calls to `write/2` to ensure that they pass `0` or `1`. `ElixirALE`
   allowed users to pass `true` and `false`. That won't work. Running Dialyzer
   should catch this change as well.
6. Consider adding a call to `Circuits.GPIO.close/1` if there's an obvious place
   to release the GPIO. This is not strictly necessary since the garbage
   collector will free unreferenced GPIOs.

If you find that you have to make any other changes, please let us know via an
issue or PR so that other users can benefit.
