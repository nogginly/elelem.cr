require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Elelem::Protocol::Gemini
  # The response half of the wire vocabulary.
  #
  # `candidates[]` is the alternatives plural, as `choices[]` is on Chat
  # Completions and unlike `output[]` or Anthropic's `content[]`. We never set
  # `candidateCount`, so exactly one is expected and index 0 is the reply, not
  # a truncation.
  #
  # Two smaller traps, both this protocol's alone. The assistant role is
  # spelled `model`. And a part is identified by *which key it has* rather than
  # by a `type` field — `text`, `functionCall`, `inlineData` — so the reader
  # branches on key presence, and a thought is a `text` part wearing a
  # `thought: true` flag rather than a part type of its own. Checking the flag
  # before the text is therefore load-bearing: read in the other order, every
  # thought silently becomes ordinary assistant prose.
  module Wire
    struct Usage
      getter prompt_tokens : Int32?
      getter candidates_tokens : Int32?
      getter thoughts_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@prompt_tokens : Int32? = nil, @candidates_tokens : Int32? = nil,
                     @thoughts_tokens : Int32? = nil, @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        return nil unless any
        new(any["promptTokenCount"]?.try(&.as_i?),
          any["candidatesTokenCount"]?.try(&.as_i?),
          any["thoughtsTokenCount"]?.try(&.as_i?),
          any["totalTokenCount"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @prompt_tokens.try { |value| object["promptTokenCount"] = value.to_i64 }
        @candidates_tokens.try { |value| object["candidatesTokenCount"] = value.to_i64 }
        @thoughts_tokens.try { |value| object["thoughtsTokenCount"] = value.to_i64 }
        @total_tokens.try { |value| object["totalTokenCount"] = value.to_i64 }
        object
      end
    end

    struct Candidate
      getter index : Int32
      getter content : Content
      getter finish_reason : String?

      def initialize(@index : Int32, @content : Content, @finish_reason : String? = nil)
      end
    end

    struct Response
      getter model_version : String?
      getter candidates : Array(Candidate)
      getter usage : Usage?

      def initialize(@candidates : Array(Candidate), @model_version : String? = nil,
                     @usage : Usage? = nil)
      end

      # The reply we asked for. Implicit `candidateCount = 1`; see the note
      # above.
      def candidate : Candidate?
        @candidates.first?
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        raw = parsed["candidates"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `candidates` array")
        end

        new(raw.map_with_index { |entry, index| candidate(entry, index) },
          model_version: parsed["modelVersion"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usageMetadata"]?))
      end

      private def self.candidate(any : JSON::Any, position : Int32) : Candidate
        body = any["content"]?
        parts = [] of Part
        body.try(&.["parts"]?).try(&.as_a?).try &.each do |entry|
          part(entry).try { |value| parts << value }
        end

        Candidate.new(
          any["index"]?.try(&.as_i?) || position,
          # `model`, not `assistant`. The single most common source of a
          # silently wrong mapping on this protocol, and the response
          # direction is no exception.
          Content.new(body.try(&.["role"]?).try(&.as_s?) || "model", parts),
          any["finishReason"]?.try(&.as_s?))
      end

      # No `type` discriminator anywhere. A part is whichever key it carries,
      # and the thought flag is checked first because a thought part *also*
      # carries `text`.
      private def self.part(any : JSON::Any) : Part?
        return thought(any) if any["thought"]?.try(&.as_bool?)

        if call = any["functionCall"]?
          return function_call(call, any["thoughtSignature"]?.try(&.as_s?))
        end

        # Both spellings appear in the wild: the REST surface emits camelCase,
        # several compatibility servers emit the snake_case form the request
        # side writes.
        if data = any["inlineData"]? || any["inline_data"]?
          return inline_data(data)
        end

        any["text"]?.try(&.as_s?).try { |text| TextPart.new(text) }
      end

      private def self.function_call(any : JSON::Any, thought_signature : String?) : Part?
        name = any["name"]?.try(&.as_s?)
        return nil unless name

        # `args` is a structured object here, and the wire type stores it as
        # raw JSON text. Re-serialized rather than parsed; parsing happens once,
        # at export.
        #
        # Note what is *absent*: an identifier. There is no id on the wire to
        # read, which is why pairing is reconstructed from name and ordering
        # and why MPSH mints its own `call_id`.
        #
        # `thought_signature` is passed in rather than read from `any` here:
        # Gemini attaches it as a sibling of `functionCall` on the enclosing
        # part, not as a field within the `functionCall` object itself, and
        # `any` at this point is already the inner object.
        FunctionCallPart.new(name,
          (any["args"]? || JSON::Any.new({} of String => JSON::Any)).to_json,
          thought_signature)
      end

      private def self.inline_data(any : JSON::Any) : Part?
        mime = any["mimeType"]?.try(&.as_s?) || any["mime_type"]?.try(&.as_s?)
        data = any["data"]?.try(&.as_s?)
        return nil unless mime && data

        InlineDataPart.new(mime, data)
      end

      private def self.thought(any : JSON::Any) : Part
        text = any["text"]?.try(&.as_s?)
        ThoughtPart.new(text, any["thoughtSignature"]?.try(&.as_s?))
      end
    end
  end
end
