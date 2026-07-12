# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2019 Mark Sebald
# SPDX-FileCopyrightText: 2019 Matt Ludwigs
# SPDX-FileCopyrightText: 2023 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIOTest do
  use ExUnit.Case
  require Circuits.GPIO
  alias Circuits.GPIO

  defmodule ForceCloseBackend do
    @behaviour Circuits.GPIO.Backend

    @impl true
    def enumerate(_options), do: []

    @impl true
    def identifiers(_gpio_spec, _options), do: {:error, :not_found}

    @impl true
    def status(_gpio_spec, _options), do: {:error, :not_found}

    @impl true
    def open(_gpio_spec, _direction, _options) do
      case Process.get(__MODULE__) do
        {:force_closed, _gpio_specs} -> {:ok, :handle}
        _ -> {:error, :already_open}
      end
    end

    @impl true
    def force_close(gpio_spec, _options) do
      gpio_specs =
        case Process.get(__MODULE__) do
          {:force_closed, gpio_specs} -> [gpio_spec | gpio_specs]
          _ -> [gpio_spec]
        end

      Process.put(__MODULE__, {:force_closed, gpio_specs})
      :ok
    end

    @impl true
    def backend_info, do: %{name: __MODULE__}
  end

  doctest GPIO

  setup do
    # Verify the test is being run with a clean environment
    assert GPIO.backend_info().pins_open == 0, "Some other test didn't stop cleanly"

    # Verify that the test leaves the environment clean
    on_exit(fn ->
      assert GPIO.backend_info().pins_open == 0, "Test didn't close all opened GPIOs"
    end)

    :ok
  end

  # not a real gpiochip, just used for testing
  @gpiochip "gpiochip0"

  # Many of these tests take advantage of the "stub" HAL. The "stub"
  # HAL connects GPIO 0 to 1, 2 to 3, etc. It is useful for testing
  # the interface and much of the NIF source code without needing
  # real hardware.

  test "info returns a map" do
    info = GPIO.backend_info()

    assert is_map(info)
    assert info.name == {Circuits.GPIO.CDev, [test: true]}
    assert info.pins_open == 0
  end

  describe "force_close/1" do
    test "closes handles that reference GPIOs" do
      {:ok, first} = GPIO.open({@gpiochip, 0}, :input)
      {:ok, group} = GPIO.open([{@gpiochip, 1}, {@gpiochip, 2}], :input)
      {:ok, last} = GPIO.open({@gpiochip, 3}, :input)

      assert GPIO.backend_info().pins_open == 4

      assert :ok = GPIO.force_close({@gpiochip, 1})
      assert GPIO.backend_info().pins_open == 2

      assert :ok = GPIO.force_close({@gpiochip, 2})
      assert GPIO.backend_info().pins_open == 2

      assert :ok = GPIO.force_close([{@gpiochip, 0}, {@gpiochip, 3}])
      assert GPIO.backend_info().pins_open == 0

      assert :ok = GPIO.close(first)
      assert :ok = GPIO.close(group)
      assert :ok = GPIO.close(last)
    end

    test "closing an empty list succeeds" do
      assert :ok = GPIO.force_close([])
    end

    test "closed GPIOs raise when used" do
      {:ok, gpio1} = GPIO.open({@gpiochip, 0}, :input)
      assert :ok = GPIO.force_close({@gpiochip, 0})
      # Raises :ebadf
      assert_raise ErlangError, fn -> GPIO.read(gpio1) end

      {:ok, gpio2} = GPIO.open({@gpiochip, 0}, :output)
      assert :ok = GPIO.force_close({@gpiochip, 0})
      assert_raise ErlangError, fn -> GPIO.write(gpio2, 0) end

      assert :ok = GPIO.close(gpio1)
      assert :ok = GPIO.close(gpio2)
    end
  end

  describe "identifiers/2" do
    test "all gpio_spec examples" do
      expected = %{
        location: {"gpiochip0", 5},
        label: "pair_2_1",
        controller: "stub0"
      }

      assert GPIO.identifiers(5) == {:ok, expected}
      assert GPIO.identifiers("pair_2_1") == {:ok, expected}
      assert GPIO.identifiers({"gpiochip0", 5}) == {:ok, expected}
      assert GPIO.identifiers({"stub0", 5}) == {:ok, expected}
      assert GPIO.identifiers({"gpiochip0", "pair_2_1"}) == {:ok, expected}
      assert GPIO.identifiers({"stub0", "pair_2_1"}) == {:ok, expected}

      assert GPIO.identifiers(-1) == {:error, :not_found}
      assert GPIO.identifiers(64) == {:error, :not_found}
      assert GPIO.identifiers("something") == {:error, :not_found}
      assert GPIO.identifiers({"gpiochip0", 64}) == {:error, :not_found}
      assert GPIO.identifiers({"stub0", 64}) == {:error, :not_found}
      assert GPIO.identifiers({"gpiochip0", "something"}) == {:error, :not_found}
      assert GPIO.identifiers({"stub0", "something"}) == {:error, :not_found}
    end

    test "lines in stub1" do
      for spec <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
        info = GPIO.identifiers(spec)

        expected_line_info = %{
          location: {"gpiochip1", 1},
          label: "pair_16_1",
          controller: "stub1"
        }

        assert info == {:ok, expected_line_info},
               "Unexpected info for #{inspect(spec)} -> #{inspect(info)}"
      end
    end

    test "nonexistent lines" do
      for spec <- [-1, 65, "pair_100_0", {"stub10", "pair_2_0"}] do
        info = GPIO.identifiers(spec)

        assert info == {:error, :not_found},
               "Unexpected info for #{inspect(spec)} -> #{inspect(info)}"
      end
    end
  end

  describe "status/1" do
    test "all gpio_spec examples" do
      expected = %{consumer: "", direction: :input, pull_mode: :none, drive_mode: :push_pull}

      assert GPIO.status(5) == {:ok, expected}
      assert GPIO.status("pair_2_1") == {:ok, expected}
      assert GPIO.status({"gpiochip0", 5}) == {:ok, expected}
      assert GPIO.status({"stub0", 5}) == {:ok, expected}
      assert GPIO.status({"gpiochip0", "pair_2_1"}) == {:ok, expected}
      assert GPIO.status({"stub0", "pair_2_1"}) == {:ok, expected}

      assert GPIO.status(-1) == {:error, :not_found}
      assert GPIO.status(64) == {:error, :not_found}
      assert GPIO.status("something") == {:error, :not_found}
      assert GPIO.status({"gpiochip0", 64}) == {:error, :not_found}
      assert GPIO.status({"stub0", 64}) == {:error, :not_found}
      assert GPIO.status({"gpiochip0", "something"}) == {:error, :not_found}
      assert GPIO.status({"stub0", "something"}) == {:error, :not_found}
    end

    test "status reports output gpio" do
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :output)

      assert GPIO.status({@gpiochip, 1}) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :output,
                  pull_mode: :none,
                  drive_mode: :push_pull
                }}

      GPIO.close(gpio)
    end

    test "status reports input gpio" do
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)

      assert GPIO.status({@gpiochip, 1}) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :input,
                  pull_mode: :pullup,
                  drive_mode: :push_pull
                }}

      GPIO.close(gpio)
    end

    test "status reports an open GPIO handle" do
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)

      assert GPIO.status(gpio) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :input,
                  pull_mode: :pullup,
                  drive_mode: :push_pull
                }}

      GPIO.close(gpio)
    end

    test "status does not support GPIO groups" do
      {:ok, gpio} = GPIO.open([{@gpiochip, 0}, {@gpiochip, 1}], :input)

      assert GPIO.status(gpio) == {:error, :group_handle}

      GPIO.close(gpio)
    end
  end

  describe "drive_mode" do
    test "can set drive mode in open" do
      {:ok, gpio} = GPIO.open({@gpiochip, 0}, :output, drive_mode: :open_drain)

      assert GPIO.status({@gpiochip, 0}) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :output,
                  pull_mode: :none,
                  drive_mode: :open_drain
                }}

      GPIO.close(gpio)
    end

    test "can change drive mode after open" do
      {:ok, gpio} = GPIO.open({@gpiochip, 0}, :output)
      assert {:ok, %{drive_mode: :push_pull}} = GPIO.status({@gpiochip, 0})

      :ok = GPIO.set_drive_mode(gpio, :open_source)
      assert {:ok, %{drive_mode: :open_source}} = GPIO.status({@gpiochip, 0})

      GPIO.close(gpio)
    end

    test "emulates open-drain in stub" do
      # Pin 0 (output) connected to Pin 1 (input)
      {:ok, out} = GPIO.open({@gpiochip, 0}, :output, drive_mode: :open_drain)
      {:ok, p1} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)

      # 0 pulls line low
      :ok = GPIO.write(out, 0)
      assert GPIO.read(p1) == 0

      # 1 floats, pullup makes it high
      :ok = GPIO.write(out, 1)
      assert GPIO.read(p1) == 1

      # Turning off pullup causes it to float to 0
      :ok = GPIO.set_pull_mode(p1, :none)
      assert GPIO.read(p1) == 0

      GPIO.close(out)
      GPIO.close(p1)
    end

    test "emulates open-source in stub" do
      # Pin 0 (output) connected to Pin 1 (input)
      {:ok, out} = GPIO.open({@gpiochip, 0}, :output, drive_mode: :open_source)
      {:ok, p1} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pulldown)

      # 1 pulls line high
      :ok = GPIO.write(out, 1)
      assert GPIO.read(p1) == 1

      # 0 floats, pulldown makes it low
      :ok = GPIO.write(out, 0)
      assert GPIO.read(p1) == 0

      # Turning off pulldown causes it to float to 0
      :ok = GPIO.set_pull_mode(p1, :none)
      assert GPIO.read(p1) == 0

      GPIO.close(out)
      GPIO.close(p1)
    end

    test "raises ArgumentError for invalid drive modes" do
      assert_raise ArgumentError, fn -> GPIO.open({@gpiochip, 0}, :output, drive_mode: :bogus) end
    end
  end

  test "opening and closing a pin gets counted" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
    assert is_struct(gpio, Circuits.GPIO.CDev)

    assert GPIO.backend_info().pins_open == 1

    GPIO.close(gpio)
    assert GPIO.backend_info().pins_open == 0
  end

  test "open does not force close GPIOs that open successfully" do
    {:ok, previous} = GPIO.open({@gpiochip, 1}, :input)
    {:ok, current} = GPIO.open({@gpiochip, 1}, :input)

    assert GPIO.backend_info().pins_open == 2

    GPIO.close(previous)
    GPIO.close(current)
  end

  test "open retries after force closing an already open GPIO" do
    original_backend = Application.get_env(:circuits_gpio, :default_backend)
    Application.put_env(:circuits_gpio, :default_backend, {ForceCloseBackend, []})

    on_exit(fn ->
      if original_backend do
        Application.put_env(:circuits_gpio, :default_backend, original_backend)
      else
        Application.delete_env(:circuits_gpio, :default_backend)
      end
    end)

    Process.delete(ForceCloseBackend)
    gpio_specs = [{@gpiochip, 1}, {@gpiochip, 2}]

    assert GPIO.open(gpio_specs, :input, on_busy: :take_over) == {:ok, :handle}
    assert Process.get(ForceCloseBackend) == {:force_closed, Enum.reverse(gpio_specs)}

    Process.delete(ForceCloseBackend)
    assert GPIO.open({@gpiochip, 1}, :input, on_busy: :error) == {:error, :already_open}

    # Test default
    Process.delete(ForceCloseBackend)
    assert GPIO.open({@gpiochip, 1}, :input) == {:error, :already_open}

    assert_raise ArgumentError, ":on_busy should be :take_over or :error", fn ->
      GPIO.open({@gpiochip, 1}, :input, on_busy: :invalid)
    end
  end

  test "open returns errors on invalid pins" do
    # The stub returns error on any pin numbers >= 64
    assert GPIO.open({@gpiochip, 100}, :input) == {:error, :not_found}
  end

  test "gpio refs get garbage collected" do
    assert GPIO.backend_info().pins_open == 0

    # Expect that the process dying will free up the pin
    me = self()

    spawn_link(fn ->
      {:ok, _ref} = GPIO.open({@gpiochip, 1}, :input)
      send(me, :done)
    end)

    assert_receive :done

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(10)

    assert GPIO.backend_info().pins_open == 0
  end

  test "lots of gpio refs can be created" do
    assert GPIO.backend_info().pins_open == 0

    # Expect that the process dying will free up all of the pins
    me = self()
    count = 10_000

    {pid, ref} =
      spawn_monitor(fn ->
        x = Enum.map(1..count, fn _ -> {:ok, _ref} = GPIO.open({@gpiochip, 1}, :input) end)
        ^count = GPIO.backend_info().pins_open
        send(me, {:done, length(x)})
      end)

    # Wait to allow spawned task to complete
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    refute Process.alive?(pid)
    assert_receive {:done, ^count}

    :erlang.garbage_collect()

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(100)

    assert GPIO.backend_info().pins_open == 0
  end

  test "can read and write gpio" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.write(gpio0, 1)
    assert GPIO.read(gpio1) == 1
    :ok = GPIO.write(gpio0, 0)
    assert GPIO.read(gpio1) == 0

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can set direction" do
    {:ok, gpio} = GPIO.open({@gpiochip, 0}, :output)
    assert GPIO.set_direction(gpio, :input) == :ok
    assert GPIO.set_direction(gpio, :output) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
    assert GPIO.set_pull_mode(gpio, :not_set) == :ok
    assert GPIO.set_pull_mode(gpio, :none) == :ok
    assert GPIO.set_pull_mode(gpio, :pullup) == :ok
    assert GPIO.set_pull_mode(gpio, :pulldown) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode in open" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)
    GPIO.close(gpio)
  end

  test "raises argument error on invalid gpio_spec" do
    assert_raise ArgumentError, fn -> GPIO.open(:invalid_gpio_spec, :output) end
  end

  test "ignores unknown open options" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, bogus: true)
    GPIO.close(gpio)
  end

  describe "set_interrupts/3" do
    test "no initial interrupt on set_interrupts" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :both)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupts on both edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :both)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

      :ok = GPIO.write(gpio0, 0)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupt with various specs" do
      # Test that interrupts sent the original spec that they were opened with
      for spec1 <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
        {:ok, gpio0} = GPIO.open({"gpiochip1", 0}, :output)
        {:ok, gpio1} = GPIO.open(spec1, :input)

        :ok = GPIO.set_interrupts(gpio1, :both)

        :ok = GPIO.write(gpio0, 1)
        assert_receive {:circuits_gpio, ^spec1, _timestamp, 1}

        :ok = GPIO.write(gpio0, 0)
        assert_receive {:circuits_gpio, ^spec1, _timestamp, 0}

        refute_receive _
        GPIO.close(gpio0)
        GPIO.close(gpio1)
      end
    end

    test "interrupts on falling edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :falling)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      :ok = GPIO.write(gpio0, 1)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

      :ok = GPIO.write(gpio0, 0)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupts on rising edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :rising)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

      :ok = GPIO.write(gpio0, 0)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "can disable interrupts" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :both)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

      :ok = GPIO.set_interrupts(gpio1, :none)
      :ok = GPIO.write(gpio0, 0)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "no interrupts after closing" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      :ok = GPIO.set_interrupts(gpio1, :both)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

      GPIO.close(gpio1)
      Process.sleep(10)

      :ok = GPIO.write(gpio0, 0)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

      GPIO.close(gpio0)
    end
  end

  describe "subscribe/2" do
    test "no initial interrupt" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, _ref} = GPIO.subscribe(gpio1)
      refute_receive _

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupts on both edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, ref} = GPIO.subscribe(gpio1)
      refute_receive _

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

      :ok = GPIO.write(gpio0, 0)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 0, previous_value: 1}}

      refute_receive _
      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "tag replaces the ref in notifications" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, tag} = GPIO.subscribe(gpio1, tag: :button)
      assert tag == :button

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, %{ref: :button, value: 1, previous_value: 0}}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "notifications go to the :receiver process" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      parent = self()
      receiver = spawn_link(fn -> receive do: (msg -> send(parent, {:got, msg})) end)

      {:ok, ref} = GPIO.subscribe(gpio1, receiver: receiver)

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:got, {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}}
      # The subscribing process itself gets nothing
      refute_receive {:circuits_gpio, _}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupt with various specs" do
      # Test that interrupts sent the original spec that they were opened with
      for spec1 <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
        {:ok, gpio0} = GPIO.open({"gpiochip1", 0}, :output)
        {:ok, gpio1} = GPIO.open(spec1, :input)

        {:ok, ref} = GPIO.subscribe(gpio1)
        refute_receive _

        :ok = GPIO.write(gpio0, 1)
        assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

        :ok = GPIO.write(gpio0, 0)
        assert_receive {:circuits_gpio, %{ref: ^ref, value: 0, previous_value: 1}}

        GPIO.close(gpio0)
        GPIO.close(gpio1)
      end
    end

    test "interrupts on falling edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, ref} = GPIO.subscribe(gpio1, trigger: :falling)
      refute_receive _

      :ok = GPIO.write(gpio0, 1)
      refute_receive _

      :ok = GPIO.write(gpio0, 0)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 0, previous_value: 1}}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "interrupts on rising edges" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, ref} = GPIO.subscribe(gpio1, trigger: :rising)
      refute_receive _

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

      :ok = GPIO.write(gpio0, 0)
      refute_receive _

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "can unsubscribe" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, ref} = GPIO.subscribe(gpio1)
      refute_receive _

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

      :ok = GPIO.unsubscribe(gpio1)
      :ok = GPIO.write(gpio0, 0)
      refute_receive _

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end

    test "no messages after closing" do
      {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
      {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

      {:ok, ref} = GPIO.subscribe(gpio1)
      refute_receive _

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 1, previous_value: 0}}

      GPIO.close(gpio1)
      Process.sleep(10)

      :ok = GPIO.write(gpio0, 0)
      refute_receive _

      GPIO.close(gpio0)
    end
  end

  test "opening as an output with no initial_value defaults to 0" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 0}, :input)
    :ok = GPIO.write(gpio0, 1)
    assert GPIO.read(gpio1) == 1
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    assert GPIO.read(gpio1) == 0
    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can set the output on open" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output, initial_value: 1)
    assert GPIO.read(gpio0) == 1
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output, initial_value: 0)
    assert GPIO.read(gpio0) == 0
    GPIO.close(gpio0)
  end

  test "can enumerate GPIOs" do
    result = GPIO.enumerate()
    assert length(result) == 64

    assert hd(result) == %{
             location: {"gpiochip0", 0},
             controller: "stub0",
             label: "pair_0_0"
           }

    assert List.last(result) == %{
             location: {"gpiochip1", 31},
             controller: "stub1",
             label: "pair_31_1"
           }
  end

  test "can open all enumerated GPIOs" do
    result = GPIO.enumerate()

    Enum.each(result, fn info ->
      # This also tests opening by info
      {:ok, ref} = GPIO.open(info, :input)
      GPIO.close(ref)
    end)
  end

  test "unloading NIF" do
    # The theory here is that there shouldn't be a crash if this is reloaded a
    # few times.
    for _times <- 1..10 do
      assert {:module, Circuits.GPIO} == :code.ensure_loaded(Circuits.GPIO)
      assert {:module, Circuits.GPIO.Nif} == :code.ensure_loaded(Circuits.GPIO.Nif)

      # Try running something to verify that it works.
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
      assert is_struct(gpio, Circuits.GPIO.CDev)

      assert GPIO.backend_info().pins_open == 1

      GPIO.close(gpio)
      assert GPIO.backend_info().pins_open == 0

      assert true == :code.delete(Circuits.GPIO.Nif)
      assert true == :code.delete(Circuits.GPIO)

      # The purge will call the unload which can be verified by turning DEBUG on
      # in the C code.
      assert false == :code.purge(Circuits.GPIO.Nif)
      assert false == :code.purge(Circuits.GPIO)
    end
  end

  test "is_gpio_spec/1" do
    assert GPIO.is_gpio_spec("PA8")
    assert GPIO.is_gpio_spec(1 * 1 * 32 + 8)
    assert GPIO.is_gpio_spec({"gpiochip0", 8})
    assert GPIO.is_gpio_spec({"gpiochip0", "PA8"})
    refute GPIO.is_gpio_spec({nil, nil})
    refute GPIO.is_gpio_spec(nil)
    refute GPIO.is_gpio_spec(%{})
  end

  test "gpio_spec?/1" do
    assert GPIO.gpio_spec?("PA8")
    assert GPIO.gpio_spec?(1 * 1 * 32 + 8)
    assert GPIO.gpio_spec?({"gpiochip0", 8})
    assert GPIO.gpio_spec?({"gpiochip0", "PA8"})
    refute GPIO.gpio_spec?({nil, nil})
    refute GPIO.gpio_spec?(nil)
    refute GPIO.gpio_spec?(%{})
  end

  test "refresh enumeration cache" do
    bogus_gpio = %{
      location: {"gpiochip10", 5},
      label: "not_a_gpio",
      controller: "not_a_controller"
    }

    good_gpio = %{
      location: {"gpiochip1", 5},
      label: "pair_18_1",
      controller: "stub1"
    }

    # Set the cache to something bogus and check that it's comes back
    :persistent_term.put(Circuits.GPIO.CDev, [bogus_gpio])
    assert GPIO.identifiers("not_a_gpio") == {:ok, bogus_gpio}

    # Now check that the cache gets refreshed when a gpio isn't found
    assert GPIO.identifiers("pair_18_1") == {:ok, good_gpio}

    # The bogus GPIO doesn't come back
    assert GPIO.identifiers("not_a_gpio") == {:error, :not_found}
  end

  test "write_one/2 + read_one/1" do
    assert GPIO.write_one({@gpiochip, 1}, 0) == :ok
    assert GPIO.read_one({@gpiochip, 0}) == 0
    assert GPIO.write_one({@gpiochip, 1}, 1) == :ok
    assert GPIO.read_one({@gpiochip, 0}) == 1
  end

  test "read_one/2 and write_one/3 do not force close GPIOs that open successfully" do
    {:ok, read_handle} = GPIO.open({@gpiochip, 0}, :input)
    assert GPIO.read_one({@gpiochip, 0}) == 0
    assert GPIO.backend_info().pins_open == 1
    GPIO.close(read_handle)

    {:ok, write_handle} = GPIO.open({@gpiochip, 1}, :input)
    assert GPIO.write_one({@gpiochip, 1}, 1) == :ok
    assert GPIO.backend_info().pins_open == 1
    GPIO.close(write_handle)
  end

  describe "groups" do
    test "read and write a group as a value bitmap" do
      {:ok, out} =
        GPIO.open([{@gpiochip, 0}, {@gpiochip, 2}, {@gpiochip, 4}, {@gpiochip, 6}], :output)

      {:ok, input} =
        GPIO.open([{@gpiochip, 1}, {@gpiochip, 3}, {@gpiochip, 5}, {@gpiochip, 7}], :input)

      :ok = GPIO.write(out, 0b1011)
      assert GPIO.read(input) == 0b1011

      :ok = GPIO.write(out, 0b0100)
      assert GPIO.read(input) == 0b0100

      GPIO.close(out)
      GPIO.close(input)
    end

    test "the first GPIO in the list is the least significant bit" do
      # Open the outputs in reverse so bit 0 of `out` drives line 6.
      {:ok, out} =
        GPIO.open([{@gpiochip, 6}, {@gpiochip, 4}, {@gpiochip, 2}, {@gpiochip, 0}], :output)

      {:ok, input} =
        GPIO.open([{@gpiochip, 1}, {@gpiochip, 3}, {@gpiochip, 5}, {@gpiochip, 7}], :input)

      # out bit 0 -> line 6 -> input bit 3
      :ok = GPIO.write(out, 0b0001)
      assert GPIO.read(input) == 0b1000

      GPIO.close(out)
      GPIO.close(input)
    end

    test "a single GPIO is a one-line group" do
      {:ok, out} = GPIO.open([{@gpiochip, 0}], :output)
      {:ok, input} = GPIO.open([{@gpiochip, 1}], :input)

      :ok = GPIO.write(out, 1)
      assert GPIO.read(input) == 1

      GPIO.close(out)
      GPIO.close(input)
    end

    test "initial_value is a value bitmap" do
      {:ok, out} = GPIO.open([{@gpiochip, 0}, {@gpiochip, 2}], :output, initial_value: 0b10)
      {:ok, input} = GPIO.open([{@gpiochip, 1}, {@gpiochip, 3}], :input)

      assert GPIO.read(input) == 0b10

      GPIO.close(out)
      GPIO.close(input)
    end

    test "rejects lines on multiple controllers" do
      assert GPIO.open([{"gpiochip0", 0}, {"gpiochip1", 0}], :input) ==
               {:error, :multiple_controllers}
    end

    test "rejects duplicate lines" do
      assert GPIO.open([{@gpiochip, 0}, {@gpiochip, 0}], :input) == {:error, :duplicate_lines}
    end

    test "rejects an empty list" do
      assert_raise ArgumentError, fn -> GPIO.open([], :input) end
    end

    test "rejects more than 64 lines" do
      specs = Enum.to_list(0..64)
      assert_raise ArgumentError, fn -> GPIO.open(specs, :input) end
    end

    test "set_interrupts rejects a group handle" do
      {:ok, group} = GPIO.open([{@gpiochip, 1}, {@gpiochip, 3}], :input)
      assert GPIO.set_interrupts(group, :both) == {:error, :group_handle}
      GPIO.close(group)
    end
  end

  describe "subscribe/2 with a group" do
    test "group notifications carry the aggregate value and previous_value" do
      {:ok, out} = GPIO.open([{@gpiochip, 0}, {@gpiochip, 2}], :output)
      {:ok, input} = GPIO.open([{@gpiochip, 1}, {@gpiochip, 3}], :input)

      {:ok, ref} = GPIO.subscribe(input)

      :ok = GPIO.write(out, 0b01)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 0b01, previous_value: 0b00} = msg1}
      # Exactly one line changed
      assert Bitwise.bxor(msg1.value, msg1.previous_value) == 0b01

      :ok = GPIO.write(out, 0b11)
      assert_receive {:circuits_gpio, %{ref: ^ref, value: 0b11, previous_value: 0b01} = msg2}
      assert Bitwise.bxor(msg2.value, msg2.previous_value) == 0b10

      GPIO.close(out)
      GPIO.close(input)
    end
  end
end
