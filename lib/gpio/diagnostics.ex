# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Diagnostics do
  @moduledoc """
  Runtime diagnostics

  This module provides simple diagnostics to verify GPIO controller and
  implementation differences. Along with the device that you're using, this is
  super helpful for diagnosing issues since some GPIO features aren't supposed
  to work on some devices.
  """
  alias Circuits.GPIO

  @doc """
  Reminder for how to use report/2
  """
  @spec report() :: String.t()
  def report() do
    "Externally connect two GPIOs. Pass the gpio_specs for each to report/2."
  end

  @doc """
  Print a summary of the GPIO diagnostics

  Connect the pins referred to by `out_gpio_spec` and `in_gpio_spec` together.
  When using the cdev stub implementation, any pair of GPIOs can be used. For
  example, run:

  ```elixir
  Circuits.GPIO.Diagnostics.report({"gpiochip0", 0}, {"gpiochip0", 1})
  ```

  This function is intended for IEx prompt usage. See `run/2` for programmatic
  use.
  """
  @spec report(GPIO.gpio_spec(), GPIO.gpio_spec()) :: boolean
  def report(out_gpio_spec, in_gpio_spec) do
    {:ok, out_gpio_info} = GPIO.gpio_info(out_gpio_spec)
    {:ok, in_gpio_info} = GPIO.gpio_info(in_gpio_spec)
    results = run(out_gpio_spec, in_gpio_spec)
    passed = Enum.all?(results, fn {_, result} -> result == :ok end)
    check_connections? = hd(results) != {"Simple writes and reads work", :ok}
    speed_results = speed_test(out_gpio_spec)

    [
      """
      Circuits.GPIO Diagnostics #{Application.spec(:circuits_gpio)[:vsn]}

      Output GPIO: #{inspect(out_gpio_spec)}
      Input GPIO:  #{inspect(in_gpio_spec)}

      Output info: #{inspect(out_gpio_info)}
      Input info:  #{inspect(in_gpio_info)}
      Backend: #{inspect(Circuits.GPIO.info()[:name])}

      """,
      Enum.map(results, &pass_text/1),
      """

      Writes/second: #{round(speed_results.writes_per_sec)}
      Reads/second: #{round(speed_results.reads_per_sec)}

      """,
      if(check_connections?,
        do: [
          :red,
          "Check that the pins are physically connected and the gpio_specs are correct.\n",
          :reset
        ],
        else: []
      ),
      if(passed, do: "All tests passed", else: "Failed")
    ]
    |> IO.ANSI.format()
    |> IO.puts()

    passed
  end

  defp pass_text({name, :ok}), do: [name, ": ", :green, "PASSED", :reset, "\n"]

  defp pass_text({name, {:error, reason}}),
    do: [name, ": ", :red, "FAILED", :reset, " ", reason, "\n"]

  @doc """
  Run GPIO tests and return a list of the results
  """
  @spec run(GPIO.gpio_spec(), GPIO.gpio_spec()) :: list()
  def run(out_gpio_spec, in_gpio_spec) do
    tests = [
      {"Simple writes and reads work", &check_reading_and_writing/3, []},
      {"Can set 0 on open", &check_setting_initial_value/3, value: 0},
      {"Can set 1 on open", &check_setting_initial_value/3, value: 1},
      {"Input interrupts sent", &check_interrupts/3, []},
      {"Interrupt timing sane", &check_interrupt_timing/3, []},
      {"Internal pullup works", &check_pullup/3, []},
      {"Internal pulldown works", &check_pulldown/3, []}
    ]

    tests
    |> Enum.map(&check(&1, out_gpio_spec, in_gpio_spec))
  end

  @doc """
  Run GPIO API performance tests

  Disclaimer: There should be a better way than relying on the Circuits.GPIO
  write performance on nearly every device. Write performance shouldn't be
  terrible, though.
  """
  @spec speed_test(GPIO.gpio_spec()) :: %{writes_per_sec: float(), reads_per_sec: float()}
  def speed_test(gpio_spec) do
    times = 1000

    {:ok, gpio} = GPIO.open(gpio_spec, :output)
    toggle_write(gpio, 10)
    {write_micros, :ok} = :timer.tc(fn -> toggle_read(gpio, times) end)
    GPIO.close(gpio)

    {:ok, gpio} = GPIO.open(gpio_spec, :input)
    toggle_read(gpio, 10)
    {read_micros, :ok} = :timer.tc(fn -> toggle_read(gpio, times) end)

    # 2 ops/toggle
    %{
      writes_per_sec: times / write_micros * 1_000_000 * 2,
      reads_per_sec: times / read_micros * 1_000_000 * 2
    }
  end

  defp toggle_write(gpio, times) do
    Enum.each(1..times, fn _ ->
      GPIO.write(gpio, 0)
      GPIO.write(gpio, 1)
    end)
  end

  defp toggle_read(gpio, times) do
    Enum.each(1..times, fn _ ->
      GPIO.read(gpio)
      GPIO.read(gpio)
    end)
  end

  defmacrop assert(expr) do
    line = __CALLER__.line

    quote do
      unless unquote(expr) do
        raise "#{unquote(line)}: Assertion failed: #{unquote(Macro.to_string(expr))}"
      end
    end
  end

  defmacrop assert_receive(expected, timeout \\ 500) do
    quote do
      receive do
        unquote(expected) = x ->
          x
      after
        unquote(timeout) ->
          raise "Expected message not received within #{unquote(timeout)}ms: #{unquote(Macro.to_string(expected))}"
      end
    end
  end

  defmacrop refute_receive(unexpected, timeout \\ 50) do
    quote do
      receive do
        unquote(unexpected) ->
          raise "Should not have received message within #{unquote(timeout)}ms: #{unquote(Macro.to_string(unexpected))}"
      after
        unquote(timeout) -> :ok
      end
    end
  end

  defp check({name, test, options}, out_gpio_spec, in_gpio_spec) do
    # Run the tests in a process so that GPIO handles get cleaned up and the process
    # mailbox is empty for interrupt checks.
    t = Task.async(fn -> safe_check(test, out_gpio_spec, in_gpio_spec, options) end)

    {name, Task.await(t)}
  rescue
    e ->
      {name, {:error, Exception.message(e)}}
  end

  defp safe_check(test, out_gpio_spec, in_gpio_spec, options) do
    test.(out_gpio_spec, in_gpio_spec, options)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  @spec check_reading_and_writing(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_reading_and_writing(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    GPIO.write(out_gpio, 1)
    assert GPIO.read(in_gpio) == 1

    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_setting_initial_value(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_setting_initial_value(out_gpio_spec, in_gpio_spec, options) do
    value = options[:value]
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: value)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    assert GPIO.read(in_gpio) == value

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_interrupts(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_interrupts(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    :ok = GPIO.set_interrupts(in_gpio, :both)

    # Initial notification
    refute_receive {:circuits_gpio, _spec, _timestamp, _}

    # Toggle enough times to avoid being tricked by something
    # works a few times and then stops.
    for _ <- 1..64 do
      GPIO.write(out_gpio, 1)
      _ = assert_receive {:circuits_gpio, ^in_gpio_spec, _timestamp, 1}

      GPIO.write(out_gpio, 0)
      _ = assert_receive {:circuits_gpio, ^in_gpio_spec, _timestamp, 0}
    end

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_interrupt_timing(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_interrupt_timing(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    :ok = GPIO.set_interrupts(in_gpio, :both)

    # No notifications until something changes
    refute_receive {:circuits_gpio, _, _, _}

    GPIO.write(out_gpio, 1)
    {_, _, first_ns, _} = assert_receive {:circuits_gpio, ^in_gpio_spec, _, 1}

    GPIO.write(out_gpio, 0)
    {_, _, second_ns, _} = assert_receive {:circuits_gpio, ^in_gpio_spec, _, 0}

    # No notifications after this
    refute_receive {:circuits_gpio, _, _, _}

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)

    # Check that the timestamps are ordered and not too far apart.
    assert first_ns < second_ns
    assert second_ns - first_ns < 100_000_000
    assert second_ns - first_ns > 100

    :ok
  end

  @doc false
  @spec check_pullup(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_pullup(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input, pull_mode: :pullup)

    # Check non-pullup case
    assert GPIO.read(in_gpio) == 0
    GPIO.write(out_gpio, 1)
    assert GPIO.read(in_gpio) == 1
    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    # Check pullup by re-opening out_gpio as an input
    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :input)

    assert GPIO.read(in_gpio) == 1

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_pulldown(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_pulldown(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 1)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input, pull_mode: :pulldown)

    # Check non-pullup case
    assert GPIO.read(in_gpio) == 1
    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0
    GPIO.write(out_gpio, 1)
    assert GPIO.read(in_gpio) == 1

    # Check pulldown by re-opening out_gpio as an input
    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :input)

    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end
end
