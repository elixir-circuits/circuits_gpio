defmodule ElixirALE.GPIO do
  alias ElixirALE.GPIO.Nif

  @type pin_number :: non_neg_integer()
  @type pin_direction :: :input | :output
  @type value :: 0 | 1

  # Public API

  @doc """
  Start and link a new GPIO GenServer. `pin` should be a valid
  GPIO pin number on the system and `pin_direction` should be
  `:input` or `:output`.
  """
  @spec start_link(pin_number(), pin_direction(), [term()]) :: GenServer.on_start()
  def start_link(pin, pin_direction, opts \\ []) do
    Nif.open(pin, pin_direction)
  end

  @spec read(reference()) :: value() | {:error, atom()}
  def read(gpio) do
    Nif.read(gpio)
  end

  @spec write(reference(), value()) :: :ok | {:error, atom()}
  def write(gpio, value) do
    Nif.write(gpio, value)
  end

  @doc """
  Listen for GPIO interups
  """
  def listen(_ref) do
    # GenServer.call(pid, :listen)
  end

  #  def handle_call(:listen, {pid, _}, state) do
  #    :ok = Nif.poll()
  #    {:reply, :ok, %{state | pid: pid}}
  #  end

  #  def handle_info({:select, _res, _ref, :ready_input}, state) do
  #    value = Nif.read()
  #    send(state.pid, {:elixir_ale, value})
  #    {:noreply, state}
  #  end
end
