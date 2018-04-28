defmodule ElixirALE.GPIO.Nif do
  @on_load {:load_nif, 0}
  @compile {:autoload, false}

  def load_nif() do
    nif_exec = '#{:code.priv_dir(:elixir_ale)}/gpio_nif'
    :erlang.load_nif(nif_exec, 0)
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

  def set_int(_gpio, _edge, _suppress_glitches, _process) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
