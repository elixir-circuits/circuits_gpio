# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Nif do
  @moduledoc false

  defp load_nif_and_apply(fun, args) do
    nif_binary = Application.app_dir(:circuits_gpio, "priv/gpio_nif")

    # Optimistically load the NIF. Handle the possible race.
    case :erlang.load_nif(to_charlist(nif_binary), 0) do
      :ok -> apply(__MODULE__, fun, args)
      {:error, {:reload, _}} -> apply(__MODULE__, fun, args)
      error -> error
    end
  end

  def open(pin_number, pin_direction, initial_value, pull_mode) do
    load_nif_and_apply(:open, [pin_number, pin_direction, initial_value, pull_mode])
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
    load_nif_and_apply(:info, [])
  end
end
