# Circuits - GPIO

[![Hex version](https://img.shields.io/hexpm/v/circuits_gpio2.svg "Hex version")](https://hex.pm/packages/circuits_gpio2)
[![API docs](https://img.shields.io/hexpm/v/circuits_gpio2.svg?label=hexdocs "API docs")](https://hexdocs.pm/circuits_gpio2/Circuits.GPIO2.html)
[![CircleCI](https://circleci.com/gh/elixir-circuits/circuits_gpio2.svg?style=svg)](https://circleci.com/gh/elixir-circuits/circuits_gpio2)
[![REUSE status](https://api.reuse.software/badge/github.com/elixir-circuits/circuits_gpio2)](https://api.reuse.software/info/github.com/elixir-circuits/circuits_gpio2)

`Circuits.GPIO2` lets you use GPIOs in Elixir.

*This is the v2.0 development branch. It's not ready yet. Most users will want
to follow the [maint-v1.x branch](https://github.com/elixir-circuits/circuits_gpio2/tree/maint-v1.x).*

`Circuits.GPIO2` v2.0  is an almost backwards compatible update to `Circuits.GPIO2`
v1.x. Here's what's new:

* Linux or Nerves are no longer required. In fact, the NIF supporting them won't
  be compiled if you don't want it.
* Develop using simulated GPIOs to work with LEDs and buttons with
  [CircuitsSim](https://github.com/elixir-circuits/circuits_sim)

If you've used `Circuits.GPIO2` v1.x, nearly all of your code will be the same. If
you're a library author, we'd appreciate if you could try this out and update
your `:circuits_gpio2` dependency to allow v2.0. Details can be found in our
[porting guide](PORTING.md).

## Getting started on Nerves and Linux

If you're natively compiling `circuits_gpio2` on a Raspberry Pi or using Nerves,
everything should work like any other Elixir library. Normally, you would
include `circuits_gpio2` as a dependency in your `mix.exs` like this:

```elixir
def deps do
  [{:circuits_gpio2, "~> 2.0"}]
end
```

One common error on Raspbian is that the Erlang headers are missing (`ie.h`),
you may need to install erlang with `apt-get install erlang-dev` or build Erlang
from source per instructions [here](http://elinux.org/Erlang).

## Examples

`Circuits.GPIO2` only supports simple uses of the GPIO interface in Linux, but
you can still do quite a bit. The following examples were tested on a Raspberry
Pi that was connected to an [Erlang Embedded Demo
Board](http://solderpad.com/omerk/erlhwdemo/). There's nothing special about
either the demo board or the Raspberry Pi, so these should work similarly on
other embedded Linux platforms.

## GPIO

A [General Purpose
Input/Output](https://en.wikipedia.org/wiki/General-purpose_input/output) (GPIO)
is just a wire that you can use as an input or an output. It can only be one of
two values, 0 or 1. A 1 corresponds to a logic high voltage like 3.3 V and a 0
corresponds to 0 V. The actual voltage depends on the hardware.

Here's an example of turning an LED on or off:

![GPIO LED schematic](assets/images/schematic-gpio-led.png)

To turn on the LED that's connected to the net (or wire) labeled `GPIO18`, run
the following:

```elixir
iex> {:ok, gpio} = Circuits.GPIO2.open(18, :output)
{:ok, #Reference<...>}

iex> Circuits.GPIO2.write(gpio, 1)
:ok

iex> Circuits.GPIO2.close(gpio)
:ok
```

_Note that the call to `Circuits.GPIO2.close/1` is not necessary, as the garbage
collector will free up any unreferenced GPIOs. It can be used to explicitly
de-allocate connections you know you will not need anymore._

Input works similarly. Here's an example of a button with a pull down resistor
connected.

![GPIO Button schematic](assets/images/schematic-gpio-button.png)

If you're not familiar with pull up or pull down resistors, they're resistors
whose purpose is to drive a wire high or low when the button isn't pressed. In
this case, it drives the wire low. Many processors have ways of configuring
internal resistors to accomplish the same effect without needing to add an
external resistor. If you're using a Raspberry Pi, you can use [the built-in
pull-up/pull-down resistors](#internal-pull-uppull-down).

The code looks like this in `Circuits.GPIO2`:

```elixir
iex> {:ok, gpio} = Circuits.GPIO2.open(17, :input)
{:ok, #Reference<...>}

iex> Circuits.GPIO2.read(gpio)
0

# Push the button down

iex> Circuits.GPIO2.read(gpio)
1
```

If you'd like to get a message when the button is pressed or released, call the
`set_interrupts` function. You can trigger on the `:rising` edge, `:falling` edge
or `:both`.

```elixir
iex> Circuits.GPIO2.set_interrupts(gpio, :both)
:ok

iex> flush
{:circuits_gpio2, 17, 1233456, 1}
{:circuits_gpio2, 17, 1234567, 0}
:ok
```

Note that after calling `set_interrupts`, the calling process will receive an
initial message with the state of the pin. This prevents the race condition
between getting the initial state of the pin and turning on interrupts. Without
it, you could get the state of the pin, it could change states, and then you
could start waiting on it for interrupts. If that happened, you would be out of
sync.

### Internal pull-up/pull-down

To connect or disconnect an internal [pull-up or pull-down resistor](https://github.com/raspberrypilearning/physical-computing-guide/blob/master/pull_up_down.md) to a GPIO
pin, call the `set_pull_mode` function.

```elixir
iex> Circuits.GPIO2.set_pull_mode(gpio, pull_mode)
:ok
```

Valid `pull_mode` values are `:none` `:pullup`, or `:pulldown`

Note that `set_pull_mode` is platform dependent, and currently only works for
Raspberry Pi hardware.  Calls to `set_pull_mode` on other platforms will have no
effect.  The internal pull-up resistor value is between 50K and 65K, and the
pull-down is between 50K and 60K.  It is not possible to read back the current
Pull-up/down settings, and GPIO pull-up pull-down resistor connections are
maintained, even when the CPU is powered down.

To get the GPIO pin number for a gpio reference, call the `pin` function.

```elixir
iex> Circuits.GPIO2.pin(gpio)
17
```

## Enumeration

`Circuits.GPIO2` v2.0 supports a new function, `enumerate/0`. which will list out every pin that Linux knows about via the gpio-cdev subsystem. See
the [Official DeviceTree documentation for GPIOs](https://elixir.bootlin.com/linux/v6.6.6/source/Documentation/devicetree/bindings/gpio/gpio.txt) for more
information on how to configure the fields of this struct for your own system.

```elixir
iex> Circuits.GPIO2.enumerate()
[
  %Circuits.GPIO2.Line{line_spec: {"gpiochip0", 0}, label: "special-name-for-pin-0", controller: "gpiochip0"},
  %Circuits.GPIO2.Line{line_spec: {"gpiochip0", 1}, label: "special-name-for-pin-1", controller: "gpiochip0"},
  %Circuits.GPIO2.Line{line_spec: {"gpiochip1", 0}, label: "", controller: "gpiochip1"},
  ...
]
```

## Pin Specs

`Circuits.GPIO2` V2.0 supports a new form of specifying how to open a pin called a `Spec`. These specs are based on the *newer* gpio-cdev subsystem
in Linux. Notably, they include the concept of `gpiochips` and `lines``, both of which are used internally to provide pin numbers for the *older* pin numbering scheme.
Specs are a tuple of a `gpiochip` and a `line`. The gpiochip may be provided as either a label for a chip if configured by your platform, or as it's name as listed
in `/dev`. 

```elixir
iex> {:ok, ref} = Circuits.GPIO2.open({"gpiochip0", 1}, :input)
{:ok, #Reference<...>}
```

The spec `line` may also be provided as a label if configured for your platform:

```elixir
iex> {:ok, ref} = Circuits.GPIO2.open({"gpiochip0", "special-name-for-pin-0"})
{:ok, #Reference<...>}
```

Additionally, if the label for a pin is unique, that label may be provided without a gpiochip in the spec.
If the label is *not* unique, the first line matching that name will be opened.

```elixir
iex> {:ok, ref} = Circuits.GPIO2.open("special-name-for-pin-0")
{:ok, #Reference<...>}
```

See [Enumeration](#enumeration) for listing out all available pin specs for your device.

## Testing

`Circuits.GPIO2` supports a "stub" hardware abstraction layer on platforms
without GPIO support and when `MIX_ENV=test`. The stub allows for some
limited unit testing without real hardware.

To use it, first check that you're using the "stub" HAL:

```elixir
iex> Circuits.GPIO2.info
%{name: :stub, pins_open: 0}
```

The stub HAL has 64 GPIOs. Each pair of GPIOs is connected. For example,
GPIO 0 is connected to GPIO 1. If you open GPIO 0 as an output and
GPIO 1 as an input, you can write to GPIO 0 and see the result on GPIO 1.
Here's an example:

```elixir
iex> {:ok, gpio0} = Circuits.GPIO2.open(0, :output)
{:ok, #Reference<0.801050056.3201171470.249048>}
iex> {:ok, gpio1} = Circuits.GPIO2.open(1, :input)
{:ok, #Reference<0.801050056.3201171470.249052>}
iex> Circuits.GPIO2.read(gpio1)
0
iex> Circuits.GPIO2.write(gpio0, 1)
:ok
iex> Circuits.GPIO2.read(gpio1)
1
```

The stub HAL is fairly limited, but it does support interrupts.

If `Circuits.GPIO2` is used as a dependency the stub may not be present. To
manually enable it, set `CIRCUITS_MIX_ENV` to `test` and rebuild
`circuits_gpio2`.

## FAQ

### Where can I get help?

Most issues people have are on how to communicate with hardware for the first
time. Since `Circuits.GPIO2` is a thin wrapper on the Linux CDev GPIO interface,
you may find help by searching for similar issues when using Python or C.

For help specifically with `Circuits.GPIO2`, you may also find help on the nerves
channel on the [elixir-lang Slack](https://elixir-lang.slack.com/).  Many
[Nerves](http://nerves-project.org) users also use `Circuits.GPIO2`.

### I tried turning on and off a GPIO as fast as I could. Why was it slow?

Please don't do that - there are so many better ways of accomplishing whatever
you're trying to do:

1. If you're trying to drive a servo or dim an LED, look into PWM. Many
   platforms have PWM hardware and you won't tax your CPU at all. If your
   platform is missing a PWM, several chips are available that take I2C commands
   to drive a PWM output.
2. If you need to implement a wire level protocol to talk to a device, look for
   a Linux kernel driver. It may just be a matter of loading the right kernel
   module.
3. If you want a blinking LED to indicate status, `gpio` really should
   be fast enough to do that, but check out Linux's LED class interface. Linux
   can flash LEDs, trigger off events and more. See [nerves_leds](https://github.com/nerves-project/nerves_leds).

If you're still intent on optimizing GPIO access, you may be interested in
[gpio_twiddler](https://github.com/fhunleth/gpio_twiddler).

### Can I develop code that uses GPIO on my laptop?

The intended way to support this is to have a custom `Circuits.GPIO2.Backend`
that runs on your laptop. The
[CircuitsSim](https://github.com/elixir-circuits/circuits_sim) is an example of
a project that provides simulated LEDs and buttons.

## License

All original source code in this project is licensed under Apache-2.0.

Additionally, this project follows the [REUSE recommendations](https://reuse.software)
and labels so that licensing and copyright are clear at the file level.

Exceptions to Apache-2.0 licensing are:

* Configuration and data files are licensed under CC0-1.0
* Documentation files are CC-BY-4.0
* Erlang Embedded board images are Solderpad Hardware License v0.51.
