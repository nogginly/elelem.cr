require "./sse"
require "./event"
require "../mpsh/message"

module Elelem::Streaming
  # Frames in, one `MPSH::Message` out — the per-protocol half of streaming,
  # and the only part of it that differs between the four.
  #
  # ## The rule every implementation follows
  #
  # **Never stitch anything whose partial form is invalid.**
  #
  # Text's partial form is valid text: concatenation is exact, a prefix is a
  # legitimate short answer, and nothing about it can be misread. A tool call's
  # partial form is not a tool call — half a JSON arguments blob is unparseable
  # and cannot be dispatched — so a call that was still arriving when the
  # stream ended must simply not appear in the reply.
  #
  # This is what makes an interrupted turn produce something usable rather than
  # something plausible. A caller that stops a turn gets an honest short answer
  # instead of an answer with an invented tail, and a session never ends up
  # holding a call nobody can act on.
  #
  # **What counts as a unit differs by protocol, and that is not a wrinkle in
  # the rule but the reason it is phrased this way.** An earlier version said
  # "assemble from complete units; deltas are for events", which fits Responses
  # exactly — it emits finished items, so fragments can be watched and thrown
  # away. Gemini emits no finished items at all: every chunk is a whole
  # envelope wrapping fragmentary parts, so its text *must* be concatenated,
  # and following the older phrasing literally would have produced a reply
  # consisting of the final fragment. The rule above survives both, because it
  # asks the question that actually matters.
  #
  # ## Why `finish` returns a message and not a wire type
  #
  # So that the single translation path is structural. An assembler builds its
  # own protocol's `Wire::Response` and hands it to the exporter it was
  # constructed with, which means a streamed reply and a non-streamed one meet
  # at `export_reply` having differed only as far as the wire — and are the
  # same `MPSH::Message` by construction rather than by anyone remembering to
  # keep two code paths in step.
  #
  # Concrete assemblers additionally expose their `Wire::Response` for specs to
  # assert against, since that is the level a translation bug is legible at.
  abstract class Assembler
    # Takes one frame, yielding whatever a caller may watch.
    #
    # Yields zero, one or several events. A frame that says nothing worth
    # watching — a keep-alive, a lifecycle marker, something this protocol has
    # gained since this was written — yields none and is not an error.
    abstract def absorb(frame : Sse::Frame, & : Event ->) : Nil

    # Whether a terminal frame arrived.
    #
    # False after a stream that was cut, and false after one the caller
    # stopped. Distinguishing those two is the *client's* job, because only it
    # knows whether anybody asked — see `Client#send`.
    abstract def complete? : Bool

    # The reply, whether the stream finished or not.
    abstract def finish : MPSH::Message
  end
end
