require "./sse"
require "./event"
require "../mpsh/message"

module Elelem::Streaming
  # Frames in, one `MPSH::Message` out — the per-protocol half of streaming,
  # and the only part of it that differs between the four.
  #
  # ## The rule every implementation follows
  #
  # **Assemble from complete units; deltas are for events.** A frame carrying a
  # finished thing — an output item, a content block, a whole candidate — is
  # accumulated. A frame carrying a fragment is turned into an `Event` and
  # forgotten. Nothing is stitched together from fragments.
  #
  # This is not fussiness. It is what makes an interrupted turn produce
  # something usable: whatever finished arriving is a legitimate partial reply,
  # while a half-received tool call simply never becomes one, because it never
  # completed. A caller that stops a turn gets an honest short answer rather
  # than an answer with an invented tail — and rather than nothing at all,
  # which is what a "keep only the terminal frame" assembler would hand back.
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
