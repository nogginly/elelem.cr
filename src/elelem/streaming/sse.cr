module Elelem::Streaming
  # Server-Sent Events framing, and nothing above it.
  #
  # All four protocols stream over SSE and none of them agrees about what goes
  # *inside* a frame: Anthropic names every frame with an `event:` line, Gemini
  # sends bare `data:` lines, Chat Completions ends with a `data: [DONE]`
  # sentinel that is not JSON at all. So this module reads frames and stops
  # there. Deciding what a frame means is the assembler's job, which is why
  # `Frame` carries a name and a payload and no interpretation of either.
  #
  # One module rather than four, because the framing genuinely is the same
  # framing — this is the one part of streaming where the protocols do not
  # diverge, and writing it four times is how it would come to.
  module Sse
    # One dispatched event: an optional `event:` name and the concatenated
    # `data:` payload.
    #
    # `data` is a `String` rather than parsed JSON because it is not always
    # JSON. Chat Completions' `[DONE]` is the standing counter-example, and a
    # parser here would have to either fail on it or special-case one protocol
    # in the shared layer.
    struct Frame
      getter name : String?
      getter data : String

      def initialize(@data : String, @name : String? = nil)
      end
    end

    # Reads frames until the stream ends.
    #
    # **A trailing partial frame is discarded, and that is load-bearing.** The
    # SSE specification says any data pending when the stream ends is dropped,
    # and following it here is what makes a cut stream *detectable*: a
    # truncated body's final fragment never reaches an assembler, so no
    # terminal frame is seen and `SCOPE.md`'s class-3 interruption shows up as
    # the absence it actually is. Dispatching the fragment instead would let a
    # half-written terminal frame masquerade as a complete one.
    #
    # The cost is named rather than hidden: a server that omits the final blank
    # line after its last event loses that event here. That is a real risk with
    # compatibility ports, it is exactly the kind of divergence
    # `docs/STREAMING_DESIGN.md` expects from emulators, and a live recording
    # settles it in a way that reasoning about it cannot.
    #
    # Line endings: `gets(chomp: true)` handles `\n` and `\r\n`. A lone `\r` as
    # a separator is legal SSE and is not handled, because no protocol here
    # sends one; if a server ever does, the symptom is one enormous frame
    # rather than a subtle mis-parse.
    def self.each_frame(io : IO, & : Frame ->) : Nil
      name = nil.as(String?)
      data = [] of String

      while line = io.gets(chomp: true)
        if line.empty?
          yield Frame.new(data.join('\n'), name) unless data.empty?
          name = nil
          data.clear
          next
        end

        # A line beginning with a colon is a comment. Every one of these
        # endpoints uses them as keep-alives, so this is the common case on a
        # slow generation rather than an oddity.
        next if line.starts_with?(':')

        field, _, value = line.partition(":")
        # Exactly one leading space is stripped, per the specification —
        # not `lstrip`, which would eat indentation that belongs to the
        # payload.
        value = value[1..] if value.starts_with?(' ')

        # `id` and `retry` are read by clients that reconnect. This one never
        # does — `docs/STREAMING_DESIGN.md` puts resumption out of scope, since
        # it needs a server-side handle and that is the provider-owns-history
        # model this shard rejects — so they fall through and are dropped
        # rather than stored somewhere nothing reads.
        case field
        when "event" then name = value
        when "data"  then data << value
        end
      end
    end
  end
end
