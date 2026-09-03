require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Elelem::Protocol::Responses
  # The response half of the wire vocabulary.
  #
  # `output[]` is **not** the plural that `choices[]` is. It is the reply's own
  # parts — a reasoning item, a message, one function_call per requested tool —
  # and taking index 0 would throw away most of the answer. The array is walked
  # entire, in order, and the order is the order the model produced them in.
  #
  # The items themselves are the request-side `Item` types, unchanged. That
  # reuse is the whole reason this protocol was pleasant to add a reader for:
  # the input and output vocabularies are the same vocabulary, which is the
  # design's own claim about itself and turns out to be true.
  module Wire
    struct Usage
      getter input_tokens : Int32?
      getter output_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@input_tokens : Int32? = nil, @output_tokens : Int32? = nil,
                     @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        return nil unless any
        new(any["input_tokens"]?.try(&.as_i?),
          any["output_tokens"]?.try(&.as_i?),
          any["total_tokens"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @input_tokens.try { |value| object["input_tokens"] = value.to_i64 }
        @output_tokens.try { |value| object["output_tokens"] = value.to_i64 }
        @total_tokens.try { |value| object["total_tokens"] = value.to_i64 }
        object
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter status : String?
      getter output : Array(Item)
      getter usage : Usage?

      def initialize(@output : Array(Item), @id : String? = nil, @model : String? = nil,
                     @status : String? = nil, @usage : Usage? = nil)
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        from_any(parsed)
      end

      # The same reader, from an object someone else already parsed.
      #
      # Streaming needs this: a terminal frame carries the whole response
      # nested under `response`, so the reader has a `JSON::Any` in hand and no
      # body to hand back. Re-serializing it just to parse it again would be
      # silly, and — worse — would make the streamed and non-streamed readers
      # two different readers that happen to agree today.
      def self.from_any(parsed : JSON::Any) : Response
        raw = parsed["output"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `output` array")
        end

        new(from_items(raw),
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          status: parsed["status"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      # Item reading with no envelope around it.
      #
      # An assembler collecting `response.output_item.done` frames has items
      # and never sees an envelope, so it needs the item half on its own. That
      # it is the *same* half is the point: a partial reply and a complete one
      # translate their items through identical code, so the two cannot drift.
      def self.from_items(raw : Array(JSON::Any)) : Array(Item)
        output = [] of Item
        raw.each { |entry| items(entry, output) }
        output
      end

      # One wire item can yield more than one `Item`: a message whose content
      # holds both output text and a refusal is two of ours, because the
      # request vocabulary models a refusal as an item in its own right.
      # Appending rather than returning is what lets that stay honest.
      private def self.items(any : JSON::Any, into : Array(Item)) : Nil
        case any["type"]?.try(&.as_s?)
        when "message"
          message(any, into)
        when "function_call"
          function_call(any).try { |item| into << item }
        when "reasoning"
          into << reasoning(any)
        else
          # Unknown item types are dropped rather than raised on. A provider
          # adding a new one must not break a client that has no use for it —
          # and anything we could not read, we could not have replayed.
          nil
        end
      end

      private def self.message(any : JSON::Any, into : Array(Item)) : Nil
        role = any["role"]?.try(&.as_s?) || "assistant"
        parts = [] of Part
        refusals = [] of String

        any["content"]?.try(&.as_a?).try &.each do |entry|
          case entry["type"]?.try(&.as_s?)
          when "output_text", "input_text", "text"
            entry["text"]?.try(&.as_s?).try { |text| parts << TextPart.new(text, role) }
          when "refusal"
            entry["refusal"]?.try(&.as_s?).try { |reason| refusals << reason }
          end
        end

        into << MessageItem.new(role, parts) unless parts.empty?
        refusals.each { |reason| into << RefusalItem.new(reason) }
      end

      private def self.function_call(any : JSON::Any) : Item?
        name = any["name"]?.try(&.as_s?)
        return nil unless name

        FunctionCallItem.new(
          any["call_id"]?.try(&.as_s?) || any["id"]?.try(&.as_s?) || "",
          name,
          any["arguments"]?.try(&.as_s?) || "{}")
      end

      # `encrypted_content` is opaque and must survive byte-identical. Reading
      # it here rather than discarding it is what makes a reasoning trace
      # replayable across the two OpenAI protocols.
      private def self.reasoning(any : JSON::Any) : Item
        summary = [] of String
        any["summary"]?.try(&.as_a?).try &.each do |entry|
          entry["text"]?.try(&.as_s?).try { |text| summary << text }
        end

        ReasoningItem.new(summary,
          id: any["id"]?.try(&.as_s?),
          encrypted_content: any["encrypted_content"]?.try(&.as_s?))
      end
    end
  end
end
