defmodule ElixirALE.GPIO do
  use GenServer

  @on_load {:load_nif, 0}

  defmodule State do
    @moduledoc false
    @enforce_keys :pin_number
    defstruct pin_number: nil, direction: nil, callbacks: [], fd: nil
  end

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

  def init([pin, pin_direction]) do
    {:ok, fd} = init_gpio(pin, pin_direction)

    {:ok, %State{pin_number: pin, direction: pin_direction, fd: fd}}
  end

  def handle_call(:read, _from, %State{pin_number: pin_number, fd: fd} = state) do
    {:reply, read_nif(pin_number, fd), state}
  end

  def handle_call({:write, value}, _from, %State{pin_number: pin_number, fd: fd} = state) do
    IO.inspect fd, label: "FD"
    {:reply, write_nif(pin_number, value, fd), state}
  end

  def init_gpio(_pin_number, _pin_direction) do
    "NIF library not loaded."
  end

  def load_nif do
    nif_exec = '#{:code.priv_dir(:elixir_ale)}/gpio_nif'
    :erlang.load_nif(nif_exec, 0)
  end

  def read_nif(_pin_number, _fd) do
    "NIF library not loaded."
  end
  
  def write_nif(_pin_number, _value, _fd) do
    "NIF library not loaded"
  end
end
