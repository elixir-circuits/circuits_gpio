# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.Line do
  @moduledoc """
  Information about a GPIO line returned from `GPIO.enumerate/0`
  """
  alias Circuits.GPIO2

  defstruct [:line_spec, :label, :controller]

  @typedoc """
  Line information

  * `:line_spec` - the line spec to pass to `GPIO.open/3` to use the GPIO
  * `:controller` - the GPIO controller name or an empty string if unnamed
  * `:label` - a controller label, line label tuple. Could have empty strings if no labels
  """
  @type t() :: %__MODULE__{
          line_spec: GPIO2.line_spec(),
          controller: GPIO2.controller(),
          label: {GPIO2.label(), GPIO2.label()}
        }
end
