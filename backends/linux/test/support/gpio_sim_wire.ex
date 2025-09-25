# SPDX-FileCopyrightText: 2025 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule GPIOSimWire do
  use GenServer

  @poll_interval 10

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  @impl GenServer
  def init(init_args) do
    read_gpio = Keyword.fetch!(init_args, :read)
    write_gpio = Keyword.fetch!(init_args, :write)

    read_path = Path.join(GPIOSim.line_path(read_gpio), "value")
    write_path = Path.join(GPIOSim.line_path(write_gpio), "pull")

    {:ok, %{value: nil, read_path: read_path, write_path: write_path}, @poll_interval}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    new_value = File.read!(state.read_path)

    if new_value != state.value do
      File.write!(state.write_path, value_to_pull(new_value))
      {:noreply, %{state | value: new_value}, @poll_interval}
    else
      {:noreply, state, @poll_interval}
    end
  end

  defp value_to_pull("0" <> _), do: "pull-down"
  defp value_to_pull("1" <> _), do: "pull-up"
end
