defmodule ElixirALE.GPIO do
  alias ElixirALE.GPIO.Nif

  @type pin_direction :: :input | :output

  # Public API

  @doc """
  Start and link a new GPIO GenServer. `pin` should be a valid
  GPIO pin number on the system and `pin_direction` should be
  `:input` or `:output`.
  """
  @spec start_link(integer, pin_direction, [term]) :: GenServer.on_start()
  def start_link(pin, pin_direction, opts \\ []) do
    Nif.init_gpio(pin, pin_direction)
  end

  def read(pid) do
    Nif.read(pid)
  end

  def write(pid, value) do
    Nif.write(pid, value)
  end

  @doc """
  Listen for GPIO interups
  """
  def listen(pid) do
    #GenServer.call(pid, :listen)
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
