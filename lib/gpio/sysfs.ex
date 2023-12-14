# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.Sysfs do
  @moduledoc """
  Circuits.GPIO2 backend that uses the Linux sysfs for controlling GPIOs
  """
  @behaviour Circuits.GPIO2.Backend

  alias Circuits.GPIO2.Backend
  alias Circuits.GPIO2.Handle
  alias Circuits.GPIO2.Nif

  defstruct [:ref]

  @impl Backend
  def enumerate() do
    Nif.enum()
    |> Enum.reduce([], fn {{chip_path, chip_label}, lines}, acc ->
      Enum.reduce(lines, acc, fn {_line_number, %{label: line_label, line: line_number}}, acc ->
        line = %GPIO2.Line{line_spec: {chip_path, line_number}, controller: chip_path, label: {chip_label, line_label}}
        [line | acc]
      end)
    end)
  end

  @impl Backend
  def open(line_spec, direction, options) do
    value = Keyword.fetch!(options, :initial_value)
    pull_mode = Keyword.fetch!(options, :pull_mode)

    with {:ok, ref} <- Nif.open(line_spec, direction, value, pull_mode) do
      {:ok, %__MODULE__{ref: ref}}
    end
  end

  @impl Backend
  def info() do
    Nif.info() |> Map.put(:name, __MODULE__)
  end

  defimpl Handle do
    @impl Handle
    def read(%Circuits.GPIO2.Sysfs{ref: ref}) do
      Nif.read(ref)
    end

    @impl Handle
    def write(%Circuits.GPIO2.Sysfs{ref: ref}, value) do
      Nif.write(ref, value)
    end

    @impl Handle
    def set_direction(%Circuits.GPIO2.Sysfs{ref: ref}, line_direction) do
      Nif.set_direction(ref, line_direction)
    end

    @impl Handle
    def set_pull_mode(%Circuits.GPIO2.Sysfs{ref: ref}, pull_mode) do
      Nif.set_pull_mode(ref, pull_mode)
    end

    @impl Handle
    def set_interrupts(%Circuits.GPIO2.Sysfs{ref: ref}, trigger, options) do
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
    def close(%Circuits.GPIO2.Sysfs{ref: ref}) do
      Nif.close(ref)
    end

    @impl Handle
    def info(%Circuits.GPIO2.Sysfs{ref: ref}) do
      %{line_spec: Nif.pin(ref)}
    end
  end
end
