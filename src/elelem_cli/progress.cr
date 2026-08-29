module Elelem::Cli
  # A "still working" indicator for the stretches where the CLI has nothing
  # to say and no way to know how long it will be saying nothing for.
  #
  # ## Why a clock rather than an event queue
  #
  # The obvious design is for the library to emit progress events and the CLI
  # to render them. That is the right design *when there are events* — which
  # is to say, once streaming lands. Today there is exactly one thing to
  # report ("still waiting") and its source is a clock, not the server, so a
  # queue would be building half of streaming's architecture against a library
  # that has no seam to feed it, while delivering none of streaming's benefit.
  #
  # So: a fiber and a clock, entirely inside the CLI. `Elelem::Client` is
  # unchanged and stays headless.
  #
  # ## What streaming will need from this, and why it will not need a rewrite
  #
  # Streaming does not retire the ticker. Chunks arrive that cannot be shown —
  # a tool call spread over several deltas has to be aggregated before it is
  # parseable, and during that aggregation the CLI is once again waiting with
  # nothing to print. So the indicator survives, it just gets started and
  # stopped repeatedly within one turn instead of wrapping the whole call.
  #
  # Which is why `#start`/`#stop` are public and `.while_waiting` is a
  # convenience built on them, rather than the only door. And why `#label` is
  # mutable: a caller mid-stream can say what it is waiting *for* ("aggregating
  # tool call") without tearing the indicator down and standing a new one up.
  # That is the part of the event-queue idea worth keeping — a settable label —
  # at none of its cost.
  class Progress
    # How often the fiber wakes. Fast enough that the spinner reads as motion
    # rather than as a hung process ticking once a second, slow enough to be
    # four wakeups per second against a request measured in seconds. Tune here.
    TICK = 250.milliseconds

    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]

    property label : String

    def initialize(@label : String, @io : IO = STDERR)
      @stop = Channel(Nil).new
      @drained = Channel(Nil).new
      @running = false
      @width = 0
    end

    # No-op on anything that is not a terminal. Redirected stderr belongs to a
    # log file or a CI transcript, and a few hundred carriage returns and
    # braille glyphs in one is worse than no indicator at all.
    #
    # `STDERR` is the default rather than the only option because the CLI's
    # commands pass `Output.error_stream` instead, which makes `Output` the
    # single switch for everything the CLI emits — without that, silencing the
    # spec suite would have silenced `Output` and left the spinner drawing.
    def start : Nil
      return if @running || !@io.tty?

      @running = true
      started = Time.instant

      spawn do
        frame = 0
        loop do
          select
          when @stop.receive?
            break
          when timeout(TICK)
            draw(FRAMES[frame % FRAMES.size], Time.instant - started)
            frame += 1
          end
        end
        erase
        @drained.close
      end
    end

    # Waits for the fiber to have erased its line before returning, so a caller
    # printing a reply immediately afterwards cannot land on top of a
    # half-drawn spinner.
    def stop : Nil
      return unless @running

      @running = false
      @stop.close
      @drained.receive?
    end

    # Runs the block with the indicator up, and takes it down again whatever
    # happens — a failed request is exactly when a stray spinner left on the
    # line would be most confusing, since the error text lands right after it.
    #
    # Yields the indicator so the block can relabel mid-flight.
    def self.while_waiting(label : String, io : IO = STDERR, &)
      indicator = new(label, io)
      indicator.start
      begin
        yield indicator
      ensure
        indicator.stop
      end
    end

    # Elapsed seconds are the point, not decoration. A spinner alone says the
    # process is alive; "23s" is what tells you whether a local model is being
    # slow or an endpoint is hanging, which is the question actually being
    # asked by the person watching it.
    private def draw(frame : String, elapsed : Time::Span) : Nil
      line = "#{frame} #{@label}… #{elapsed.total_seconds.to_i}s"
      @io.print("\r#{line}")
      @io.flush
      @width = line.size
    end

    private def erase : Nil
      return if @width.zero?
      @io.print("\r#{" " * @width}\r")
      @io.flush
      @width = 0
    end
  end
end
