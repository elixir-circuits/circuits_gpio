# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Nif do
  @on_load {:load_nif, 0}
  @compile {:autoload, false}

  @moduledoc false

  def load_nif() do
    nif_binary = Application.app_dir(:circuits_gpio, "priv/gpio_nif")

    :erlang.load_nif(to_charlist(nif_binary), 0)
  end

  def open(_pin_number, _pin_direction, _initial_value, _pull_mode) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def close(_gpio) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def read(_gpio) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def write(_gpio, _value) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_interrupts(_gpio, _trigger, _suppress_glitches, _process) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_direction(_gpio, _pin_direction) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_pull_mode(_gpio, _pull_mode) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def pin(_gpio) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def info() do
    :erlang.nif_error(:nif_not_loaded)
  end
end
