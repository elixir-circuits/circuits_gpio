# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO do
  @moduledoc """
  Control GPIOs from Elixir

  If you're coming from Elixir/ALE, check out our [porting guide](PORTING.md).

  `Circuits.GPIO` works great with LEDs, buttons, many kinds of sensors, and
  simple control of motors. In general, if a device requires high speed
  transactions or has hard real-time constraints in its interactions, this is not
  the right library. For those devices, see if there's a Linux kernel driver.
  """
  alias Circuits.GPIO.Nif

  @typedoc "A GPIO pin number. See your device's documentation for how these connect to wires"
  @type pin_number :: non_neg_integer()

  @typedoc "The GPIO direction (input or output)"
  @type pin_direction :: :input | :output

  @typedoc "GPIO logic value (low = 0 or high = 1)"
  @type value :: 0 | 1

  @typedoc "Trigger edge for pin change notifications"
  @type trigger :: :rising | :falling | :both | :none

  @typedoc "Pull mode for platforms that support controllable pullups and pulldowns"
  @type pull_mode :: :not_set | :none | :pullup | :pulldown

  @typedoc "Options for open/3"
  @type open_option :: {:initial_value, value() | :not_set} | {:pull_mode, pull_mode()}

  # Public API

  @doc """
  Open a GPIO for use.

  `pin` should be a valid GPIO pin number on the system and `pin_direction`
  should be `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option if you need the set to be glitch free.

  Options:

  * :initial_value - Set to `:not_set`, `0` or `1` if this is an output.
    `:not_set` is the default.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.
  """
  @spec open(pin_number(), pin_direction(), [open_option()]) ::
          {:ok, reference()} | {:error, atom()}
  def open(pin_number, pin_direction, options \\ []) do
    check_open_options(options)

    value = Keyword.get(options, :initial_value, :not_set)
    pull_mode = Keyword.get(options, :pull_mode, :not_set)

    Nif.open(pin_number, pin_direction, value, pull_mode)
  end

  defp check_open_options([]), do: :ok

  defp check_open_options([{:initial_value, value} | rest]) when value in [:not_set, 0, 1] do
    check_open_options(rest)
  end

  defp check_open_options([{:pull_mode, value} | rest])
       when value in [:not_set, :pullup, :pulldown, :none] do
    check_open_options(rest)
  end

  defp check_open_options([bad_option | _]) do
    raise ArgumentError.exception("Unsupported option to GPIO.open/3: #{inspect(bad_option)}")
  end

  @doc """
  Release the resources associated with the GPIO.

  This is optional. The garbage collector will free GPIO resources that aren't in
  use, but this will free them sooner.
  """
  @spec close(reference()) :: :ok
  def close(gpio) do
    Nif.close(gpio)
  end

  @doc """
  Read the current value on a pin.
  """
  @spec read(reference()) :: value()
  def read(gpio) do
    Nif.read(gpio)
  end

  @doc """
  Set the value of a pin. The pin should be configured to an output
  for this to work.
  """
  @spec write(reference(), value()) :: :ok
  def write(gpio, value) do
    Nif.write(gpio, value)
  end

  @doc """
  Enable or disable pin value change notifications. The notifications
  are sent based on the trigger parameter:

  * :none - No notifications are sent
  * :rising - Send a notification when the pin changes from 0 to 1
  * :falling - Send a notification when the pin changes from 1 to 0
  * :both - Send a notification on all changes

  Available Options:
  * `suppress_glitches` - It is possible that the pin transitions to a value
  and back by the time that Circuits GPIO gets to process it. This controls
  whether a notification is sent. Set this to `false` to receive notifications.
  * `receiver` - Process which should receive the notifications.
  Defaults to the calling process (`self()`)

  Notifications look like:

  ```
  {:circuits_gpio, pin_number, timestamp, value}
  ```

  Where `pin_number` is the pin that changed values, `timestamp` is roughly when
  the transition occurred in nanoseconds since host system boot time,
  and `value` is the new value.

  NOTE: You will need to store the `Circuits.GPIO` reference somewhere (like
  your `GenServer`'s state) so that it doesn't get garbage collected. Event
  messages stop when it gets collected. If you only get one message and you are
  expecting more, this is likely the case.
  """
  @spec set_interrupts(reference(), trigger(), list()) :: :ok | {:error, atom()}
  def set_interrupts(gpio, trigger, opts \\ []) do
    suppress_glitches = Keyword.get(opts, :suppress_glitches, true)

    receiver =
      case Keyword.get(opts, :receiver) do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name) || self()
        _ -> self()
      end

    Nif.set_interrupts(gpio, trigger, suppress_glitches, receiver)
  end

  @doc """
  Change the direction of the pin.
  """
  @spec set_direction(reference(), pin_direction()) :: :ok | {:error, atom()}
  def set_direction(gpio, pin_direction) do
    Nif.set_direction(gpio, pin_direction)
  end

  @doc """
  Enable or disable internal pull-up or pull-down resistor to GPIO pin
  """
  @spec set_pull_mode(reference(), pull_mode()) :: :ok | {:error, atom()}
  def set_pull_mode(gpio, pull_mode) do
    Nif.set_pull_mode(gpio, pull_mode)
  end

  @doc """
  Get the GPIO pin number
  """
  @spec pin(reference) :: pin_number
  def pin(gpio) do
    Nif.pin(gpio)
  end

  @doc """
  Return info about the low level GPIO interface

  This may be helpful when debugging issues.
  """
  @spec info() :: map()
  defdelegate info(), to: Nif
end
