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

  defstruct location: nil, label: "", controller: "", consumer: ""

  @typedoc """
  Line information

  * `:location` - a tuple that contains the controller and GPIO index on that controller
  * `:controller` - the name or an alias for the GPIO controller. Empty string if unused
  * `:label` - a label for the GPIO that could be passed to `GPIO.open/3`. Empty string
    if no label
  * `:consumer` - a hint at who's using the GPIO. Empty string if unused or unknown
  """
  @type t() :: %__MODULE__{
          location: {GPIO.controller(), non_neg_integer()},
          controller: GPIO.controller(),
          label: GPIO.label(),
          consumer: String.t()
        }
end
