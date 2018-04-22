defmodule ElixirALE.GPIO.Nif do
  @on_load {:load_nif, 0}
  @compile {:autoload, false}

  def load_nif do
    nif_exec = '#{:code.priv_dir(:elixir_ale)}/gpio_nif'
    :erlang.load_nif(nif_exec, 0)
  end

  def init_gpio(_pin_number, _pin_direction) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def read do
    :erlang.nif_error(:nif_not_loaded)
  end

  def write(_value) do
    :erlang.nif_error(:nif_not_loaded)
  end

  def poll do
    :erlang.nif_error(:nif_not_loaded)
  end
end
