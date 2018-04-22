defmodule ElixirALE.GPIO do
  use GenServer

  defmodule State do
    @moduledoc false
    defstruct pid: nil
  end

  alias ElixirALE.GPIO.Nif

  @type pin_direction :: :input | :output

  # Public API

  @doc """
  Start and link a new GPIO GenServer. `pin` should be a valid
  GPIO pin number on the system and `pin_direction` should be
  `:input` or `:output`.
  """
  @spec start_link(integer, pin_direction, [term]) :: Genser.on_start()
  def start_link(pin, pin_direction, opts \\ []) do
    GenServer.start_link(__MODULE__, [pin, pin_direction], opts)
  end

  def read(pid) do
    GenServer.call(pid, :read)
  end

  def write(pid, value) do
    GenServer.call(pid, {:write, value})
  end

  @doc """
  Listen for GPIO interups
  """
  def listen(pid) do
    GenServer.call(pid, :listen)
  end

  def init([pin, pin_direction]) do
    {:ok, _fd} = Nif.init_gpio(pin, pin_direction)
    {:ok, %State{}}
  end

  def handle_call(:read, _from, %State{} = state) do
    {:reply, Nif.read(), state}
  end

  def handle_call({:write, value}, _from, state) do
    {:reply, Nif.write(value), state}
  end

  def handle_call(:listen, {pid, _}, state) do
    :ok = Nif.poll()
    {:reply, :ok, %{state | pid: pid}}
  end

  def handle_info({:select, _res, _ref, :ready_input}, state) do
    value = Nif.read()
    send(state.pid, {:elixir_ale, value})
    {:noreply, state}
  end
end
