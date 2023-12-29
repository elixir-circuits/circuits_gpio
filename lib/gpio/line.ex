# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Line do
  @moduledoc """
  Information about a GPIO line returned from `GPIO.enumerate/0`
  """
  alias Circuits.GPIO

  defstruct [:gpio_spec, :label, :controller]

  @typedoc """
  Line information

  * `:gpio_spec` - the gpio spec to pass to `GPIO.open/3` to use the GPIO
  * `:controller` - the GPIO controller name or an empty string if unnamed
  * `:label` - a controller label, line label tuple. Could have empty strings if no labels
  """
  @type t() :: %__MODULE__{
          gpio_spec: GPIO.gpio_spec(),
          controller: GPIO.controller(),
          label: {GPIO.label(), GPIO.label()}
        }
end
