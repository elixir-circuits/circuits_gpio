# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.Nif do
  @moduledoc false

  defp load_nif() do
    nif_binary = Application.app_dir(:circuits_gpio2, "priv/gpio_nif")
    :erlang.load_nif(to_charlist(nif_binary), 0)
  end

  def open(pin_number, line_direction, initial_value, pull_mode) do
    with :ok <- load_nif() do
      apply(__MODULE__, :open, [pin_number, line_direction, initial_value, pull_mode])
    end
  end

  def close(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def read(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def write(_gpio, _value), do: :erlang.nif_error(:nif_not_loaded)

  def set_interrupts(_gpio, _trigger, _suppress_glitches, _process),
    do: :erlang.nif_error(:nif_not_loaded)

  def set_direction(_gpio, _pin_direction), do: :erlang.nif_error(:nif_not_loaded)
  def set_pull_mode(_gpio, _pull_mode), do: :erlang.nif_error(:nif_not_loaded)
  def pin(_gpio), do: :erlang.nif_error(:nif_not_loaded)

  def info() do
    :ok = load_nif()
    apply(__MODULE__, :info, [])
  end
end
