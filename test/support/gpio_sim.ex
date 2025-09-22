defmodule GPIOSim do
  alias Circuits.GPIO

  defp line_path(gpio_name) do
    {:ok, %{location: {gpiochip, line}, controller: controller}} = GPIO.identifiers(gpio_name)
    base_controller = String.replace(controller, "-node0", "")
    "/sys/devices/platform/#{base_controller}/#{gpiochip}/sim_gpio#{line}"
  end

  def write(gpio_name, value) do
    pull_path = Path.join(line_path(gpio_name), "pull")
    pull_dir = if value > 0, do: "pull-up", else: "pull-down"
    File.write!(pull_path, pull_dir)
  end

  def read(gpio_name) do
    value_path = Path.join(line_path(gpio_name), "value")
    {value_str, 0} = System.cmd("cat", [value_path])
    String.trim(value_str) |> String.to_integer()
  end
end
