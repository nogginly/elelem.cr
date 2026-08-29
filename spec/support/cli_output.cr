require "../../src/elelem_cli/output"

# Redirects everything the CLI prints into memory for the duration of the
# block, and returns it as `{stdout, stderr}`.
#
# Two reasons this is shared rather than local to one spec file.
#
# The obvious one: a `crystal spec` run used to be buried under the replies of
# every recorded `start` and `continue`, which made real failures hard to see.
#
# The less obvious one: `Progress` draws a spinner whenever its stream is a
# terminal, and a spec run in a terminal is one. Redirecting `Output` alone
# would not have stopped it, so `start` and `continue` now hand `Progress` the
# `Output.error_stream` rather than `STDERR` directly. That makes `Output` the
# single switch for everything the CLI emits, which is exactly what a helper
# like this needs there to be.
#
# Always restores the real streams, including when the block raises — a spec
# that leaked a closed `IO::Memory` into `Output.stream` would take every
# later spec in the run down with it.
def captured(&) : {String, String}
  printed, warned = IO::Memory.new, IO::Memory.new
  original_stream = Elelem::Cli::Output.stream
  original_error = Elelem::Cli::Output.error_stream

  Elelem::Cli::Output.stream = printed
  Elelem::Cli::Output.error_stream = warned
  begin
    yield
  ensure
    Elelem::Cli::Output.stream = original_stream
    Elelem::Cli::Output.error_stream = original_error
  end

  {printed.to_s, warned.to_s}
end
