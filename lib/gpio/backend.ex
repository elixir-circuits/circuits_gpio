# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Backend do
  @moduledoc """
  Backends provide the connection to the real or virtual GPIO controllers
  """
  alias Circuits.GPIO
  alias Circuits.GPIO.Handle
  alias Circuits.GPIO.Line

  @doc """
  Return a list of GPIOs

  See the `Line` struct for the information that is returned. The `options` contain
  backend-specific options to help with enumeration.
  """
  @callback enumerate(options :: GPIO.open_options()) :: [Line.t()]

  @doc """
  Return information about a GPIO line

  See `t:gpio_spec/0` for the ways of referring to GPIOs. The `options` contain
  backend-specific options to help enumerating GPIOs.

  If the GPIO is found, this function returns information about the GPIO.
  """
  @callback line_info(
              gpio_spec :: GPIO.gpio_spec(),
              options :: GPIO.open_options()
            ) :: {:ok, Line.t()} | {:error, atom()}

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
  @callback info() :: map()
end
