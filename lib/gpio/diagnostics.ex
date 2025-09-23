# SPDX-FileCopyrightText: 2023 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Connor Rigby
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

  @type options() :: [skip_pullup_tests?: boolean()]

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

  Options:

  * `:skip_pullup_tests?` - set to `true` if the GPIO controller doesn't support
    internal pullups and you don't want to get an error
  """
  @spec report(GPIO.gpio_spec(), GPIO.gpio_spec(), options()) :: boolean
  def report(out_gpio_spec, in_gpio_spec, options \\ []) do
    {:ok, out_identifiers} = GPIO.identifiers(out_gpio_spec)
    {:ok, in_identifiers} = GPIO.identifiers(in_gpio_spec)
    results = run(out_gpio_spec, in_gpio_spec, options)
    passed = Enum.all?(results, fn {_, result} -> result == :ok end)
    check_connections? = hd(results) != {"Simple writes and reads work", :ok}
    speed_results = speed_test(out_gpio_spec)

    [
      """
      Circuits.GPIO Diagnostics #{Application.spec(:circuits_gpio)[:vsn]}

      Output GPIO: #{inspect(out_gpio_spec)}
      Input GPIO:  #{inspect(in_gpio_spec)}

      Output ids:  #{inspect(out_identifiers)}
      Input ids:   #{inspect(in_identifiers)}
      Backend: #{inspect(Circuits.GPIO.backend_info()[:name])}

      """,
      Enum.map(results, &pass_text/1),
      """

      write/2:     #{round(speed_results.write_cps)} calls/s
      read/1:      #{round(speed_results.read_cps)} calls/s
      write_one/3: #{round(speed_results.write_one_cps)} calls/s
      read_one/2:  #{round(speed_results.read_one_cps)} calls/s

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

  Options:

  * `:skip_pullup_tests?` - set to `true` if the GPIO controller doesn't support
    internal pullups and you don't want to get an error
  """
  @spec run(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword) :: list()
  def run(out_gpio_spec, in_gpio_spec, options \\ []) do
    skip_pullup_tests? = Keyword.get(options, :skip_pullup_tests?, false)

    tests = [
      {"Simple writes and reads work", &check_reading_and_writing/3, []},
      {"Can set 0 on open", &check_setting_initial_value/3, value: 0},
      {"Can set 1 on open", &check_setting_initial_value/3, value: 1},
      {"Input interrupts sent", &check_interrupts/3, []},
      {"Interrupt timing sane", &check_interrupt_timing/3, []},
      if(!skip_pullup_tests?, do: {"Internal pullup works", &check_pullup/3, []}),
      if(!skip_pullup_tests?, do: {"Internal pulldown works", &check_pulldown/3, []})
    ]

    tests
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&check(&1, out_gpio_spec, in_gpio_spec))
  end

  @doc """
  Run GPIO API performance tests

  Disclaimer: There should be a better way than relying on the Circuits.GPIO
  write performance on nearly every device. Write performance shouldn't be
  terrible, though.
  """
  @spec speed_test(GPIO.gpio_spec()) :: %{
          write_cps: float(),
          read_cps: float(),
          write_one_cps: float(),
          read_one_cps: float()
        }
  def speed_test(gpio_spec) do
    times = 1000
    one_times = ceil(times / 100)

    {:ok, gpio} = GPIO.open(gpio_spec, :output)
    write_cps = time_fun2(times, &write2/1, gpio)
    GPIO.close(gpio)

    {:ok, gpio} = GPIO.open(gpio_spec, :input)
    read_cps = time_fun2(times, &read2/1, gpio)
    GPIO.close(gpio)

    write_one_cps = time_fun2(one_times, &write_one2/1, gpio_spec)
    read_one_cps = time_fun2(one_times, &read_one2/1, gpio_spec)

    %{
      write_cps: write_cps,
      read_cps: read_cps,
      write_one_cps: write_one_cps,
      read_one_cps: read_one_cps
    }
  end

  defp time_fun2(times, fun, arg) do
    # Check that it works
    _ = fun.(arg)

    # Benchmark it
    {micros, :ok} = :timer.tc(fn -> Enum.each(1..times, fn _ -> fun.(arg) end) end)
    times / micros * 1_000_000 * 2
  end

  defp write2(gpio) do
    GPIO.write(gpio, 0)
    GPIO.write(gpio, 1)
  end

  defp read2(gpio) do
    GPIO.read(gpio)
    GPIO.read(gpio)
  end

  defp write_one2(gpio_spec) do
    _ = GPIO.write_one(gpio_spec, 0)
    _ = GPIO.write_one(gpio_spec, 1)
  end

  defp read_one2(gpio_spec) do
    _ = GPIO.read_one(gpio_spec)
    _ = GPIO.read_one(gpio_spec)
  end

  defmacrop assert(expr) do
    line = __CALLER__.line

    quote do
      if !unquote(expr) do
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
