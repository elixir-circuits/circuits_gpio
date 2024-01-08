# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Nif do
  @moduledoc false

  defp load_nif_and_apply(fun, args) do
    nif_binary = Application.app_dir(:circuits_gpio, "priv/gpio_nif")

    with :ok <- :erlang.load_nif(to_charlist(nif_binary), 0) do
      apply(__MODULE__, fun, args)
    end
  end

  def open(gpio_spec, resolved_gpio_spec, direction, initial_value, pull_mode) do
    load_nif_and_apply(:open, [
      gpio_spec,
      resolved_gpio_spec,
      direction,
      initial_value,
      pull_mode
    ])
  end

  def close(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def read(_gpio), do: :erlang.nif_error(:nif_not_loaded)
  def write(_gpio, _value), do: :erlang.nif_error(:nif_not_loaded)

  def set_interrupts(_gpio, _trigger, _suppress_glitches, _process),
    do: :erlang.nif_error(:nif_not_loaded)

  def set_direction(_gpio, _direction), do: :erlang.nif_error(:nif_not_loaded)
  def set_pull_mode(_gpio, _pull_mode), do: :erlang.nif_error(:nif_not_loaded)
  def info(_gpio), do: :erlang.nif_error(:nif_not_loaded)

  def status(resolved_gpio_spec) do
    load_nif_and_apply(:status, [resolved_gpio_spec])
  end

  def backend_info() do
    load_nif_and_apply(:backend_info, [])
  end

  def enumerate() do
    load_nif_and_apply(:enumerate, [])
  end
end
