# SPDX-FileCopyrightText: 2023 Frank Hunleth, Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.CDev do
  @moduledoc """
  Circuits.GPIO2 backend that uses the Linux CDev for controlling GPIOs
  """
  @behaviour Circuits.GPIO2.Backend

  alias Circuits.GPIO2.Backend
  alias Circuits.GPIO2.Handle
  alias Circuits.GPIO2.Line
  alias Circuits.GPIO2.Nif

  defstruct [:ref]

  @impl Backend
  def enumerate() do
    Nif.enumerate()
  end

  defp normalize_gpio_spec(number) when is_integer(number) do
    info = enumerate() |> Enum.at(number)

    if info, do: {:ok, info.gpio_spec}, else: {:error, :not_found}
  end

  defp normalize_gpio_spec(line_label) when is_binary(line_label) do
    spec =
      Enum.find_value(enumerate(), fn
        %Line{gpio_spec: spec, label: {_chip_label, ^line_label}} -> spec
        _ -> false
      end)

    if spec, do: {:ok, spec}, else: {:error, :not_found}
  end

  defp normalize_gpio_spec({chip_label, line_label})
       when is_binary(chip_label) and is_binary(line_label) do
    spec =
      Enum.find_value(enumerate(), fn
        %Line{gpio_spec: spec, label: {^chip_label, ^line_label}} -> spec
        _ -> false
      end)

    if spec, do: {:ok, spec}, else: {:error, :not_found}
  end

  defp normalize_gpio_spec({controller, line}) when is_binary(controller) and is_integer(line) do
    {:ok, {controller, line}}
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

    with {:ok, normalized_spec} <- normalize_gpio_spec(gpio_spec),
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
    def read(%Circuits.GPIO2.CDev{ref: ref}) do
      Nif.read(ref)
    end

    @impl Handle
    def write(%Circuits.GPIO2.CDev{ref: ref}, value) do
      Nif.write(ref, value)
    end

    @impl Handle
    def set_direction(%Circuits.GPIO2.CDev{ref: ref}, direction) do
      Nif.set_direction(ref, direction)
    end

    @impl Handle
    def set_pull_mode(%Circuits.GPIO2.CDev{ref: ref}, pull_mode) do
      Nif.set_pull_mode(ref, pull_mode)
    end

    @impl Handle
    def set_interrupts(%Circuits.GPIO2.CDev{ref: ref}, trigger, options) do
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
    def close(%Circuits.GPIO2.CDev{ref: ref}) do
      Nif.close(ref)
    end

    @impl Handle
    def info(%Circuits.GPIO2.CDev{ref: ref}) do
      %{gpio_spec: Nif.gpio_spec(ref), pin_number: Nif.pin_number(ref)}
    end
  end
end
