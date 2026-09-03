module Elelem::Streaming
  # The second block parameter: a handle on the turn in progress, so a caller
  # watching events can ask for it to end.
  #
  # ```
  # reply, report = client.send(session, model) do |event, turn|
  #   turn.stop if user_pressed_escape?
  #   present(event)
  # end
  # ```
  #
  # ## Cooperative, not an exception
  #
  # `SCOPE.md` argues this at length and the short version is: raising from
  # inside the caller's block unwinds through the client mid-parse, leaving it
  # to reconstruct state while handling control flow, which is where subtle
  # bugs live. Setting a flag lets the client stop at a frame boundary — a
  # point it chose — and finalise through exactly the path a complete stream
  # takes.
  #
  # ## Stopping is not repairing
  #
  # A stopped turn is finalised normally: the same assembler, the same
  # `export_reply`, the same `MPSH::Message`. Whatever frames arrived are
  # translated, and nothing is thrown away.
  #
  # Which means a deliberately stopped turn and a silently truncated one look
  # **identical** here, and that is correct rather than a gap. Both are a
  # stream that ended before its terminal frame. What either should *mean* for
  # a session left holding a half-finished tool call is `SCOPE.md`'s remaining
  # MUST FIX, and it is not answered by this type. A caller stopping a turn
  # today gets an honest partial reply and is responsible for what it does with
  # it, the same as a caller whose connection dropped.
  #
  # ## Deliberately not an interruption reason
  #
  # `#stop` takes no cause. The cause of an interruption matters to the
  # caller's *next* move — await input, back off, retry — and the caller is the
  # one who knows it, having just decided to stop. Threading it through here
  # would be handing someone their own value back.
  class Turn
    def initialize
      @stopped = false
    end

    # Ask for the turn to end after the current frame. Idempotent; calling it
    # twice is not an error, because a block that calls it on every event after
    # the first is a perfectly reasonable block.
    def stop : Nil
      @stopped = true
    end

    def stopped? : Bool
      @stopped
    end
  end
end
