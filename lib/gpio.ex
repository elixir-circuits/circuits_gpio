defmodule ElixlirCircuits.GPIO do
  alias ElixirCircuits.GPIO.Nif, as: Nif

  @type pin_number :: non_neg_integer()
  @type pin_direction :: :input | :output
  @type value :: 0 | 1
  @type edge :: :rising | :falling | :both | :none
  @type pull_dir :: :not_set | :none | :pullup | :pulldown
  

  
  # Public API

  @doc """
  Open a GPIO for use. `pin` should be a valid GPIO pin number on the system
  and `pin_direction` should be `:input` or `:output`.
  """
  @spec open(pin_number(), pin_direction(), [term()]) :: {:ok, integer} | {:error, atom()}
  def open(pin_number, pin_direction, _gpio_opts \\ []) do
    #init_value = Keyword.get(gpio_opts, :init_value, 0)
    #int_edge = Keyword.get(gpio_opts, :int_edge, :none)
    #pull_dir = Keyword.get(gpio_opts, :pull_dir, :not_set)
    #notify_pid = Keyword.get(gpio_opts, :notify_pid, nil)

    #Nif.open(pin_number, pin_direction, init_value, int_edge, pull_dir, notifiy_pid)
    Nif.open(pin_number, pin_direction)
  end

  @doc """
  Read the current value on a pin.
  """
  @spec read(reference()) :: value() | {:error, atom()}
  def read(gpio) do
    Nif.read(gpio)
  end

  @doc """
  Set the value of a pin. The pin should be configured to an output
  for this to work.
  """
  @spec write(reference(), value()) :: :ok | {:error, atom()}
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

  It is possible that the pin transitions to a value and back by the time
  that Elixir ALE gets to process it. The third parameter, `suppress_glitches`, controls
  whether a notification is sent. Set this to `false` to receive notifications.

  Notifications look like:

  ```
  {:gpio, pin_number, timestamp, value}
  ```

  Where `pin_number` is the pin that changed values, `timestamp` is roughly when
  the transition occurred in nanoseconds, and `value` is the new value.
  """
  @spec set_edge_mode(reference(), edge(), boolean()) :: :ok | {:error, atom()}
  def set_edge_mode(gpio, edge \\ :both, suppress_glitches \\ true) do
    Nif.set_edge_mode(gpio, edge, suppress_glitches, self())
  end

  @doc """
  Change the direction of the pin.
  """
  @spec set_direction(reference(), pin_direction()) :: :ok | {:error, atom()}
  def set_direction(gpio, pin_direction) do
    Nif.set_direction(gpio, pin_direction)
  end

  #@spec set_int(reference(), edge()) :: :ok | {:error, atom()}
  #def set_int(gpio, edge \\ :both) do
  #  set_edge_mode(gpio, edge)
  #end

end
