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
  import Bitwise
  alias Circuits.GPIO

  @type gpio_pair :: {GPIO.gpio_spec(), GPIO.gpio_spec()}

  @doc """
  Reminder for how to use report/1
  """
  @spec report() :: String.t()
  def report() do
    "Externally connect one or more GPIO pairs. Pass a list of {output_gpio_spec, input_gpio_spec} tuples to report/1."
  end

  @doc """
  Run GPIO diagnostics and print a report

  Connect each output GPIO to the corresponding input GPIO. When using the cdev
  stub implementation, any connected pairs can be used. For example, run:

  ```elixir
  Circuits.GPIO.Diagnostics.report([
    {{"gpiochip0", 0}, {"gpiochip0", 1}},
    {{"gpiochip0", 2}, {"gpiochip0", 3}}
  ])
  ```

  Pass more than one pair to also run multi-GPIO group diagnostics. This
  function is intended for IEx prompt usage. See `run/1` for programmatic use.
  """
  @spec report([gpio_pair()]) :: boolean
  def report([{_, _} | _] = gpio_pairs) do
    identifier_pairs =
      Enum.map(gpio_pairs, fn {out_gpio_spec, in_gpio_spec} ->
        {:ok, out_identifiers} = GPIO.identifiers(out_gpio_spec)
        {:ok, in_identifiers} = GPIO.identifiers(in_gpio_spec)
        {out_identifiers, in_identifiers}
      end)

    results = run(gpio_pairs)
    passed = Enum.all?(results, fn {_, result} -> result == :ok end)
    check_connections? = Enum.any?(results, &connection_failure?/1)
    speed_gpio_spec = gpio_pairs |> hd() |> elem(0)
    speed_results = speed_test(speed_gpio_spec)

    [
      diagnostics_header(gpio_pairs, identifier_pairs),
      Enum.map(results, &pass_text/1),
      """

      Speed test output GPIO: #{inspect(speed_gpio_spec)}

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

  @doc """
  Run diagnostics and print a report for a single pair of GPIOs

  This calls `report/1`.
  """
  @spec report(GPIO.gpio_spec(), GPIO.gpio_spec()) :: boolean
  def report(out_gpio_spec, in_gpio_spec), do: report([{out_gpio_spec, in_gpio_spec}])

  defp pass_text({name, :ok}), do: [name, ": ", :green, "PASSED", :reset, "\n"]

  defp pass_text({name, {:error, reason}}),
    do: [name, ": ", :red, "FAILED", :reset, " ", reason, "\n"]

  defp diagnostics_header([{out_gpio_spec, in_gpio_spec}], [{out_identifiers, in_identifiers}]) do
    """
    Circuits.GPIO Diagnostics #{Application.spec(:circuits_gpio)[:vsn]}

    Output GPIO: #{inspect(out_gpio_spec)}
    Input GPIO:  #{inspect(in_gpio_spec)}

    Output ids:  #{inspect(out_identifiers)}
    Input ids:   #{inspect(in_identifiers)}
    Backend: #{inspect(Circuits.GPIO.backend_info()[:name])}

    """
  end

  defp diagnostics_header(gpio_pairs, identifier_pairs) do
    pair_text =
      gpio_pairs
      |> Enum.zip(identifier_pairs)
      |> Enum.with_index(1)
      |> Enum.map(fn {{{out_gpio_spec, in_gpio_spec}, {out_identifiers, in_identifiers}}, index} ->
        """
        Pair #{index} output GPIO: #{inspect(out_gpio_spec)}
        Pair #{index} input GPIO:  #{inspect(in_gpio_spec)}
        Pair #{index} output ids:  #{inspect(out_identifiers)}
        Pair #{index} input ids:   #{inspect(in_identifiers)}

        """
      end)

    [
      """
      Circuits.GPIO Diagnostics #{Application.spec(:circuits_gpio)[:vsn]}

      """,
      pair_text,
      "Backend: #{inspect(Circuits.GPIO.backend_info()[:name])}\n\n"
    ]
  end

  defp connection_failure?({name, result}) do
    result != :ok and
      (String.contains?(name, "Simple writes and reads work") or
         String.contains?(name, "Multi-GPIO writes and reads work"))
  end

  defp split_pairs(gpio_pairs) do
    Enum.unzip(gpio_pairs)
  end

  defp all_ones(count), do: bsl(1, count) - 1

  defp alternating_mask(count) do
    Enum.reduce(0..(count - 1), 0, fn bit, acc ->
      if rem(bit, 2) == 0 do
        bor(acc, bsl(1, bit))
      else
        acc
      end
    end)
  end

  defp inverse_alternating_mask(count), do: bxor(alternating_mask(count), all_ones(count))

  defp group_transition_values(count) do
    set_values =
      Enum.scan(0..(count - 1), 0, fn bit, acc ->
        bor(acc, bsl(1, bit))
      end)

    clear_values =
      Enum.scan(0..(count - 1), all_ones(count), fn bit, acc ->
        band(acc, bnot(bsl(1, bit)))
      end)

    set_values ++ clear_values
  end

  @doc """
  Run GPIO tests and return a list of the results
  """
  @spec run([gpio_pair()]) :: list()
  def run([{out_gpio_spec, in_gpio_spec}]) do
    run(out_gpio_spec, in_gpio_spec)
  end

  def run([{_, _} | _] = gpio_pairs) do
    single_results =
      Enum.flat_map(gpio_pairs, fn {out_gpio_spec, in_gpio_spec} ->
        prefix = "Pair #{inspect(out_gpio_spec)} -> #{inspect(in_gpio_spec)}"

        run(out_gpio_spec, in_gpio_spec)
        |> Enum.map(fn {name, result} -> {"#{prefix}: #{name}", result} end)
      end)

    single_results ++ run_multi(gpio_pairs)
  end

  @spec run(GPIO.gpio_spec(), GPIO.gpio_spec()) :: list()
  def run(out_gpio_spec, in_gpio_spec) do
    tests = [
      {"Simple writes and reads work", &check_reading_and_writing/3, []},
      {"Can set 0 on open", &check_setting_initial_value/3, value: 0},
      {"Can set 1 on open", &check_setting_initial_value/3, value: 1},
      {"Input interrupts sent", &check_interrupts/3, []},
      {"Subscribe notifications sent", &check_subscribe/3, []},
      {"Interrupt timing sane", &check_interrupt_timing/3, []},
      {"Internal pullup works", &check_pullup/3, []},
      {"Internal pulldown works", &check_pulldown/3, []},
      {"Open drain drive mode works", &check_open_drain/3, []},
      {"Open source drive mode works", &check_open_source/3, []}
    ]

    Enum.map(tests, &check(&1, out_gpio_spec, in_gpio_spec))
  end

  defp run_multi(gpio_pairs) do
    {out_gpio_specs, in_gpio_specs} = split_pairs(gpio_pairs)
    count = length(out_gpio_specs)

    tests = [
      {"Multi-GPIO writes and reads work", &check_multi_reading_and_writing/3, []},
      {"Multi-GPIO can set alternating bits on open", &check_multi_setting_initial_value/3,
       value: alternating_mask(count)},
      {"Multi-GPIO can set inverse alternating bits on open",
       &check_multi_setting_initial_value/3, value: inverse_alternating_mask(count)},
      {"Multi-GPIO subscribe notifications sent", &check_multi_subscribe/3, []},
      {"Multi-GPIO notification timing sane", &check_multi_interrupt_timing/3, []},
      {"Multi-GPIO internal pullup works", &check_multi_pullup/3, []},
      {"Multi-GPIO internal pulldown works", &check_multi_pulldown/3, []},
      {"Multi-GPIO open drain drive mode works", &check_multi_open_drain/3, []},
      {"Multi-GPIO open source drive mode works", &check_multi_open_source/3, []}
    ]

    Enum.map(tests, &check(&1, out_gpio_specs, in_gpio_specs))
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
  @spec check_subscribe(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_subscribe(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    {:ok, ref} = GPIO.subscribe(in_gpio)

    # No initial notification
    refute_receive {:circuits_gpio, _}

    # Toggle enough times to avoid being tricked by something that
    # works a few times and then stops.
    for _ <- 1..64 do
      GPIO.write(out_gpio, 1)
      _ = assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

      GPIO.write(out_gpio, 0)
      _ = assert_receive {:circuits_gpio, %{ref: ^ref, value: 0, previous_value: 1}}
    end

    # Unsubscribing stops notifications
    :ok = GPIO.unsubscribe(in_gpio)
    GPIO.write(out_gpio, 1)
    refute_receive {:circuits_gpio, _}

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_interrupt_timing(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_interrupt_timing(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input)

    {:ok, ref} = GPIO.subscribe(in_gpio)

    # No notifications until something changes
    refute_receive {:circuits_gpio, _}

    GPIO.write(out_gpio, 1)
    {_, %{timestamp: first_ns}} = assert_receive {:circuits_gpio, %{ref: ^ref, value: 1}}

    GPIO.write(out_gpio, 0)
    {_, %{timestamp: second_ns}} = assert_receive {:circuits_gpio, %{ref: ^ref, value: 0}}

    # No notifications after this
    refute_receive {:circuits_gpio, _}

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

    # Check pullup by re-opening out_gpio as an input with no pull
    # Note: the default pull_mode is :not_set.
    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :input, pull_mode: :none)

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

    # Check pulldown by re-opening out_gpio as an input with no pull
    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_spec, :input, pull_mode: :none)

    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  # Wait for a released line to settle through its weak pull resistor.
  # Without a wait, the tests actually can fail. 1 ms should be much
  # more than enough time.
  defp settle(), do: Process.sleep(1)

  @doc false
  @spec check_open_drain(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_open_drain(out_gpio_spec, in_gpio_spec, _options) do
    # Note that the pull_mode is set to :none since the default is to not change it.
    {:ok, out_gpio} =
      GPIO.open(out_gpio_spec, :output,
        drive_mode: :open_drain,
        pull_mode: :none,
        initial_value: 1
      )

    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input, pull_mode: :pullup)

    # Writing a 1 releases the line, so the pullup should win
    settle()
    assert GPIO.read(in_gpio) == 1

    # Writing a 0 actively drives the line low even with the pullup
    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    # Stop driving the line. Input should follow its pull mode
    GPIO.write(out_gpio, 1)
    settle()
    assert GPIO.read(in_gpio) == 1
    :ok = GPIO.set_pull_mode(in_gpio, :pulldown)
    settle()
    assert GPIO.read(in_gpio) == 0
    :ok = GPIO.set_pull_mode(in_gpio, :pullup)
    settle()
    assert GPIO.read(in_gpio) == 1

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_open_source(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_open_source(out_gpio_spec, in_gpio_spec, _options) do
    {:ok, out_gpio} =
      GPIO.open(out_gpio_spec, :output,
        drive_mode: :open_source,
        pull_mode: :none,
        initial_value: 0
      )

    {:ok, in_gpio} = GPIO.open(in_gpio_spec, :input, pull_mode: :pulldown)

    # Writing a 0 releases the line, so the pulldown should win
    settle()
    assert GPIO.read(in_gpio) == 0

    # Writing a 1 actively drives the line high even with the pulldown
    GPIO.write(out_gpio, 1)
    assert GPIO.read(in_gpio) == 1

    # Stop driving the line. Input should follow its pull mode
    GPIO.write(out_gpio, 0)
    settle()
    assert GPIO.read(in_gpio) == 0
    :ok = GPIO.set_pull_mode(in_gpio, :pullup)
    settle()
    assert GPIO.read(in_gpio) == 1
    :ok = GPIO.set_pull_mode(in_gpio, :pulldown)
    settle()
    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_reading_and_writing([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_reading_and_writing(out_gpio_specs, in_gpio_specs, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input)

    assert GPIO.read(in_gpio) == 0

    for value <- group_transition_values(length(out_gpio_specs)) do
      GPIO.write(out_gpio, value)
      assert GPIO.read(in_gpio) == value
    end

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_setting_initial_value([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) ::
          :ok
  def check_multi_setting_initial_value(out_gpio_specs, in_gpio_specs, options) do
    value = options[:value]
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output, initial_value: value)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input)

    assert GPIO.read(in_gpio) == value

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_subscribe([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_subscribe(out_gpio_specs, in_gpio_specs, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input)

    {:ok, ref} = GPIO.subscribe(in_gpio)

    refute_receive {:circuits_gpio, _}

    previous_value =
      Enum.reduce(group_transition_values(length(out_gpio_specs)), 0, fn value, previous_value ->
        GPIO.write(out_gpio, value)

        _ =
          assert_receive {:circuits_gpio,
                          %{ref: ^ref, value: ^value, previous_value: ^previous_value}}

        assert Bitwise.bxor(value, previous_value) |> power_of_two?()
        value
      end)

    :ok = GPIO.unsubscribe(in_gpio)
    GPIO.write(out_gpio, bxor(previous_value, all_ones(length(out_gpio_specs))))
    refute_receive {:circuits_gpio, _}

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  defp power_of_two?(value), do: value > 0 and band(value, value - 1) == 0

  @doc false
  @spec check_multi_interrupt_timing([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_interrupt_timing(out_gpio_specs, in_gpio_specs, _options) do
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input)

    {:ok, ref} = GPIO.subscribe(in_gpio)

    refute_receive {:circuits_gpio, _}

    [first_value, second_value | _] = group_transition_values(length(out_gpio_specs))

    GPIO.write(out_gpio, first_value)

    {_, %{timestamp: first_ns}} =
      assert_receive {:circuits_gpio, %{ref: ^ref, value: ^first_value}}

    GPIO.write(out_gpio, second_value)

    {_, %{timestamp: second_ns}} =
      assert_receive {:circuits_gpio, %{ref: ^ref, value: ^second_value}}

    refute_receive {:circuits_gpio, _}

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)

    assert first_ns < second_ns
    assert second_ns - first_ns < 100_000_000
    assert second_ns - first_ns > 100

    :ok
  end

  @doc false
  @spec check_multi_pullup([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_pullup(out_gpio_specs, in_gpio_specs, _options) do
    all_ones = all_ones(length(out_gpio_specs))
    mixed_value = alternating_mask(length(out_gpio_specs))

    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output, initial_value: 0)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input, pull_mode: :pullup)

    assert GPIO.read(in_gpio) == 0
    GPIO.write(out_gpio, all_ones)
    assert GPIO.read(in_gpio) == all_ones
    GPIO.write(out_gpio, mixed_value)
    assert GPIO.read(in_gpio) == mixed_value
    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :input, pull_mode: :none)

    assert GPIO.read(in_gpio) == all_ones

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_pulldown([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_pulldown(out_gpio_specs, in_gpio_specs, _options) do
    all_ones = all_ones(length(out_gpio_specs))
    mixed_value = inverse_alternating_mask(length(out_gpio_specs))

    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :output, initial_value: all_ones)
    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input, pull_mode: :pulldown)

    assert GPIO.read(in_gpio) == all_ones
    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0
    GPIO.write(out_gpio, mixed_value)
    assert GPIO.read(in_gpio) == mixed_value
    GPIO.write(out_gpio, all_ones)
    assert GPIO.read(in_gpio) == all_ones

    GPIO.close(out_gpio)
    {:ok, out_gpio} = GPIO.open(out_gpio_specs, :input, pull_mode: :none)

    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_open_drain([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_open_drain(out_gpio_specs, in_gpio_specs, _options) do
    all_ones = all_ones(length(out_gpio_specs))
    mixed_value = alternating_mask(length(out_gpio_specs))

    {:ok, out_gpio} =
      GPIO.open(out_gpio_specs, :output,
        drive_mode: :open_drain,
        pull_mode: :none,
        initial_value: all_ones
      )

    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input, pull_mode: :pullup)

    settle()
    assert GPIO.read(in_gpio) == all_ones

    GPIO.write(out_gpio, mixed_value)
    assert GPIO.read(in_gpio) == mixed_value

    GPIO.write(out_gpio, 0)
    assert GPIO.read(in_gpio) == 0

    GPIO.write(out_gpio, all_ones)
    settle()
    assert GPIO.read(in_gpio) == all_ones
    :ok = GPIO.set_pull_mode(in_gpio, :pulldown)
    settle()
    assert GPIO.read(in_gpio) == 0
    :ok = GPIO.set_pull_mode(in_gpio, :pullup)
    settle()
    assert GPIO.read(in_gpio) == all_ones

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end

  @doc false
  @spec check_multi_open_source([GPIO.gpio_spec()], [GPIO.gpio_spec()], keyword()) :: :ok
  def check_multi_open_source(out_gpio_specs, in_gpio_specs, _options) do
    all_ones = all_ones(length(out_gpio_specs))
    mixed_value = inverse_alternating_mask(length(out_gpio_specs))

    {:ok, out_gpio} =
      GPIO.open(out_gpio_specs, :output,
        drive_mode: :open_source,
        pull_mode: :none,
        initial_value: 0
      )

    {:ok, in_gpio} = GPIO.open(in_gpio_specs, :input, pull_mode: :pulldown)

    settle()
    assert GPIO.read(in_gpio) == 0

    GPIO.write(out_gpio, mixed_value)
    assert GPIO.read(in_gpio) == mixed_value

    GPIO.write(out_gpio, all_ones)
    assert GPIO.read(in_gpio) == all_ones

    GPIO.write(out_gpio, 0)
    settle()
    assert GPIO.read(in_gpio) == 0
    :ok = GPIO.set_pull_mode(in_gpio, :pullup)
    settle()
    assert GPIO.read(in_gpio) == all_ones
    :ok = GPIO.set_pull_mode(in_gpio, :pulldown)
    settle()
    assert GPIO.read(in_gpio) == 0

    GPIO.close(out_gpio)
    GPIO.close(in_gpio)
  end
end
