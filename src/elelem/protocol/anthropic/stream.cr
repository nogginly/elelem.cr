require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Elelem::Protocol::Anthropic
  # Frames from Anthropic's message stream, assembled into a `Wire::Response`.
  #
  # ## The first protocol where the rule does real work
  #
  # `Streaming::Assembler`'s rule — never stitch anything whose partial form is
  # invalid — was a single verdict per protocol until now. Responses gives
  # finished items and Gemini gives fragmentary text, so each had one answer.
  # Anthropic gives both **in the same stream**, block by block:
  #
  # - a `text` block's deltas are text, and a prefix of them is a short answer;
  # - a `thinking` block's deltas are the same, though its signature is not;
  # - a `tool_use` block's deltas are `partial_json` — fragments of an
  #   arguments object that mean nothing until the last one arrives.
  #
  # So a stream cut mid-flight keeps the text and the thinking it had, and
  # drops the half-built call, and this assembler decides that per block rather
  # than for the reply. See `#materialise`.
  #
  # ## Blocks are reconstructed, then read by the ordinary reader
  #
  # `content_block_start` carries a block's skeleton, deltas fill it, and
  # `content_block_stop` closes it. Rather than build `Wire::Block`s directly,
  # this rebuilds the JSON object the non-streamed reply would have contained
  # and hands it to `Wire::Response.from_content_block`. That keeps one
  # understanding of what a block is — including the suffix rule that makes an
  # unheard-of `*_tool_result` read as provider-run, which a second reader
  # would have had to remember to reproduce.
  #
  # ## Indices, not order
  #
  # Every block frame carries an `index`, and Anthropic does not promise those
  # arrive in order or without gaps. Blocks are therefore held in a hash keyed
  # by index and sorted on the way out, rather than pushed onto an array in
  # arrival order.
  class Assembler < ::Elelem::Streaming::Assembler
    # One content block being built.
    class Pending
      getter skeleton : JSON::Any
      property text : String
      property json : String
      property signature : String?
      property? closed : Bool

      def initialize(@skeleton : JSON::Any)
        @text = ""
        @json = ""
        @signature = nil
        @closed = false
      end

      def kind : String?
        @skeleton["type"]?.try(&.as_s?)
      end
    end

    def initialize(@exporter : Exporter)
      @blocks = {} of Int32 => Pending
      @id = nil.as(String?)
      @model = nil.as(String?)
      @role = "assistant"
      @stop_reason = nil.as(String?)
      @stop_sequence = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @terminal = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = decode(frame.data)
      return unless payload

      case frame.name || payload["type"]?.try(&.as_s?)
      when "content_block_delta"
        index = index_of(payload)
        return unless index
        pending = @blocks[index]?
        return unless pending

        delta = payload["delta"]?
        return unless delta

        case delta["type"]?.try(&.as_s?)
        when "text_delta"
          delta["text"]?.try(&.as_s?).try do |text|
            pending.text += text
            yield Streaming::TextDelta.new(text)
          end
        when "thinking_delta"
          delta["thinking"]?.try(&.as_s?).try do |text|
            pending.text += text
            yield Streaming::ReasoningDelta.new(text)
          end
        when "input_json_delta"
          # Deliberately silent. These are fragments of a tool call's
          # arguments, and an event carrying them would invite exactly the
          # accumulation this design refuses — `ToolCallStarted` already said
          # a call is coming, and it said so with the name alone.
          delta["partial_json"]?.try(&.as_s?).try { |chunk| pending.json += chunk }
        when "signature_delta"
          # Arrives at the end of a thinking block and must be replayed
          # unmodified. Not an event: nobody watches a signature.
          delta["signature"]?.try(&.as_s?).try { |value| pending.signature = value }
        end
      else
        record(frame, payload) { |event| yield event }
      end
    end

    def complete? : Bool
      @terminal
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      Wire::Response.new(materialise,
        id: @id, model: @model, role: @role,
        stop_reason: @stop_reason, stop_sequence: @stop_sequence, usage: @usage)
    end

    # Frames that open, close or describe rather than fill.
    private def record(frame : Streaming::Sse::Frame, payload : JSON::Any,
                       & : Streaming::Event ->) : Nil
      case frame.name || payload["type"]?.try(&.as_s?)
      when "message_start"       then payload["message"]?.try { |message| began(message) }
      when "content_block_start" then opened(payload) { |event| yield event }
      when "content_block_stop"  then closed(payload)
      when "message_delta"       then advanced(payload)
      when "message_stop"        then @terminal = true
      when "error"               then raise mid_stream(payload)
      end
    end

    # Identity and the input side of the token count.
    private def began(message : JSON::Any) : Nil
      @id = message["id"]?.try(&.as_s?)
      @model = message["model"]?.try(&.as_s?)
      @role = message["role"]?.try(&.as_s?) || "assistant"
      Wire::Usage.parse(message["usage"]?).try { |value| @usage = value }
    end

    # A block's skeleton, which every later delta for that index fills in.
    private def opened(payload : JSON::Any, & : Streaming::Event ->) : Nil
      index = index_of(payload)
      skeleton = payload["content_block"]?
      return unless index && skeleton

      @blocks[index] = Pending.new(skeleton)
      return unless skeleton["type"]?.try(&.as_s?) == "tool_use"

      # Announced the moment the block opens, because the name is here and
      # nowhere later — the deltas that follow carry only argument fragments.
      skeleton["name"]?.try(&.as_s?).try { |name| yield Streaming::ToolCallStarted.new(name) }
    end

    private def closed(payload : JSON::Any) : Nil
      index_of(payload).try { |index| @blocks[index]?.try(&.closed=(true)) }
    end

    # Where the stop reason lives, and where the output-token count is finally
    # correct — `message_start`'s usage is the input side only.
    private def advanced(payload : JSON::Any) : Nil
      payload["delta"]?.try do |delta|
        delta["stop_reason"]?.try(&.as_s?).try { |value| @stop_reason = value }
        delta["stop_sequence"]?.try(&.as_s?).try { |value| @stop_sequence = value }
      end
      Wire::Usage.parse(payload["usage"]?).try { |value| @usage = merged(value) }
    end

    # Turns what has been collected into blocks, applying the rule per block.
    #
    # A closed block is materialised whatever it is. An open one is materialised
    # only if what arrived is meaningful on its own: text and thinking are,
    # because a prefix of prose is prose. A `tool_use` block is not, because its
    # `partial_json` is fragments of an object — so a call still arriving when
    # the stream ended is dropped rather than guessed at, and never reaches a
    # session where something might try to dispatch it.
    private def materialise : Array(Wire::Block)
      @blocks.keys.sort!.compact_map do |index|
        pending = @blocks[index]
        next nil unless pending.closed? || salvageable?(pending)

        Wire::Response.from_content_block(rebuild(pending)).as(Wire::Block?)
      end
    end

    private def salvageable?(pending : Pending) : Bool
      case pending.kind
      when "text", "thinking" then !pending.text.empty?
      else                         false
      end
    end

    # Rebuilds the object the non-streamed reply would have carried.
    private def rebuild(pending : Pending) : JSON::Any
      fields = pending.skeleton.as_h.dup

      case pending.kind
      when "text"
        fields["text"] = JSON::Any.new(pending.text)
      when "thinking"
        fields["thinking"] = JSON::Any.new(pending.text)
        pending.signature.try { |value| fields["signature"] = JSON::Any.new(value) }
      when "tool_use", "server_tool_use"
        fields["input"] = arguments(pending.json)
      end

      JSON::Any.new(fields)
    end

    # An empty or unreadable accumulation becomes an empty object rather than a
    # raise. Only closed tool blocks reach here, so unreadable means the
    # provider sent something this cannot represent — and a call with no
    # arguments is a truthful reading of that, where a raise would discard an
    # otherwise complete reply.
    private def arguments(json : String) : JSON::Any
      return JSON::Any.new({} of String => JSON::Any) if json.blank?

      JSON.parse(json)
    rescue JSON::ParseException
      JSON::Any.new({} of String => JSON::Any)
    end

    # `message_delta` reports output tokens while `message_start` reported
    # input tokens, and neither carries the other. Keeping both means the
    # exported usage matches what a non-streamed reply would have said.
    private def merged(update : Wire::Usage) : Wire::Usage
      previous = @usage
      return update unless previous

      Wire::Usage.new(
        update.input_tokens || previous.input_tokens,
        update.output_tokens || previous.output_tokens)
    end

    private def index_of(payload : JSON::Any) : Int32?
      payload["index"]?.try(&.as_i?)
    end

    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = payload["error"]?
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider sent an error frame",
        error.try(&.["type"]?).try(&.as_s?))
    end
  end
end
