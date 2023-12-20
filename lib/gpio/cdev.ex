# SPDX-FileCopyrightText: 2023 Frank Hunleth
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
    Nif.enum()
  end

  @impl Backend
  def open(line_nr, _direction, _options) when is_integer(line_nr) do
    # {_index, sysfs_index_lookup} =
    #   nif_enum_and_sort()
    #   |> Enum.reduce({0, []}, fn {{_chip_nr, _chip_label, chip_name}, lines}, acc ->
    #     Enum.reduce(lines, acc, fn {line_number, _}, {index, list} ->
    #       spec = {chip_name, line_number}
    #       {index + 1, [{index, spec} | list]}
    #     end)
    #   end)

    # spec =
    #   Enum.find_value(sysfs_index_lookup, fn
    #     {^line_nr, spec} -> spec
    #     _ -> false
    #   end)

    # if spec, do: open(spec, direction, options), else: {:error, :not_found}
    {:error, :not_found}
  end

  def open(line_label, direction, options) when is_binary(line_label) do
    spec =
      Enum.find_value(enumerate(), fn
        %Line{line_spec: spec, label: {_chip_label, ^line_label}} -> spec
        _ -> false
      end)

    if spec, do: open(spec, direction, options), else: {:error, :not_found}
  end

  def open({chip_label, line_label}, direction, options)
      when is_binary(chip_label) and is_binary(line_label) do
    spec =
      Enum.find_value(enumerate(), fn
        %Line{line_spec: spec, label: {^chip_label, ^line_label}} -> spec
        _ -> false
      end)

    if spec, do: open(spec, direction, options), else: {:error, :not_found}
  end

  def open({controller, line}, direction, options)
      when is_binary(controller) and is_integer(line) do
    value = Keyword.fetch!(options, :initial_value)
    pull_mode = Keyword.fetch!(options, :pull_mode)
    line_spec = get_line_spec(controller, line)

    with {:ok, ref} <- Nif.open(line_spec, direction, value, pull_mode) do
      {:ok, %__MODULE__{ref: ref}}
    end
  end

  @spec get_line_spec(Circuits.GPIO2.controller(), Circuits.GPIO2.line_offset()) ::
          Circuits.GPIO2.line_spec()
  defp get_line_spec(controller, line) do
    in_slash_dev = Path.expand(controller, "/dev")

    if File.exists?(in_slash_dev), do: {in_slash_dev, line}, else: {controller, line}
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
    def set_direction(%Circuits.GPIO2.CDev{ref: ref}, line_direction) do
      Nif.set_direction(ref, line_direction)
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
      %{line_spec: Nif.pin(ref)}
    end
  end
end
