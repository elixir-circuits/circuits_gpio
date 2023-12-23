# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defprotocol Circuits.GPIO2.Handle do
  @moduledoc """
  A handle is the connection to a real or virtual GPIO

  The implementation of this protocol handles communications to GPIO controller.
  """

  alias Circuits.GPIO2

  @typedoc """
  Information about the GPIO

  * `:gpio_spec` - the spec that was used to open the GPIO
  * `:pin_number` - the legacy pin number for the GPIO. This is for backwards compatibility and could be
                  set to `0` if there's no easy way to assign a unique number to it.
  """
  @type info() :: %{gpio_spec: GPIO2.gpio_spec(), pin_number: non_neg_integer()}

  @doc """
  Return the current GPIO state
  """
  @spec read(t()) :: GPIO2.value()
  def read(handle)

  @doc """
  Set the GPIO state
  """
  @spec write(t(), GPIO2.value()) :: :ok
  def write(handle, value)

  @doc """
  Change the direction of the GPIO
  """
  @spec set_direction(t(), GPIO2.direction()) :: :ok | {:error, atom()}
  def set_direction(handle, direction)

  @doc """
  Change the pull mode of an input GPIO
  """
  @spec set_pull_mode(t(), GPIO2.pull_mode()) :: :ok | {:error, atom()}
  def set_pull_mode(handle, mode)

  @doc """
  Free up resources associated with the handle

  Well behaved backends free up their resources with the help of the Erlang garbage collector. However, it is good
  practice for users to call `Circuits.GPIO2.close/1` (and hence this function) so that
  limited resources are freed before they're needed again.
  """
  @spec close(t()) :: :ok
  def close(handle)

  @spec set_interrupts(t(), GPIO2.trigger(), GPIO2.interrupt_options()) :: :ok | {:error, atom()}
  def set_interrupts(handle, trigger, options)

  @spec info(t()) :: info()
  def info(handle)
end
