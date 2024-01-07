# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defprotocol Circuits.GPIO.Handle do
  @moduledoc """
  Handle for referring to GPIOs

  Use the functions in `Circuits.GPIO` to read and write to GPIOs.
  """

  alias Circuits.GPIO

  # Information about the GPIO
  #
  # * `:gpio_spec` - the spec that was used to open the GPIO
  @typep info() :: %{gpio_spec: GPIO.gpio_spec()}

  # Return the current GPIO state
  @doc false
  @spec read(t()) :: GPIO.value()
  def read(handle)

  # Set the GPIO state
  @doc false
  @spec write(t(), GPIO.value()) :: :ok
  def write(handle, value)

  # Change the direction of the GPIO
  @doc false
  @spec set_direction(t(), GPIO.direction()) :: :ok | {:error, atom()}
  def set_direction(handle, direction)

  # Change the pull mode of an input GPIO
  @doc false
  @spec set_pull_mode(t(), GPIO.pull_mode()) :: :ok | {:error, atom()}
  def set_pull_mode(handle, mode)

  # Free up resources associated with the handle
  #
  # Well behaved backends free up their resources with the help of the Erlang
  # garbage collector. However, it is good practice for users to call
  # `Circuits.GPIO.close/1` (and hence this function) so that limited resources
  # are freed before they're needed again.
  @doc false
  @spec close(t()) :: :ok
  def close(handle)

  @doc false
  @spec set_interrupts(t(), GPIO.trigger(), GPIO.interrupt_options()) :: :ok | {:error, atom()}
  def set_interrupts(handle, trigger, options)

  @doc false
  @spec info(t()) :: info()
  def info(handle)
end
