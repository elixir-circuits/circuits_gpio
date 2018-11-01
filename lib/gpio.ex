defmodule Circuits.GPIO do
  alias Circuits.GPIO.Nif

  @type pin_number :: non_neg_integer()
  @type pin_direction :: :input | :output
  @type value :: 0 | 1
  @type edge :: :rising | :falling | :both | :none
  @type pull_mode :: :not_set | :none | :pullup | :pulldown

  # Public API

  @doc """
  Open a GPIO for use. `pin` should be a valid GPIO pin number on the system
  and `pin_direction` should be `:input` or `:output`.
  """
  @spec open(pin_number(), pin_direction()) :: {:ok, reference()} | {:error, atom()}
  def open(pin_number, pin_direction) do
    Nif.open(pin_number, pin_direction)
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
  are sent based on the edge mode parameter:

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
  {:gpio, pin_number, timestamp, value}
  ```

  Where `pin_number` is the pin that changed values, `timestamp` is roughly when
  the transition occurred in nanoseconds, and `value` is the new value.
  """
  @spec set_edge_mode(reference(), edge(), list()) :: :ok | {:error, atom()}
  def set_edge_mode(gpio, edge \\ :both, opts \\ []) do
    suppress_glitches = Keyword.get(opts, :suppress_glitches, true)

    receiver =
      case Keyword.get(opts, :receiver) do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name) || self()
        _ -> self()
      end

    Nif.set_edge_mode(gpio, edge, suppress_glitches, receiver)
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

  defmodule :circuits_gpio do
    @moduledoc """
    Provide an Erlang friendly interface to Circuits
    Example Erlang code:  circuits_gpio:open(5, output)
    """
    defdelegate open(pin_number, pin_direction), to: Circuits.GPIO
    defdelegate read(gpio), to: Circuits.GPIO
    defdelegate write(gpio, value), to: Circuits.GPIO
    defdelegate set_edge_mode(gpio), to: Circuits.GPIO
    defdelegate set_edge_mode(gpio, edge), to: Circuits.GPIO
    defdelegate set_edge_mode(gpio, edge, suppress_glitches), to: Circuits.GPIO
    defdelegate set_direction(gpio, pin_direction), to: Circuits.GPIO
    defdelegate set_pull_mode(gpio, pull_mode), to: Circuits.GPIO
    defdelegate pin(gpio), to: Circuits.GPIO
  end
end
