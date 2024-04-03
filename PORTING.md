# Porting

## Upgrading Circuits.GPIO 1.0 projects to 2.0

Circuits.GPIO 2.0 supports alternative GPIO hardware and the ability to mock or
emulate devices via backends. The Linux cdev backend is the default and usage is
similar to Circuits.GPIO 1.0. Most projects won't need any changes other than to
update the dependency in `mix.exs`. If upgrading a library, The following
dependency specification is recommended to allow both `circuits_gpio` versions:

```elixir
   {:circuits_gpio, "~> 2.0 or ~> 1.0"}
```

The following breaking changes were made:

1. `Circuits.GPIO.open/3` opens an exclusive reference to the GPIO. It's no
   longer possible to have multiple processes open the same GPIO. This sometimes
   comes up when GPIOs are not closed when they're done being used. The garbage
   collector will eventually close the GPIO, so you may see intermittent failed
   opens. The solution is either to open once and pass the handle around or to
   explicitly close handles after usage.
2. `Circuits.GPIO.open/3` accepts more general pin specifications called
   `gpio_spec`s. This allows you to specify GPIO controllers and refer to pins
   by labels. Please see `t:Circuits.GPIO.gpio_spec/0` since referring to pins
   by number is brittle and has broken in the past.
3. `Circuits.GPIO.open/3` no longer can preserve the previous output value on
   a pin automatically. I.e., `initial_value: :not_set` is no longer supported.
4. Reading the values of output GPIOs is not supported. This does have a chance
   of working depending on the backend, but it's no longer a requirement of the
   API since some backends may not be readable. The workaround is to cache what
   you wrote.
5. `Circuits.GPIO.set_interrupts/3` does not send an initial notification.
   Notifications are ONLY sent on GPIO transitions now.
6. The `stub` implementation still exists and is useful for testing the cdev NIF
   interface. It's possible to have alternative GPIO backends now so more
   complicated testing backends can be created. If you have simple needs, it's
   still available when compiled with `MIX_ENV=test` and when the backend is
   specified to be `{Circuits.GPIO.CDev, test: true}`. See the `README.md` for
   more information.
7. `Circuits.GPIO.pin/1` is no longer available.

You should hopefully find that the semantics of API are more explicit now or at
least the function documentation is more clear. This was necessary to support
more backends without requiring backend authors to implement features that are
trickier than you'd expect.

If you find that you have to make any other changes, please let us know via an
issue or PR so that other users can benefit.
