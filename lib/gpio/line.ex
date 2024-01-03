# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Line do
  @moduledoc """
  Information about a GPIO line

  See `Circuits.GPIO.enumerate/0` and `Circuits.GPIO.line_info/1`.
  """
  alias Circuits.GPIO

  @derive {Inspect, optional: [:label, :controller, :consumer]}

  defstruct gpio_spec: nil, label: "", controller: "", consumer: ""

  @typedoc """
  Line information

  * `:gpio_spec` - the gpio spec to pass to `GPIO.open/3` to use the GPIO
  * `:controller` - a GPIO controller label or description. Empty string if unused
  * `:label` - a label for the line. This could also be passed to
    `GPIO.open/3`. Empty string if no label
  * `:consumer` - a hint at who's using the GPIO. Empty string if unused or unknown
  """
  @type t() :: %__MODULE__{
          gpio_spec: GPIO.gpio_spec(),
          controller: GPIO.controller() | GPIO.label(),
          label: GPIO.label(),
          consumer: String.t()
        }
end
