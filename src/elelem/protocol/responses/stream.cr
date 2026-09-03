require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Elelem::Protocol::Responses
  # Frames from the Responses protocol, assembled back into a `Wire::Response`.
  #
  # ## Three kinds of frame, three different fates
  #
  # **Deltas become events and are discarded.** `response.output_text.delta`
  # and friends carry fragments. They are what a person watches and they are
  # never stored, because storing them would mean stitching them, and stitching
  # them would mean a second implementation of the reader that has to agree
  # with the first forever.
  #
  # **`response.output_item.done` frames are accumulated.** Each carries one
  # finished item — a message, a function call, a reasoning trace — in exactly
  # the shape `Wire::Response` already reads. So accumulation is `<<`, and the
  # partial reply is made of complete parts by construction. A tool call whose
  # arguments were still arriving when the stream ended never completed, so it
  # never enters the reply, which is the right answer rather than a limitation.
  #
  # **The terminal frame wins outright.** `response.completed` carries the
  # entire response object, so when it arrives it replaces the accumulation.
  # Not because the accumulation is suspect, but because the vendor's own
  # assembly is definitionally correct and there is no reason to prefer ours.
  #
  # ## The accumulation is kept even so
  #
  # `accumulated` survives the terminal frame, and exists for one reason: it
  # makes this protocol the only one of the four with a **free correctness
  # oracle**. Every other assembler can be checked only against a hand-written
  # expectation, which is a spec agreeing with whoever wrote it. Here, a live
  # transcript lets `accumulated.output` be compared against the vendor's own
  # `output` on real data — a real disagreement, if there is one, rather than a
  # restatement.
  #
  # This is what made Responses the right protocol to build first, and it is
  # why the shortcut of keeping only the terminal frame was rejected: that
  # shortcut assembles nothing, so there is nothing left to check against.
  class Assembler < ::Elelem::Streaming::Assembler
    def initialize(@exporter : Exporter)
      @items = [] of JSON::Any
      @completed = nil.as(JSON::Any?)
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = decode(frame.data)
      return unless payload

      # The `event:` line and the payload's own `type` say the same thing, and
      # this prefers the line while accepting either. Compatibility ports have
      # been known to send bare `data:` frames with no names at all, and
      # falling back costs nothing.
      kind = frame.name || payload["type"]?.try(&.as_s?)

      # Split along the rule this class exists to follow: what a watcher sees
      # is here, what the reply is made of is in `record`. Nothing appears in
      # both, which is the invariant — a delta is never stored and a finished
      # item is never a fragment.
      case kind
      when "response.output_text.delta"
        if text = delta(payload)
          yield Streaming::TextDelta.new(text)
        end
      when "response.reasoning_summary_text.delta"
        if text = delta(payload)
          yield Streaming::ReasoningDelta.new(text)
        end
      when "response.output_item.added"
        if name = tool_name(payload)
          yield Streaming::ToolCallStarted.new(name)
        end
      else
        record(kind, payload)
      end
    end

    # Frames that change what the reply will be, and are never watched.
    private def record(kind : String?, payload : JSON::Any) : Nil
      case kind
      when "response.output_item.done"
        payload["item"]?.try { |item| @items << item }
      when "response.completed", "response.incomplete"
        # `incomplete` is terminal too, and is not a failure: the model hit a
        # limit and the object describes honestly what it managed. Its `status`
        # reaches the reply's metadata like any other, so a caller who cares
        # can see it.
        @completed = payload["response"]?
      when "response.failed"
        raise failure(payload)
      when "error"
        raise mid_stream(payload)
      end
    end

    def complete? : Bool
      !@completed.nil?
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    # What `finish` will translate: the vendor's assembly when there is one,
    # ours when the stream did not get that far.
    def response : Wire::Response
      if completed = @completed
        Wire::Response.from_any(completed)
      else
        accumulated
      end
    end

    # Only what finished arriving, whether or not a terminal frame came later.
    #
    # `status` is reported as incomplete because, taken alone, that is what
    # this is. When the terminal frame did arrive, `response` is what gets
    # exported and this exists for the oracle described above.
    def accumulated : Wire::Response
      Wire::Response.new(Wire::Response.from_items(@items), status: "incomplete")
    end

    # A frame that will not parse is skipped rather than raised on.
    #
    # Nothing is lost quietly by this. If the unreadable frame was a delta, a
    # watcher misses a fragment that was never authoritative. If it was the
    # terminal frame, `complete?` stays false and `Client#send` raises — so the
    # failure still surfaces, at the place that can tell an interrupted stream
    # from a stopped one.
    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def delta(payload : JSON::Any) : String?
      payload["delta"]?.try(&.as_s?)
    end

    # The name, and deliberately nothing else — see `Streaming::ToolCallStarted`.
    private def tool_name(payload : JSON::Any) : String?
      item = payload["item"]?
      return nil unless item
      return nil unless item["type"]?.try(&.as_s?) == "function_call"
      item["name"]?.try(&.as_s?)
    end

    private def failure(payload : JSON::Any) : StreamError
      error = payload["response"]?.try(&.["error"]?)
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider reported a failed response",
        error.try(&.["code"]?).try(&.as_s?))
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      StreamError.new(NAME,
        payload["message"]?.try(&.as_s?) || "the provider sent an error frame",
        payload["code"]?.try(&.as_s?))
    end
  end
end
