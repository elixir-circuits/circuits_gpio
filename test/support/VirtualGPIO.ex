# SPDX-FileCopyrightText: 2025 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule VirtualGPIO do
  @moduledoc """
  A simple virtual GPIO backend for unit testing.

  This backend provides exactly two GPIOs:
  - GPIO 0: Output only ({"virtual_chip", 0})
  - GPIO 1: Input only ({"virtual_chip", 1})

  The GPIOs are virtually connected - any value written to GPIO 0 immediately
  appears when reading GPIO 1, like they're connected by a wire.

  Example usage:
  ```elixir
  # Set the backend
  Application.put_env(:circuits_gpio, :backend, {VirtualGPIO.Backend, []})

  # Open the GPIOs
  {:ok, output} = Circuits.GPIO.open({"virtual_chip", 0}, :output)
  {:ok, input} = Circuits.GPIO.open({"virtual_chip", 1}, :input)

  # Write to output, read from input
  Circuits.GPIO.write(output, 1)
  1 = Circuits.GPIO.read(input)
  ```
  """

  defmodule Backend do
    @moduledoc """
    Virtual GPIO backend implementation
    """
    @behaviour Circuits.GPIO.Backend

    alias Circuits.GPIO.Backend

    @virtual_controller "virtual_chip"

    @impl Backend
    def enumerate(_options) do
      [
        %{
          location: {@virtual_controller, 0},
          controller: @virtual_controller,
          label: "VIRTUAL_OUTPUT"
        },
        %{
          location: {@virtual_controller, 1},
          controller: @virtual_controller,
          label: "VIRTUAL_INPUT"
        }
      ]
    end

    @impl Backend
    def identifiers(gpio_spec, _options) do
      case normalize_gpio_spec(gpio_spec) do
        {@virtual_controller, 0} ->
          {:ok,
           %{
             location: {@virtual_controller, 0},
             controller: @virtual_controller,
             label: "VIRTUAL_OUTPUT"
           }}

        {@virtual_controller, 1} ->
          {:ok,
           %{
             location: {@virtual_controller, 1},
             controller: @virtual_controller,
             label: "VIRTUAL_INPUT"
           }}

        "VIRTUAL_OUTPUT" ->
          identifiers({@virtual_controller, 0}, [])

        "VIRTUAL_INPUT" ->
          identifiers({@virtual_controller, 1}, [])

        _ ->
          {:error, :not_found}
      end
    end

    @impl Backend
    def status(gpio_spec, _options) do
      case normalize_gpio_spec(gpio_spec) do
        {@virtual_controller, 0} ->
          {:ok,
           %{
             consumer: nil,
             direction: :output,
             pull_mode: :not_set
           }}

        {@virtual_controller, 1} ->
          {:ok,
           %{
             consumer: nil,
             direction: :input,
             pull_mode: :not_set
           }}

        "VIRTUAL_OUTPUT" ->
          status({@virtual_controller, 0}, [])

        "VIRTUAL_INPUT" ->
          status({@virtual_controller, 1}, [])

        _ ->
          {:error, :not_found}
      end
    end

    @impl Backend
    def open(gpio_spec, direction, options) do
      case {normalize_gpio_spec(gpio_spec), direction} do
        {{@virtual_controller, 0}, :output} ->
          initial_value = Keyword.get(options, :initial_value, 0)
          VirtualGPIO.State.set_value(initial_value)
          {:ok, %VirtualGPIO.Handle{gpio: 0, direction: :output}}

        {{@virtual_controller, 1}, :input} ->
          {:ok, %VirtualGPIO.Handle{gpio: 1, direction: :input}}

        {{@virtual_controller, 0}, :input} ->
          {:error, :invalid_direction}

        {{@virtual_controller, 1}, :output} ->
          {:error, :invalid_direction}

        {"VIRTUAL_OUTPUT", :output} ->
          open({@virtual_controller, 0}, direction, options)

        {"VIRTUAL_INPUT", :input} ->
          open({@virtual_controller, 1}, direction, options)

        _ ->
          {:error, :not_found}
      end
    end

    @impl Backend
    def backend_info() do
      %{name: __MODULE__, description: "Virtual GPIO backend for testing"}
    end

    defp normalize_gpio_spec({controller, line}) when is_binary(controller) and is_integer(line),
      do: {controller, line}

    defp normalize_gpio_spec(label) when is_binary(label), do: label
    defp normalize_gpio_spec(other), do: other
  end

  defmodule Handle do
    @moduledoc """
    Virtual GPIO handle implementation
    """
    defstruct [:gpio, :direction]

    @type t() :: %__MODULE__{
            gpio: 0 | 1,
            direction: :input | :output
          }
  end

  defmodule State do
    @moduledoc """
    Shared state for the virtual connection between GPIO 0 and GPIO 1
    """
    use Agent

    @doc """
    Start the state agent
    """
    def start_link(initial_value \\ 0) do
      Agent.start_link(fn -> initial_value end, name: __MODULE__)
    end

    @doc """
    Set the GPIO value (from output GPIO 0)
    """
    def set_value(value) when value in [0, 1] do
      case Process.whereis(__MODULE__) do
        nil -> start_link(value)
        _ -> Agent.update(__MODULE__, fn _ -> value end)
      end

      :ok
    end

    @doc """
    Get the GPIO value (for input GPIO 1)
    """
    def get_value() do
      case Process.whereis(__MODULE__) do
        nil ->
          start_link(0)
          0

        _ ->
          Agent.get(__MODULE__, & &1)
      end
    end

    @doc """
    Stop the state agent
    """
    def stop() do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end
  end
end

defimpl Circuits.GPIO.Handle, for: VirtualGPIO.Handle do
  @impl true
  def read(%VirtualGPIO.Handle{gpio: 1, direction: :input}) do
    VirtualGPIO.State.get_value()
  end

  def read(%VirtualGPIO.Handle{gpio: 0, direction: :output}) do
    # Reading from an output GPIO returns the last written value
    VirtualGPIO.State.get_value()
  end

  @impl true
  def write(%VirtualGPIO.Handle{gpio: 0, direction: :output}, value) when value in [0, 1] do
    VirtualGPIO.State.set_value(value)
  end

  def write(%VirtualGPIO.Handle{gpio: 1, direction: :input}, _value) do
    {:error, :read_only}
  end

  @impl true
  def set_direction(%VirtualGPIO.Handle{gpio: 0}, :output), do: :ok
  def set_direction(%VirtualGPIO.Handle{gpio: 1}, :input), do: :ok
  def set_direction(%VirtualGPIO.Handle{}, _direction), do: {:error, :invalid_direction}

  @impl true
  def set_pull_mode(%VirtualGPIO.Handle{direction: :input}, _mode), do: :ok
  def set_pull_mode(%VirtualGPIO.Handle{direction: :output}, _mode), do: {:error, :not_supported}

  @impl true
  def close(%VirtualGPIO.Handle{}), do: :ok

  @impl true
  def set_interrupts(%VirtualGPIO.Handle{}, _trigger, _options) do
    {:error, :not_supported}
  end
end
