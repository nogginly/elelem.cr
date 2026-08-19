require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Elelem::Protocol::ChatCompletions
  # The response half of the wire vocabulary. Parse-only, as `request.cr` is
  # serialize-only, and the asymmetry is the point: a request is something this
  # shard *builds*, a response is something it *reads*, and the two directions
  # fail in different ways.
  #
  # `choices` is plural in the alternatives sense — `n` requests several
  # independent answers to one prompt. We never set `n`, so exactly one is
  # expected, and taking index 0 is not a truncation. Contrast the Responses
  # API's `output[]` and Anthropic's `content[]`, which are the parts of a
  # single reply and must be walked entire.
  module Wire
    struct Usage
      getter prompt_tokens : Int32?
      getter completion_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@prompt_tokens : Int32? = nil, @completion_tokens : Int32? = nil,
                     @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        return nil unless any
        new(any["prompt_tokens"]?.try(&.as_i?),
          any["completion_tokens"]?.try(&.as_i?),
          any["total_tokens"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @prompt_tokens.try { |value| object["prompt_tokens"] = value.to_i64 }
        @completion_tokens.try { |value| object["completion_tokens"] = value.to_i64 }
        @total_tokens.try { |value| object["total_tokens"] = value.to_i64 }
        object
      end
    end

    struct Choice
      getter index : Int32
      getter message : Message
      getter finish_reason : String?

      def initialize(@index : Int32, @message : Message, @finish_reason : String? = nil)
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter choices : Array(Choice)
      getter usage : Usage?

      def initialize(@choices : Array(Choice), @id : String? = nil,
                     @model : String? = nil, @usage : Usage? = nil)
      end

      # The reply we asked for. Implicit `n = 1`; see the note above.
      def choice : Choice?
        @choices.first?
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        raw = parsed["choices"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `choices` array")
        end

        choices = raw.map_with_index { |entry, index| choice(entry, index) }

        new(choices,
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      private def self.choice(any : JSON::Any, position : Int32) : Choice
        body = any["message"]?
        unless body
          raise MalformedResponseError.new(NAME, "choice #{position} has no `message`")
        end

        Choice.new(any["index"]?.try(&.as_i?) || position,
          message(body),
          any["finish_reason"]?.try(&.as_s?))
      end

      # Reuses the request-side `Message`, which already has every field a
      # reply can carry. Nothing is invented for the response direction that
      # the request direction did not already need.
      private def self.message(any : JSON::Any) : Message
        Message.new(
          role: any["role"]?.try(&.as_s?) || "assistant",
          content: any["content"]?.try(&.as_s?),
          tool_calls: tool_calls(any["tool_calls"]?),
          refusal: any["refusal"]?.try(&.as_s?),
          # Not in OpenAI's own specification. vLLM, Ollama and others emit it
          # for reasoning models over this protocol, which is exactly the set
          # of servers this protocol reaches.
          reasoning_content: any["reasoning_content"]?.try(&.as_s?))
      end

      private def self.tool_calls(any : JSON::Any?) : Array(ToolCall)?
        entries = any.try(&.as_a?)
        return nil if entries.nil? || entries.empty?

        entries.compact_map do |entry|
          function = entry["function"]?
          next nil unless function

          name = function["name"]?.try(&.as_s?)
          next nil unless name

          ToolCall.new(
            entry["id"]?.try(&.as_s?) || "",
            name,
            # Arguments arrive as a JSON *string* on this protocol, which is
            # the fused form. It stays fused here and is parsed at export,
            # where the failure has somewhere to go.
            function["arguments"]?.try(&.as_s?) || "{}")
        end
      end
    end
  end
end
