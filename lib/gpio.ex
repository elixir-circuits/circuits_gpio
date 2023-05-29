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
  alias Circuits.GPIO.Handle

  @typedoc """
  Backends specify an implementation of a Circuits.GPIO.Backend behaviour

  The second parameter of the Backend 2-tuple is a list of options. These are
  passed to the behaviour function call implementations.
  """
  @type backend() :: {module(), keyword()}

  @typedoc """
  The names or numbers for one or more GPIO pins

  See your device's documentation for how pins are labelled on your
  device. Currently only numbers are supported by backends, but future backends
  should support other ways.
  """
  @type pin_spec() :: non_neg_integer()

  @typedoc "The GPIO direction (input or output)"
  @type pin_direction() :: :input | :output

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

  `pin` should be a valid GPIO pin number on the system and `pin_direction`
  should be `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option if you need the set to be glitch free.

  Options:

  * :initial_value - Set to `:not_set`, `0` or `1` if this is an output.
    `:not_set` is the default.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.
  """
  @spec open(pin_spec(), pin_direction(), open_options()) ::
          {:ok, Handle.t()} | {:error, atom()}
  def open(pin_number, pin_direction, options \\ []) do
    check_options!(options)

    {backend, backend_defaults} = default_backend()

    all_options =
      backend_defaults
      |> Keyword.merge(options)
      |> Keyword.put_new(:initial_value, :not_set)
      |> Keyword.put_new(:pull_mode, :not_set)

    backend.open(pin_number, pin_direction, all_options)
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
  @spec set_interrupts(Handle.t(), trigger(), interrupt_options()) :: :ok | {:error, atom()}
  defdelegate set_interrupts(handle, trigger, options \\ []), to: Handle

  @doc """
  Change the direction of the pin.
  """
  @spec set_direction(Handle.t(), pin_direction()) :: :ok | {:error, atom()}
  defdelegate set_direction(handle, pin_direction), to: Handle

  @doc """
  Enable or disable internal pull-up or pull-down resistor to GPIO pin
  """
  @spec set_pull_mode(Handle.t(), pull_mode()) :: :ok | {:error, atom()}
  defdelegate set_pull_mode(gpio, pull_mode), to: Handle

  @doc """
  Get the GPIO pin number
  """
  @spec pin(Handle.t()) :: pin_spec()
  def pin(handle) do
    info = Handle.info(handle)
    info.pin
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
    case Application.get_env(:circuits_gpio, :default_backend) do
      nil -> {Circuits.GPIO.NilBackend, []}
      m when is_atom(m) -> {m, []}
      {m, o} = value when is_atom(m) and is_list(o) -> value
    end
  end
end
