Here's a sample run of using interrupts with the new GPIO API. The "start_link"
methods are currently bogus since there's no process being started or linked,
but it makes the code work for projects that use ElixirALE and manually call
start_link. The event messages are different from ElixirALE in that they now
contain a timestamp as the third element of the tuple. The timestamp sadly
can't use `:erlang.monotonic_time` to my knowledge, but it is in nanoseconds
and can be subtracted to durations between GPIO state changes.

```elixir
iex(nerves@nerves.local)4> {:ok, gpio}=ElixirALE.GPIO.start_link(17, :input)
load
gpio_poller_thread started
{:ok, #Reference<0.1118475634.269090828.119157>}
iex(nerves@nerves.local)5> {:ok, gpio2}=ElixirALE.GPIO.start_link(18, :input)
{:ok, #Reference<0.1118475634.269090828.119158>}
iex(nerves@nerves.local)6> ElixirALE.GPIO.set_int(gpio, :both)
:ok
iex(nerves@nerves.local)7> ElixirALE.GPIO.set_int(gpio2, :both)
:ok
iex(nerves@nerves.local)8> flush
{:elixir_ale, 17, 201873252000, 0}
{:elixir_ale, 18, 205733492000, 0}
:ok
iex(nerves@nerves.local)9> flush
{:elixir_ale, 17, 213186393000, 1}
{:elixir_ale, 17, 213373765000, 0}
{:elixir_ale, 18, 213413231000, 1}
{:elixir_ale, 18, 213584244000, 0}
{:elixir_ale, 17, 213617024000, 1}
{:elixir_ale, 17, 213760640000, 0}
{:elixir_ale, 18, 213787687000, 1}
{:elixir_ale, 18, 213934529000, 0}
{:elixir_ale, 17, 213934772000, 1}
{:elixir_ale, 17, 214073885000, 0}
{:elixir_ale, 18, 214080096000, 1}
{:elixir_ale, 18, 214224770000, 0}
:ok
iex(nerves@nerves.local)11> ElixirALE.GPIO.read(gpio)
0
iex(nerves@nerves.local)12> ElixirALE.GPIO.read(gpio)
1
iex(nerves@nerves.local)13> flush
{:elixir_ale, 17, 475695798000, 1}
:ok
```
