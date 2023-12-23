# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.Backend do
  @moduledoc """
  Backends provide the connection to the real or virtual GPIO controllers
  """
  alias Circuits.GPIO2
  alias Circuits.GPIO2.Handle
  alias Circuits.GPIO2.Line

  @doc """
  """
  @callback enumerate() :: [Line.t()]

  @doc """
  Open one or more GPIOs

  `gpio_spec` should be a valid GPIO pin specification on the system and `direction`
  should be `:input` or `:output`. If opening as an output, then be sure to set
  the `:initial_value` option if you need the set to be glitch free.

  Options:

  * :initial_value - Set to `:not_set`, `0` or `1` if this is an output.
    `:not_set` is the default.
  * :pull_mode - Set to `:not_set`, `:pullup`, `:pulldown`, or `:none` for an
     input pin. `:not_set` is the default.
  """
  @callback open(
              gpio_spec :: GPIO2.gpio_spec(),
              direction :: GPIO2.direction(),
              options :: GPIO2.open_options()
            ) ::
              {:ok, Handle.t()} | {:error, atom()}

  @doc """
  Return information about this backend
  """
  @callback info() :: map()
end
