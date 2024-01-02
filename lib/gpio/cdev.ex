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
  alias Circuits.GPIO.Line
  alias Circuits.GPIO.Nif

  defstruct [:ref]

  @impl Backend
  def enumerate() do
    Nif.enumerate()
  end

  @impl Backend
  def line_info(number, _options) when is_integer(number) and number >= 0 do
    info = enumerate() |> Enum.at(number)
    if info, do: {:ok, info}, else: {:error, :not_found}
  end

  def line_info(line_label, _options) when is_binary(line_label) do
    Enum.find_value(enumerate(), {:error, :not_found}, fn
      %Line{label: ^line_label} = info -> {:ok, info}
      _ -> false
    end)
  end

  def line_info({chip_label, line_label}, _options)
      when is_binary(chip_label) and is_binary(line_label) do
    Enum.find_value(enumerate(), {:error, :not_found}, fn
      %Line{controller: ^chip_label, label: ^line_label} = info -> {:ok, info}
      _ -> false
    end)
  end

  def line_info(_gpio_spec, _options) do
    {:error, :not_found}
  end

  defp normalize_gpio_spec({controller, line}, _options)
       when is_binary(controller) and is_integer(line) do
    {:ok, {controller, line}}
  end

  defp normalize_gpio_spec(gpio_spec, options) do
    with {:ok, line_info} <- line_info(gpio_spec, options) do
      {:ok, line_info.gpio_spec}
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

    with {:ok, normalized_spec} <- normalize_gpio_spec(gpio_spec, options),
         resolved_spec = resolve_gpiochip(normalized_spec),
         {:ok, ref} <- Nif.open(gpio_spec, resolved_spec, direction, value, pull_mode) do
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
      %{gpio_spec: Nif.gpio_spec(ref), pin_number: Nif.pin_number(ref)}
    end
  end
end
