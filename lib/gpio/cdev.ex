# SPDX-FileCopyrightText: 2023 Frank Hunleth, Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.CDev do
  @moduledoc """
  Circuits.GPIO backend that uses the Linux CDev for controlling GPIOs

  This is the default on Linux and Nerves. Nothing needs to be done to
  use it on those platforms. If you need to be explicit, here's the
  configuration to force it:

  ```elixir
  config :circuits_gpio, default_backend: Circuits.GPIO.CDev
  ```

  It takes one option, `:test`, that can be set to `true` to compile
  the stub implementation that can be useful for testing.

  ```elixir
  config :circuits_gpio, default_backend: {Circuits.GPIO.CDev, test: true}
  ```
  """
  @behaviour Circuits.GPIO.Backend

  alias Circuits.GPIO.Backend
  alias Circuits.GPIO.Handle
  alias Circuits.GPIO.Nif

  defstruct [:ref]

  @impl Backend
  def enumerate(options) do
    cached = :persistent_term.get(__MODULE__, [])

    if cached == [] or options[:force_enumeration] do
      results = Nif.enumerate()
      :persistent_term.put(__MODULE__, results)
      results
    else
      cached
    end
  end

  defp find_by_index(gpios, index), do: Enum.at(gpios, index)

  defp find_by_tuple(gpios, {controller, label_or_index}) do
    Enum.find(gpios, fn
      %{location: {^controller, _}, label: ^label_or_index} -> true
      %{controller: ^controller, label: ^label_or_index} -> true
      %{location: {^controller, ^label_or_index}} -> true
      %{controller: ^controller, location: {_, ^label_or_index}} -> true
      _ -> false
    end)
  end

  defp find_by_label(gpios, label) do
    Enum.find(gpios, fn
      %{label: ^label} -> true
      _ -> false
    end)
  end

  defp retry_find(options, find_fun) do
    info =
      find_fun.(enumerate(options)) ||
        find_fun.(enumerate([{:force_enumeration, true} | options]))

    if info, do: {:ok, info}, else: {:error, :not_found}
  end

  @impl Backend
  def gpio_info(number, options) when is_integer(number) and number >= 0 do
    retry_find(options, &find_by_index(&1, number))
  end

  def gpio_info(line_label, options) when is_binary(line_label) do
    retry_find(options, &find_by_label(&1, line_label))
  end

  def gpio_info(tuple_spec, options)
      when is_tuple(tuple_spec) and tuple_size(tuple_spec) == 2 do
    retry_find(options, &find_by_tuple(&1, tuple_spec))
  end

  def gpio_info(_gpio_spec, _options) do
    {:error, :not_found}
  end

  defp find_location({controller, line}, _options)
       when is_binary(controller) and is_integer(line) do
    {:ok, {controller, line}}
  end

  defp find_location(gpio_spec, options) do
    with {:ok, gpio_info} <- gpio_info(gpio_spec, options) do
      {:ok, gpio_info.location}
    end
  end

  defp resolve_gpiochip({controller, line}) do
    in_slash_dev = Path.expand(controller, "/dev")

    if File.exists?(in_slash_dev),
      do: {in_slash_dev, line},
      else: {controller, line}
  end

  @impl Backend
  def open(gpio_spec, direction, options) do
    value = Keyword.fetch!(options, :initial_value)
    pull_mode = Keyword.fetch!(options, :pull_mode)

    with {:ok, location} <- find_location(gpio_spec, options),
         resolved_location = resolve_gpiochip(location),
         {:ok, ref} <- Nif.open(gpio_spec, resolved_location, direction, value, pull_mode) do
      {:ok, %__MODULE__{ref: ref}}
    end
  end

  @impl Backend
  def info() do
    Nif.info() |> Map.put(:name, __MODULE__)
  end

  defimpl Handle do
    @impl Handle
    def read(%Circuits.GPIO.CDev{ref: ref}) do
      Nif.read(ref)
    end

    @impl Handle
    def write(%Circuits.GPIO.CDev{ref: ref}, value) do
      Nif.write(ref, value)
    end

    @impl Handle
    def set_direction(%Circuits.GPIO.CDev{ref: ref}, direction) do
      Nif.set_direction(ref, direction)
    end

    @impl Handle
    def set_pull_mode(%Circuits.GPIO.CDev{ref: ref}, pull_mode) do
      Nif.set_pull_mode(ref, pull_mode)
    end

    @impl Handle
    def set_interrupts(%Circuits.GPIO.CDev{ref: ref}, trigger, options) do
      suppress_glitches = Keyword.get(options, :suppress_glitches, true)

      receiver =
        case Keyword.get(options, :receiver) do
          pid when is_pid(pid) -> pid
          name when is_atom(name) -> Process.whereis(name) || self()
          _ -> self()
        end

      Nif.set_interrupts(ref, trigger, suppress_glitches, receiver)
    end

    @impl Handle
    def close(%Circuits.GPIO.CDev{ref: ref}) do
      Nif.close(ref)
    end

    @impl Handle
    def info(%Circuits.GPIO.CDev{ref: ref}) do
      %{gpio_spec: Nif.gpio_spec(ref)}
    end
  end
end
