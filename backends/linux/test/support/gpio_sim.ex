defmodule GPIOSim do
  alias Circuits.GPIO

  def all_gpios() do
    [
      "gpio_sim_line_0",
      "gpio_sim_line_1",
      "gpio_sim_line_2",
      "gpio_sim_line_3",
      "gpio_sim_line_4",
      "gpio_sim_line_5",
      "gpio_sim_line_6",
      "gpio_sim_line_7"
    ]
  end

  @spec detected?() :: boolean()
  def detected?() do
    first_gpio = hd(all_gpios())
    File.exists?(line_path(first_gpio))
  end

  @spec line_path(String.t()) :: String.t()
  def line_path(gpio_name) do
    {:ok, %{location: {gpiochip, line}, controller: controller}} = GPIO.identifiers(gpio_name)
    base_controller = String.replace(controller, "-node0", "")
    "/sys/devices/platform/#{base_controller}/#{gpiochip}/sim_gpio#{line}"
  end

  @spec write(String.t(), 0 | 1) :: :ok
  def write(gpio_name, value) do
    pull_path = Path.join(line_path(gpio_name), "pull")
    pull_dir = if value > 0, do: "pull-up", else: "pull-down"
    File.write!(pull_path, pull_dir)
  end

  @spec read(String.t()) :: 0 | 1
  def read(gpio_name) do
    value_path = Path.join(line_path(gpio_name), "value")
    File.read!(value_path) |> value_to_int()
  end

  defp value_to_int("0" <> _), do: 0
  defp value_to_int("1" <> _), do: 1
end
