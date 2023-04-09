# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defprotocol Circuits.GPIO.Handle do
  @moduledoc """
  A handle is the connection to a real or virtual GPIO controller, bank, or pin
  """

  alias Circuits.GPIO

  @type info() :: %{pin_spec: GPIO.pin_spec()}

  @doc """
  Return the current GPIO state
  """
  @spec read(t()) :: GPIO.value()
  def read(handle)

  @doc """
  Set the GPIO state
  """
  @spec write(t(), GPIO.value()) :: :ok
  def write(handle, value)

  @doc """
  Change the direction of the GPIO
  """
  @spec set_direction(t(), GPIO.pin_direction()) :: :ok | {:error, atom()}
  def set_direction(handle, pin_direction)

  @doc """
  Change the pull mode of an input GPIO
  """
  @spec set_pull_mode(t(), GPIO.pull_mode()) :: :ok | {:error, atom()}
  def set_pull_mode(handle, mode)

  @doc """
  Free up resources associated with the handle

  Well behaved backends free up their resources with the help of the Erlang garbage collector. However, it is good
  practice for users to call `Circuits.GPIO.close/1` (and hence this function) so that
  limited resources are freed before they're needed again.
  """
  @spec close(t()) :: :ok
  def close(handle)

  @spec set_interrupts(t(), GPIO.trigger(), GPIO.interrupt_options()) :: :ok | {:error, atom()}
  def set_interrupts(handle, trigger, options)

  @spec info(t()) :: info()
  def info(handle)
end
