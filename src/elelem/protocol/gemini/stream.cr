require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Elelem::Protocol::Gemini
  # Chunks from `:streamGenerateContent?alt=sse`, assembled into a
  # `Wire::Response`.
  #
  # ## This protocol emits no finished units, and that shapes everything
  #
  # Every chunk is a whole `GenerateContentResponse` — envelope, `candidates`,
  # `content`, `parts` — and the parts inside are fragments. Text arrives as
  # `{"text": "Mount "}` then `{"text": "Everest"}`. There is no equivalent of
  # Responses' `output_item.done`, and no terminal chunk carrying the vendor's
  # own assembly of everything that came before.
  #
  # So this assembler concatenates, where the Responses one does not, and the
  # rule in `Streaming::Assembler` is what permits it: text's partial form is
  # valid text. A `functionCall` part is taken whole and never merged, because
  # its partial form would not be a call.
  #
  # ## Each chunk is read by the ordinary reader
  #
  # `Wire::Response.from_any` does the parsing, chunk by chunk. Part reading on
  # this protocol branches on key presence rather than a `type` field, checks
  # `thought` before `text` because a thought part also carries text, and
  # tolerates two spellings of `inlineData`. Every one of those is a trap, and
  # a streaming path with its own copy of them would be a second place to get
  # them wrong. Merging happens on the parsed `Part`, after the reader has
  # already decided what it is.
  #
  # ## No oracle here
  #
  # Responses can check its assembler against the provider's own assembly,
  # because its terminal frame carries the finished object. Nothing in a Gemini
  # stream does. What can be checked is that a streamed reply and a
  # non-streamed one have the same *shape* — and the offline specs pin the
  # merging arithmetic, which is where a bug would actually live.
  class Assembler < ::Elelem::Streaming::Assembler
    def initialize(@exporter : Exporter)
      @parts = [] of Wire::Part
      @role = "model"
      @finish_reason = nil.as(String?)
      @model_version = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @terminal = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = decode(frame.data)
      return unless payload

      # Gemini reports a mid-stream failure by putting an `error` object in a
      # chunk where a candidate would go, rather than by any distinct frame
      # type — there are no frame names on this protocol at all.
      raise mid_stream(payload) if payload["error"]?

      # Carried on the last chunk, usually alone with the finish reason. Kept
      # whenever seen rather than only at the end, since a chunk that carries
      # them and nothing else is not worth a special case.
      payload["modelVersion"]?.try(&.as_s?).try { |value| @model_version = value }
      Wire::Usage.parse(payload["usageMetadata"]?).try { |value| @usage = value }

      return unless payload["candidates"]?
      candidate = Wire::Response.from_any(payload).candidate
      return unless candidate

      @role = candidate.content.role
      candidate.finish_reason.try do |reason|
        @finish_reason = reason
        @terminal = true
      end

      candidate.content.parts.each do |part|
        case part
        when Wire::TextPart
          yield Streaming::TextDelta.new(part.text)
        when Wire::ThoughtPart
          part.text.try { |text| yield Streaming::ReasoningDelta.new(text) }
        when Wire::FunctionCallPart
          yield Streaming::ToolCallStarted.new(part.name)
        end

        merge(part)
      end
    end

    # A finish reason arrived.
    #
    # This protocol has no explicit terminator, so the reason *is* the
    # terminator — including `MAX_TOKENS`, which is a complete stream reporting
    # an incomplete answer rather than a failure, the same way Responses'
    # `response.incomplete` is.
    def complete? : Bool
      @terminal
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      Wire::Response.new(
        [Wire::Candidate.new(0, Wire::Content.new(@role, @parts), @finish_reason)],
        model_version: @model_version,
        usage: @usage)
    end

    # Appends a part, folding it into the previous one when both are text of
    # the same kind.
    #
    # Position matters and is preserved: a reply that thinks, answers, then
    # calls a tool keeps that order, and text arriving on either side of a
    # function call stays on its own side rather than collapsing into one
    # block. Merging only ever touches the *last* part, so an interleaving is
    # never reordered.
    private def merge(part : Wire::Part) : Nil
      last = @parts.last?

      case part
      when Wire::TextPart
        if last.is_a?(Wire::TextPart)
          @parts[-1] = Wire::TextPart.new(last.text + part.text)
          return
        end
      when Wire::ThoughtPart
        if last.is_a?(Wire::ThoughtPart)
          # The signature may arrive on any fragment and must be replayed
          # unmodified, so the newest one wins and an absent one never erases
          # a signature already seen.
          @parts[-1] = Wire::ThoughtPart.new(
            "#{last.text}#{part.text}",
            part.signature || last.signature)
          return
        end
      end

      @parts << part
    end

    # A chunk that will not parse is skipped rather than raised on, for the
    # reason the Responses assembler gives: nothing is lost quietly, because a
    # stream that never delivers a finish reason leaves `complete?` false and
    # `Client#send` raises.
    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = payload["error"]?
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider sent an error chunk",
        error.try(&.["status"]?).try(&.as_s?))
    end
  end
end
