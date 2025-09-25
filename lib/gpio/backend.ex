# SPDX-FileCopyrightText: 2023 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Backend do
  @moduledoc """
  Backends provide the connection to the real or virtual GPIO controllers
  """
  alias Circuits.GPIO
  alias Circuits.GPIO.Handle

  @doc """
  Return a list of GPIOs

  See `t:GPIO.identifiers/0` for the information that is returned. The `options` contain
  backend-specific options to help with enumeration.
  """
  @callback enumerate(options :: GPIO.open_options()) :: [GPIO.identifiers()]

  @doc """
  Return identifying information about a GPIO

  See `t:gpio_spec/0` for the ways of referring to GPIOs. The `options` contain
  backend-specific options to help enumerating GPIOs.

  If the GPIO is found, this function returns identifying information about the GPIO.
  """
  @callback identifiers(
              gpio_spec :: GPIO.gpio_spec(),
              options :: GPIO.open_options()
            ) :: {:ok, GPIO.identifiers()} | {:error, atom()}

  @doc """
  Return a GPIO's current status

  This function returns how a GPIO is configured. The GPIO doesn't need to be
  opened. It's different from `gpio_identifiers/2` since it returns dynamic information
  whereas `gpio_identifiers/2` only returns information about how to refer to a GPIO
  and where it exists in the system.

  See `t:gpio_spec/0` for the ways of referring to GPIOs. The `options` contain
  backend-specific options to help enumerating GPIOs.

  If the GPIO is found, this function returns its status.
  """
  @callback status(
              gpio_spec :: GPIO.gpio_spec(),
              options :: GPIO.open_options()
            ) :: {:ok, GPIO.status()} | {:error, atom()}

  @doc """
  Open a GPIO

  See `t:gpio_spec/0` for the ways of referring to GPIOs. Set `direction` to
  either `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option to minimize the time the GPIO is in the default
  state.

  Options:

  * :initial_value - Set to `0` or `1`. Only used for outputs. Defaults to `0`.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.

  Returns `{:ok, handle}` on success.
  """
  @callback open(
              gpio_spec :: GPIO.gpio_spec(),
              direction :: GPIO.direction(),
              options :: GPIO.open_options()
            ) ::
              {:ok, Handle.t()} | {:error, atom()}

  @doc """
  Return information about this backend
  """
  @callback backend_info(options :: GPIO.open_options()) :: map()
end
