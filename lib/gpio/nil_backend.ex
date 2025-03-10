# SPDX-FileCopyrightText: 2023 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.NilBackend do
  @moduledoc """
  Circuits.GPIO backend when nothing else is available
  """
  @behaviour Circuits.GPIO.Backend

  alias Circuits.GPIO.Backend

  @impl Backend
  def enumerate(_options) do
    []
  end

  @impl Backend
  def identifiers(_gpio_spec, _options) do
    {:error, :not_found}
  end

  @impl Backend
  def status(_gpio_spec, _options) do
    {:error, :not_found}
  end

  @impl Backend
  def open(_gpio_spec, _direction, _options) do
    {:error, :unimplemented}
  end

  @impl Backend
  def backend_info() do
    %{name: __MODULE__}
  end
end
