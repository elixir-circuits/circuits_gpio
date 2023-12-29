# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2 do
  @moduledoc """
  Control GPIOs from Elixir

  If you're coming from Elixir/ALE, check out our [porting guide](PORTING.md).

  `Circuits.GPIO2` works great with LEDs, buttons, many kinds of sensors, and
  simple control of motors. In general, if a device requires high speed
  transactions or has hard real-time constraints in its interactions, this is not
  the right library. For those devices, see if there's a Linux kernel driver.
  """
  alias Circuits.GPIO2.Handle

  @typedoc """
  Backends specify an implementation of a Circuits.GPIO2.Backend behaviour

  The second parameter of the Backend 2-tuple is a list of options. These are
  passed to the behaviour function call implementations.
  """
  @type backend() :: {module(), keyword()}

  @typedoc """
  GPIO controller

  GPIO controllers manage one or more GPIO lines. They're referred to
  by strings. For example, you'll mostly see `"gpiochip0"`, etc. but
  they could be anything or even empty strings there's no reason to
  differentiate controllers on a device.
  """
  @type controller() :: String.t()

  @typedoc """
  GPIO line offset on a controller

  GPIOs are numbered based on how they're connected to a controller. The
  details are controller specific, but usually the first one is `0`, then `1`, etc.
  """
  @type line_offset() :: non_neg_integer()

  @typedoc """
  A GPIO controller or line label

  Labels provide aliases for GPIO lines and controllers. They're system-specific.
  On Linux, labels are provided in device tree files.
  """
  @type label() :: String.t()

  @typedoc """
  An identifier for a GPIO line

  Call `Circuits.GPIO.enumerate/0` to see what GPIOs are available on your device. Several
  ways exist to refer to GPIOs due to variations in devices and programmer preference.

  Options:

  1. `index` - Many examples exist where GPIOs are referred to by a GPIO number. There are issues
     with this strategy since GPIO indices can change. It is so common that it's still supported. Prefer other ways when
     you're able to change code.
  2. `{controller, line_offset}` - Specify a line on a specific GPIO controller. E.g., `{"gpiochip0", 10}`
  3. `label` - Specify a GPIO line label. The first controller that has a matching line is used. This lets
     you move the mapping of GPIOs to peripheral connections to a device tree file or other central place. E.g., `"LED_ENABLE"`
  4. `{label, label}` - Specify both GPIO controller and line labels. E.g., `{"primary-gpios", "PIO4"}`
  """
  @type line_spec() ::
          non_neg_integer() | {controller(), line_offset()} | label() | {label(), label()}

  @typedoc "The GPIO direction (input or output)"
  @type line_direction() :: :input | :output

  @typedoc "GPIO logic value (low = 0 or high = 1)"
  @type value() :: 0 | 1

  @typedoc "Trigger edge for pin change notifications"
  @type trigger() :: :rising | :falling | :both | :none

  @typedoc "Pull mode for platforms that support controllable pullups and pulldowns"
  @type pull_mode() :: :not_set | :none | :pullup | :pulldown

  @typedoc """
  Options for `open/3`
  """
  @type open_options() :: [initial_value: value() | :not_set, pull_mode: pull_mode()]

  @typedoc """
  Options for `set_interrupt/2`
  """
  @type interrupt_options() :: [suppress_glitches: boolean(), receiver: pid() | atom()]

  # Public API

  @doc """
  Open a GPIO for use.

  `pin` should be a valid GPIO pin number on the system and `line_direction`
  should be `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option if you need the set to be glitch free.

  Options:

  * :initial_value - Set to `:not_set`, `0` or `1` if this is an output.
    `:not_set` is the default.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.
  """
  @spec open(line_spec(), line_direction(), open_options()) ::
          {:ok, Handle.t()} | {:error, atom()}
  def open(pin_number, line_direction, options \\ []) do
    check_options!(options)

    {backend, backend_defaults} = default_backend()

    all_options =
      backend_defaults
      |> Keyword.merge(options)
      |> Keyword.put_new(:initial_value, :not_set)
      |> Keyword.put_new(:pull_mode, :not_set)

    backend.open(pin_number, line_direction, all_options)
  end

  defp check_options!([]), do: :ok

  defp check_options!([{:initial_value, value} | rest]) do
    unless value in [:not_set, 0, 1],
      do: raise(ArgumentError, ":initial_value should be :not_set, 0, or 1")

    check_options!(rest)
  end

  defp check_options!([{:pull_mode, value} | rest]) do
    unless value in [:not_set, :pullup, :pulldown, :none],
      do: raise(ArgumentError, ":pull_mode should be :not_set, :pullup, :pulldown, or :none")

    check_options!(rest)
  end

  defp check_options!([_unknown_option | rest]) do
    # Ignore unknown options - the backend might use them
    check_options!(rest)
  end

  @doc """
  Release the resources associated with the GPIO.

  This is optional. The garbage collector will free GPIO resources that aren't in
  use, but this will free them sooner.
  """
  @spec close(Handle.t()) :: :ok
  defdelegate close(handle), to: Handle

  @doc """
  Read the current value on a pin.
  """
  @spec read(Handle.t()) :: value()
  defdelegate read(handle), to: Handle

  @doc """
  Set the value of a pin. The pin should be configured to an output
  for this to work.
  """
  @spec write(Handle.t(), value()) :: :ok
  defdelegate write(handle, value), to: Handle

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
  {:circuits_gpio2, pin_number, timestamp, value}
  ```

  Where `pin_number` is the pin that changed values, `timestamp` is roughly when
  the transition occurred in nanoseconds since host system boot time,
  and `value` is the new value.

  NOTE: You will need to store the `Circuits.GPIO2` reference somewhere (like
  your `GenServer`'s state) so that it doesn't get garbage collected. Event
  messages stop when it gets collected. If you only get one message and you are
  expecting more, this is likely the case.
  """
  @spec set_interrupts(Handle.t(), trigger(), interrupt_options()) :: :ok | {:error, atom()}
  defdelegate set_interrupts(handle, trigger, options \\ []), to: Handle

  @doc """
  Change the direction of the pin.
  """
  @spec set_direction(Handle.t(), line_direction()) :: :ok | {:error, atom()}
  defdelegate set_direction(handle, line_direction), to: Handle

  @doc """
  Enable or disable internal pull-up or pull-down resistor to GPIO pin
  """
  @spec set_pull_mode(Handle.t(), pull_mode()) :: :ok | {:error, atom()}
  defdelegate set_pull_mode(gpio, pull_mode), to: Handle

  @doc """
  Get the GPIO pin number
  """
  @spec pin(Handle.t()) :: line_spec()
  def pin(handle) do
    info = Handle.info(handle)
    info.line_spec
  end

  @doc """
  Return info about the low level GPIO interface

  This may be helpful when debugging issues.
  """
  @spec info(backend() | nil) :: map()
  def info(backend \\ nil)

  def info(nil), do: info(default_backend())
  def info({backend, _options}), do: backend.info()

  defp default_backend() do
    case Application.get_env(:circuits_gpio2, :default_backend) do
      nil -> {Circuits.GPIO2.NilBackend, []}
      m when is_atom(m) -> {m, []}
      {m, o} = value when is_atom(m) and is_list(o) -> value
    end
  end
end
