# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.NilBackend do
  @moduledoc """
  Circuits.GPIO backend when nothing else is available
  """
  @behaviour Circuits.GPIO.Backend

  alias Circuits.GPIO.Backend

  @impl Backend
  def enumerate() do
    []
  end

  @doc """
  Open a GPIO

  No supported options.
  """
  @impl Backend
  def open(_pin_spec, _direction, _options) do
    {:error, :unimplemented}
  end

  @doc """
  Return information about this backend
  """
  @impl Backend
  def info() do
    %{name: __MODULE__}
  end
end
