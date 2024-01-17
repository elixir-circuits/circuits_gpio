# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Nif do
  @moduledoc false

  @on_load {:load_nif, 0}
  @compile {:autoload, false}

  def load_nif() do
    :erlang.load_nif(:code.priv_dir(:circuits_gpio) ++ ~c"/gpio_nif", 0)
  end

  def open(_gpio_spec, _resolved_gpio_spec, _direction, _initial_value, _pull_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def close(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def read(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def write(_gpio, _value), do: :erlang.nif_error(:nif_not_loaded)

  def set_interrupts(_gpio, _trigger, _suppress_glitches, _process),
    do: :erlang.nif_error(:nif_not_loaded)

  def set_direction(_gpio, _direction), do: :erlang.nif_error(:nif_not_loaded)
  def set_pull_mode(_gpio, _pull_mode), do: :erlang.nif_error(:nif_not_loaded)
  def info(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def status(_resolved_gpio_spec), do: :erlang.nif_error(:nif_not_loaded)
  def backend_info(), do: :erlang.nif_error(:nif_not_loaded)
  def enumerate(), do: :erlang.nif_error(:nif_not_loaded)
end
