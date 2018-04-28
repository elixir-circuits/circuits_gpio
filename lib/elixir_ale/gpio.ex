defmodule ElixirALE.GPIO do
  alias ElixirALE.GPIO.Nif

  @type pin_number :: non_neg_integer()
  @type pin_direction :: :input | :output
  @type edge :: :rising | :falling | :both | :none
  @type value :: 0 | 1

  # Public API

  @doc """
  Start and link a new GPIO GenServer. `pin` should be a valid
  GPIO pin number on the system and `pin_direction` should be
  `:input` or `:output`.
  """
  @spec start_link(pin_number(), pin_direction(), [term()]) :: GenServer.on_start()
  def start_link(pin, pin_direction, _opts \\ []) do
    # TODO: don't call this start_link since we're no longer a process.
    Nif.open(pin, pin_direction)
  end

  @spec read(reference()) :: value() | {:error, atom()}
  def read(gpio) do
    Nif.read(gpio)
  end

  @spec write(reference(), value()) :: :ok | {:error, atom()}
  def write(gpio, value) do
    Nif.write(gpio, value)
  end

  @spec set_int(reference(), edge(), boolean()) :: :ok | {:error, atom()}
  def set_int(gpio, edge \\ :both, suppress_glitches \\ true) do
    Nif.set_int(gpio, edge, suppress_glitches, self())
  end
end
