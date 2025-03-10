# SPDX-FileCopyrightText: 2024 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Diagnostics.CPU do
  @moduledoc """
  CPU
  """

  @doc """
  Force the CPU to its slowest setting

  This requires the Linux kernel to have the powersave CPU scaling governor available.
  """
  @spec force_slowest() :: :ok
  def force_slowest() do
    cpu_list()
    |> Enum.each(&set_governor(&1, "powersave"))
  end

  @doc """
  Force the CPU to its fastest setting

  This requires the Linux kernel to have the performance CPU scaling governor available.
  """
  @spec force_fastest() :: :ok
  def force_fastest() do
    cpu_list()
    |> Enum.each(&set_governor(&1, "performance"))
  end

  @doc """
  Set the CPU to the specified frequency

  This requires the Linux kernel to have the userspace CPU scaling governor available.
  Not all frequencies are supported. The closest will be picked.
  """
  @spec set_frequency(number()) :: :ok
  def set_frequency(frequency_mhz) do
    cpus = cpu_list()
    Enum.each(cpus, &set_governor(&1, "userspace"))
    Enum.each(cpus, &set_frequency(&1, frequency_mhz))
  end

  defp set_governor(cpu, governor) do
    File.write!("/sys/bus/cpu/devices/#{cpu}/cpufreq/scaling_governor", governor)
  end

  defp set_frequency(cpu, frequency_mhz) do
    frequency_khz = round(frequency_mhz * 1000)
    File.write!("/sys/bus/cpu/devices/#{cpu}/cpufreq/scaling_setspeed", to_string(frequency_khz))
  end

  @doc """
  Return the string names for all CPUs

  CPUs are named `"cpu0"`, `"cpu1"`, etc.
  """
  @spec cpu_list() :: [String.t()]
  def cpu_list() do
    case File.ls("/sys/bus/cpu/devices") do
      {:ok, list} -> Enum.sort(list)
      _ -> []
    end
  end

  @doc """
  Check benchmark suitability and return CPU information
  """
  @spec check_benchmark_suitability() :: %{
          uname: String.t(),
          cpu_count: non_neg_integer(),
          speed_mhz: number(),
          warnings?: boolean()
        }
  def check_benchmark_suitability() do
    cpus = cpu_list()

    scheduler_warnings? = Enum.all?(cpus, &check_cpu_scheduler/1)
    {frequency_warnings?, mhz} = mean_cpu_frequency(cpus)

    %{
      uname: uname(),
      cpu_count: length(cpus),
      speed_mhz: mhz,
      warnings?: scheduler_warnings? or frequency_warnings?
    }
  end

  defp uname() do
    case File.read("/proc/version") do
      {:ok, s} -> String.trim(s)
      {:error, _} -> "Unknown"
    end
  end

  defp check_cpu_scheduler(cpu) do
    case File.read("/sys/bus/cpu/devices/#{cpu}/cpufreq/scaling_governor") do
      {:error, _} ->
        io_warn("Could not check CPU frequency scaling for #{cpu}")
        true

      {:ok, text} ->
        governor = String.trim(text)

        if governor in ["powersave", "performance", "userspace"] do
          false
        else
          io_warn(
            "CPU #{cpu} is using a dynamic CPU frequency governor. Performance results may vary."
          )

          true
        end
    end
  end

  defp cpu_frequency_mhz(cpu) do
    # Report the actual CPU frequency just in case something is throttling the governor (e.g., thermal throttling).
    # The governor's target frequency is in the "scaling_cur_freq" file.
    case File.read("/sys/bus/cpu/devices/#{cpu}/cpufreq/cpuinfo_cur_freq") do
      {:ok, string} -> string |> String.trim() |> String.to_integer() |> Kernel./(1000)
      {:error, _} -> 0.0
    end
  end

  defp mean_cpu_frequency(cpu_list) do
    speeds = cpu_list |> Enum.map(&cpu_frequency_mhz/1)

    case speeds do
      [] ->
        {true, 0.0}

      [speed] ->
        {false, speed}

      [first | _rest] ->
        mean = Enum.sum(speeds) / length(speeds)

        if abs(mean - first) < 0.001 do
          {false, mean}
        else
          io_warn("CPU speeds don't all match: #{inspect(speeds)}")
          {true, mean}
        end
    end
  end

  defp io_warn(text) do
    [:yellow, "WARNING: ", text, :reset]
    |> IO.ANSI.format()
    |> IO.puts()
  end
end
