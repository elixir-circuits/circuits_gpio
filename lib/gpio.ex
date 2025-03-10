# SPDX-FileCopyrightText: 2014 Frank Hunleth
# SPDX-FileCopyrightText: 2016 Justin Schneck
# SPDX-FileCopyrightText: 2017 Giovanni Visciano
# SPDX-FileCopyrightText: 2017 Tim Mecklem
# SPDX-FileCopyrightText: 2018 Jon Carstens
# SPDX-FileCopyrightText: 2018 Mark Sebald
# SPDX-FileCopyrightText: 2018 Matt Ludwigs
# SPDX-FileCopyrightText: 2019 Michael Roach
# SPDX-FileCopyrightText: 2023 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO do
  @moduledoc """
  Control GPIOs from Elixir

  See the [Readme](README.md) for a tutorial and the [porting guide](PORTING.md)
  if updating from Circuits.GPIO v1.x.

  Simple example:

  ```elixir
  # GPIO 2 is connected to GPIO 3
  iex> {:ok, my_output_gpio} = Circuits.GPIO.open({"gpiochip0", 2}, :output)
  iex> {:ok, my_input_gpio} = Circuits.GPIO.open({"gpiochip0", 3}, :input)
  iex> Circuits.GPIO.write(my_output_gpio, 1)
  :ok
  iex> Circuits.GPIO.read(my_input_gpio)
  1
  iex> Circuits.GPIO.close(my_output_gpio)
  iex> Circuits.GPIO.close(my_input_gpio)
  ```
  """
  alias Circuits.GPIO.Handle

  require Logger

  @typedoc """
  Backends specify an implementation of a Circuits.GPIO.Backend behaviour

  The second parameter of the Backend 2-tuple is a list of options. These are
  passed to the behaviour function call implementations.
  """
  @type backend() :: {module(), keyword()}

  @typedoc """
  GPIO controller

  GPIO controllers manage one or more GPIO lines. They're referred to by
  strings. For example, controllers are named `"gpiochip0"`, etc. for the
  Linux cdev backend. Other backends may have similar conventions or use
  the empty string if there's only one controller.
  """
  @type controller() :: String.t()

  @typedoc """
  GPIO line offset on a controller

  GPIOs are numbered based on how they're connected to a controller. The
  details are controller specific, but usually the first one is `0`, then `1`,
  etc.
  """
  @type line_offset() :: non_neg_integer()

  @typedoc """
  A GPIO controller label or GPIO label

  Labels provide aliases for GPIO lines and controllers. They're
  system-specific. On Linux, labels are provided in device tree files.
  """
  @type label() :: String.t()

  @typedoc """
  An identifier for a GPIO

  Call `Circuits.GPIO.enumerate/0` to see what GPIOs are available on your
  device. Several ways exist to refer to GPIOs due to variations in devices and
  programmer preference. Most Raspberry Pi models have labels like `"GPIO26"`.
  The Raspberry Pi 5 has labels based on physical location (e.g., `"PIN37"` for
  GPIO 26.)

  Options:

  1. `index` - Many examples exist where GPIOs are referred to by a GPIO
     number. There are issues with this strategy since GPIO indices can change.
     It is so common that it's still supported. Prefer other ways when you're
     able to change code.
  2. `{controller_name, line_offset}` - Specify a line on a specific GPIO
     controller. E.g., `{"gpiochip0", 10}`
  3. `label` - Specify a GPIO label. The first controller that has a
     matching GPIO is used. This lets you move the mapping of GPIOs to
     peripheral connections to a device tree file or other central place. E.g.,
     `"LED_ENABLE"`
  4. `{controller_name, label}` - Specify both GPIO controller and GPIO labels.
     E.g., `{"gpiochip4", "PIO4"}`
  """
  @type gpio_spec() ::
          non_neg_integer() | {controller(), line_offset()} | label() | {controller(), label()}

  @typedoc "The GPIO direction (input or output)"
  @type direction() :: :input | :output

  @typedoc "GPIO logic value (low = 0 or high = 1)"
  @type value() :: 0 | 1

  @typedoc "Trigger edge for pin change notifications"
  @type trigger() :: :rising | :falling | :both | :none

  @typedoc "Pull mode for platforms that support controllable pullups and pulldowns"
  @type pull_mode() :: :not_set | :none | :pullup | :pulldown

  @typedoc """
  Ways of referring to a GPIO

  It's possible to refer to a GPIOs in many ways and this map contains
  information for doing that.  See `enumerate/1` and `identifiers/1` for
  querying `Circuits.GPIO` for these maps.

  The information in this map is backend specific. At a minimum, all backends
  provide the `:location` field which is an unambiguous `t:gpio_spec/0` for use
  with `open/3`.

  When provided, the `:label` field is a string name for the GPIO that should
  be unique to the system but this isn't guaranteed. A common convention is to
  label GPIOs by their pin names in documentation or net names in schematics.
  The Linux cdev backend uses labels from the device tree file.

  Fields:

  * `:location` - this is the canonical gpio_spec for a GPIO.
  * `:label` - an optional label for the GPIO that may indicate what the GPIO is connected to
    or be more helpful that the `:location`. It may be passed to `GPIO.open/3`.
  * `:controller` - the name or an alias for the GPIO controller. Empty string if unused
  """
  @type identifiers() :: %{
          location: {controller(), non_neg_integer()},
          controller: controller(),
          label: label()
        }

  @typedoc """
  Dynamic GPIO configuration and status

  Fields:

  * `:consumer` - if this GPIO is in use, this optional string gives a hint as to who is
    using it.
  * `:direction` - whether this GPIO is an input or output
  * `:pull_mode` - if this GPIO is an input, then this is the pull mode
  """
  @type status() :: %{
          consumer: String.t(),
          direction: direction(),
          pull_mode: pull_mode()
        }

  @typedoc """
  Options for `open/3`

  * `:initial_value` - the initial value of an output GPIO
  * `:pull_mode` - the initial pull mode for an input GPIO
  * `:force_enumeration` - Linux cdev-specific option to force a scan of
    available GPIOs rather than using the cache. This is only for test purposes
    since the GPIO cache should refresh as needed.
  """
  @type open_options() :: [
          initial_value: value(),
          pull_mode: pull_mode(),
          force_enumeration: boolean()
        ]

  @typedoc """
  Options for `set_interrupt/2`
  """
  @type interrupt_options() :: [suppress_glitches: boolean(), receiver: pid() | atom()]

  @doc """
  Guard version of `gpio_spec?/1`

  Add `require Circuits.GPIO` to your source file to use this guard.
  """
  defguard is_gpio_spec(x)
           when (is_tuple(x) and is_binary(elem(x, 0)) and
                   (is_binary(elem(x, 1)) or is_integer(elem(x, 1)))) or is_binary(x) or
                  is_integer(x)

  @doc """
  Return if a term looks like a `gpio_spec`

  This function only verifies that the term has the right shape to be a
  `t:gpio_spec/0`. Whether or not it refers to a usable GPIO is checked by
  `Circuits.GPIO.open/3`.
  """
  @spec gpio_spec?(any) :: boolean()
  def gpio_spec?(x), do: is_gpio_spec(x)

  @doc """
  Return identifying information about a GPIO

  See `t:gpio_spec/0` for the ways of referring to GPIOs. If the GPIO is found,
  this function returns information about the GPIO.
  """
  @spec identifiers(gpio_spec()) :: {:ok, identifiers()} | {:error, atom()}
  def identifiers(gpio_spec) do
    {backend, backend_defaults} = default_backend()

    backend.identifiers(gpio_spec, backend_defaults)
  end

  @doc """
  Return dynamic configuration and status information about a GPIO

  See `t:gpio_spec/0` for the ways of referring to GPIOs. If the GPIO is found,
  this function returns information about the GPIO.
  """
  @spec status(gpio_spec()) :: {:ok, status()} | {:error, atom()}
  def status(gpio_spec) do
    {backend, backend_defaults} = default_backend()

    backend.status(gpio_spec, backend_defaults)
  end

  @doc """
  Open a GPIO

  See `t:gpio_spec/0` for the ways of referring to GPIOs. Set `direction` to
  either `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option to minimize the time the GPIO is in the default
  state.

  If you're having trouble, see `enumerate/0` for available GPIOs. If you
  suspect a hardware or driver issue, see `Circuits.GPIO.Diagnostics`.

  Options:

  * :initial_value - Set to `0` or `1`. Only used for outputs. Defaults to `0`.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.

  Returns `{:ok, handle}` on success.
  """
  @spec open(gpio_spec() | identifiers(), direction(), open_options()) ::
          {:ok, Handle.t()} | {:error, atom()}
  def open(gpio_spec_or_line_info, direction, options \\ [])

  def open(%{location: gpio_spec}, direction, options) do
    open(gpio_spec, direction, options)
  end

  def open(gpio_spec, direction, options) do
    check_gpio_spec!(gpio_spec)
    check_direction!(direction)
    check_options!(options)

    {backend, backend_defaults} = default_backend()

    all_options =
      backend_defaults
      |> Keyword.merge(options)
      |> Keyword.put_new(:initial_value, 0)
      |> Keyword.put_new(:pull_mode, :not_set)

    backend.open(gpio_spec, direction, all_options)
  end

  defp check_gpio_spec!(gpio_spec) do
    if not gpio_spec?(gpio_spec) do
      raise ArgumentError, "Invalid GPIO spec: #{inspect(gpio_spec)}"
    end
  end

  defp check_direction!(direction) do
    if direction not in [:input, :output] do
      raise ArgumentError,
            "Invalid direction: #{inspect(direction)}. Options are :input or :output"
    end
  end

  defp check_options!([]), do: :ok

  defp check_options!([{:initial_value, value} | rest]) do
    case value do
      0 -> :ok
      1 -> :ok
      :not_set -> Logger.warning("Circuits.GPIO no longer supports :not_set for :initial_value")
      _ -> raise ArgumentError, ":initial_value should be :not_set, 0, or 1"
    end

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
  Release the resources associated with a GPIO

  This is optional. The garbage collector will free GPIO resources that aren't
  in use, but this will free them sooner.
  """
  @spec close(Handle.t()) :: :ok
  defdelegate close(handle), to: Handle

  @doc """
  Read a GPIO's value

  The value returned for GPIO's that are configured as outputs is undefined.
  Backends may choose not to support this.
  """
  @spec read(Handle.t()) :: value()
  defdelegate read(handle), to: Handle

  @doc """
  One line GPIO read

  This is a convenience function that opens, reads, and closes a GPIO. It's
  intended to simplify one-off reads in code and for IEx prompt use.

  Prefer using handles in other situations.
  """
  @spec read_one(gpio_spec(), open_options()) :: value() | {:error, atom()}
  def read_one(gpio_spec, options \\ []) do
    with {:ok, handle} <- open(gpio_spec, :input, options),
         value <- read(handle) do
      :ok = close(handle)
      value
    end
  end

  @doc """
  Set the value of a GPIO

  The GPIO must be configured as an output.
  """
  @spec write(Handle.t(), value()) :: :ok
  defdelegate write(handle, value), to: Handle

  @doc """
  One line GPIO write

  This is a convenience function that opens, writes, and closes a GPIO. It's
  intended to simplify one-off writes in code and for IEx prompt use.

  Prefer using handles in other situations.
  """
  @spec write_one(gpio_spec(), value(), open_options()) :: :ok | {:error, atom()}
  def write_one(gpio_spec, value, options \\ []) do
    with {:ok, handle} <- open(gpio_spec, :output, options),
         :ok <- write(handle, value) do
      :ok = close(handle)
    end
  end

  @doc """
  Enable or disable GPIO value change notifications

  Notifications are sent based on the trigger:

  * `:none` - No notifications are sent
  * `:rising` - Send a notification when the pin changes from 0 to 1
  * `:falling` - Send a notification when the pin changes from 1 to 0
  * `:both` - Send a notification on all changes

  Available Options:
  * `:suppress_glitches` - Not supported in Circuits.GPIO v2
  * `:receiver` - Process which should receive the notifications.
  Defaults to the calling process (`self()`)

  Notification messages look like:

  ```
  {:circuits_gpio, gpio_spec, timestamp, value}
  ```

  Where `gpio_spec` is the `t:gpio_spec/0` passed to `open/3`, `timestamp` is an OS
  monotonic timestamp in nanoseconds, and `value` is the new value.

  Timestamps are not necessarily the same as from `System.monotonic_time/0`.
  For example, with the cdev backend, they're applied by the Linux kernel or
  can be come from a hardware timer. Erlang's monotonic time is adjusted so
  it's not the same as OS monotonic time. The result is that these timestamps
  can be compared with each other, but not with anything else.

  NOTE: You will need to store the `Circuits.GPIO` reference somewhere (like
  your `GenServer`'s state) so that it doesn't get garbage collected. Event
  messages stop when it gets collected. If you only get one message and you are
  expecting more, this is likely the case.
  """
  @spec set_interrupts(Handle.t(), trigger(), interrupt_options()) :: :ok | {:error, atom()}
  defdelegate set_interrupts(handle, trigger, options \\ []), to: Handle

  @doc """
  Change the direction of the pin
  """
  @spec set_direction(Handle.t(), direction()) :: :ok | {:error, atom()}
  defdelegate set_direction(handle, direction), to: Handle

  @doc """
  Enable or disable an internal pull-up or pull-down resistor
  """
  @spec set_pull_mode(Handle.t(), pull_mode()) :: :ok | {:error, atom()}
  defdelegate set_pull_mode(gpio, pull_mode), to: Handle

  @doc """
  Return info about the low level GPIO interface

  This may be helpful when debugging issues.
  """
  @spec backend_info(backend() | nil) :: map()
  def backend_info(backend \\ nil)

  def backend_info(nil), do: backend_info(default_backend())
  def backend_info({backend, _options}), do: backend.backend_info()

  @doc """
  Return a list of accessible GPIOs

  Each GPIO is described in a `t:identifiers/0` map. Some fields in the map like
  `:location` and `:label` may be passed to `open/3` to use the GPIO. The map
  itself can also be passed to `open/3` and the function will figure out how to
  access the GPIO.
  """
  @spec enumerate(backend() | nil) :: [identifiers()]
  def enumerate(backend \\ nil)
  def enumerate(nil), do: enumerate(default_backend())
  def enumerate({backend, options}), do: backend.enumerate(options)

  defp default_backend() do
    case Application.get_env(:circuits_gpio, :default_backend) do
      nil -> {Circuits.GPIO.NilBackend, []}
      m when is_atom(m) -> {m, []}
      {m, o} = value when is_atom(m) and is_list(o) -> value
    end
  end
end
