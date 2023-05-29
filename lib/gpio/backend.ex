# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Backend do
  @moduledoc """
  Backends provide the connection to the real or virtual GPIO controllers
  """
  alias Circuits.GPIO
  alias Circuits.GPIO.Handle

  @doc """
  Open one or more GPIOs

  `pin_spec` should be a valid GPIO pin specification on the system and `direction`
  should be `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option if you need the set to be glitch free.

  Options:

  * :initial_value - Set to `:not_set`, `0` or `1` if this is an output.
    `:not_set` is the default.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.
  """
  @callback open(
              pin_spec :: GPIO.pin_spec(),
              direction :: GPIO.pin_direction(),
              options :: GPIO.open_options()
            ) ::
              {:ok, Handle.t()} | {:error, atom()}

  @doc """
  Return information about this backend
  """
  @callback info() :: map()
end
