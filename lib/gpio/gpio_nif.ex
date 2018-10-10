defmodule ElixirCircuits.GPIO.Nif do
  @on_load {:load_nif, 0}
  @compile {:autoload, false}

  @moduledoc false

  def load_nif() do
    nif_binary = Application.app_dir(:gpio, "priv/gpio_nif")

    if File.exists?(nif_binary) do
      :erlang.load_nif(to_charlist(nif_binary), 0)
    else
      IO.puts("WARNING: Not loading SPI NIF since not compiled or not supported on this platform")
    end
  end

  def open(_pin_number, _pin_direction) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def read(_gpio) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def write(_gpio, _value) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_edge_mode(_gpio, _edge, _suppress_glitches, _process) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_direction(_gpio, _pin_direction) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def set_pull_mode(_gpio, _pull_mode) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
