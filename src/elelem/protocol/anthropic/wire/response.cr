require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Elelem::Protocol::Anthropic
  # The response half of the wire vocabulary.
  #
  # The only one of the four with no wrapper: the reply *is* the top-level
  # object, and `content[]` sits at its root. No `choices`, no `candidates`, no
  # index to pick. That is the same trait that makes this protocol the closest
  # of the four to MPSH, seen from the response side.
  #
  # It is also the one reader where a mistake is a **correctness** bug rather
  # than a fidelity one. `server_tool_use` and its result arrive already
  # executed; reading either as an ordinary `tool_use` would hand the caller a
  # call to dispatch, and dispatching it means running a tool they do not have.
  # The block types are distinct here precisely so that cannot happen by
  # accident, and this reader keeps them distinct.
  module Wire
    struct Usage
      getter input_tokens : Int32?
      getter output_tokens : Int32?

      def initialize(@input_tokens : Int32? = nil, @output_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        return nil unless any
        new(any["input_tokens"]?.try(&.as_i?), any["output_tokens"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @input_tokens.try { |value| object["input_tokens"] = value.to_i64 }
        @output_tokens.try { |value| object["output_tokens"] = value.to_i64 }
        object
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter role : String
      getter content : Array(Block)
      getter stop_reason : String?
      getter stop_sequence : String?
      getter usage : Usage?

      def initialize(@content : Array(Block), @id : String? = nil, @model : String? = nil,
                     @role : String = "assistant", @stop_reason : String? = nil,
                     @stop_sequence : String? = nil, @usage : Usage? = nil)
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        raw = parsed["content"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `content` array")
        end

        new(raw.compact_map { |entry| block(entry).as(Block?) },
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          role: parsed["role"]?.try(&.as_s?) || "assistant",
          stop_reason: parsed["stop_reason"]?.try(&.as_s?),
          stop_sequence: parsed["stop_sequence"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      # A reply can in principle carry any block this protocol defines, so all
      # of them are read. The alternative — reading only what a model is
      # *expected* to emit — is how a capability quietly stops working the
      # first time a provider starts using one.
      private def self.block(any : JSON::Any) : Block?
        type = any["type"]?.try(&.as_s?)
        return nil unless type

        case type
        when "text"
          any["text"]?.try(&.as_s?).try { |text| TextBlock.new(text) }
        when "thinking", "redacted_thinking"
          thinking(any)
        when "tool_use"
          tool_use(any).try { |parts| ToolUseBlock.new(*parts) }
        when "server_tool_use"
          # Distinct type, distinct block. See the note above.
          tool_use(any).try { |parts| ServerToolUseBlock.new(*parts) }
        when "image"
          binary(any).try { |parts| ImageBlock.new(*parts) }
        when "document"
          binary(any).try do |parts|
            DocumentBlock.new(parts[0], parts[1], any["title"]?.try(&.as_s?))
          end
        when "tool_result"
          tool_result(any)
        else
          # The server-tool result block type is tool-specific —
          # `web_search_tool_result` and its siblings — so it is matched by
          # suffix rather than enumerated. A new provider-run tool must not
          # need a code change here to be read as provider-run.
          type.ends_with?("_tool_result") ? server_tool_result(any, type) : nil
        end
      end

      private def self.tool_use(any : JSON::Any) : {String, String, String}?
        name = any["name"]?.try(&.as_s?)
        return nil unless name

        # `input` is a structured object here, not a JSON string as on the
        # OpenAI protocols. The wire type stores it as raw JSON text, so it is
        # re-serialized rather than parsed — parsing happens once, at export.
        {any["id"]?.try(&.as_s?) || "", name, (any["input"]? || JSON::Any.new({} of String => JSON::Any)).to_json}
      end

      private def self.binary(any : JSON::Any) : {String, String}?
        source = any["source"]?
        return nil unless source
        # Only inline base64 is read. A URL source names bytes we do not have,
        # and inventing a payload we never received is the one thing a reader
        # must not do.
        return nil unless source["type"]?.try(&.as_s?) == "base64"

        media_type = source["media_type"]?.try(&.as_s?)
        data = source["data"]?.try(&.as_s?)
        return nil unless media_type && data

        {media_type, data}
      end

      private def self.tool_result(any : JSON::Any) : Block?
        id = any["tool_use_id"]?.try(&.as_s?)
        return nil unless id

        ToolResultBlock.new(id, nested(any), any["is_error"]?.try(&.as_bool?) || false)
      end

      private def self.server_tool_result(any : JSON::Any, type : String) : Block?
        id = any["tool_use_id"]?.try(&.as_s?)
        return nil unless id

        ServerToolResultBlock.new(id, nested(any), type)
      end

      # `content` nests, and so does this. The recursion is the capability that
      # forced the nested block list into MPSH in the first place — an
      # image-bearing tool result is native here and expressible nowhere else.
      private def self.nested(any : JSON::Any) : Array(Block)
        body = any["content"]?
        return [] of Block unless body

        if text = body.as_s?
          [TextBlock.new(text).as(Block)]
        elsif entries = body.as_a?
          entries.compact_map { |entry| block(entry).as(Block?) }
        else
          [] of Block
        end
      end

      # A signature must be replayed unmodified, and `redacted_thinking`
      # carries no text at all. Both are kept, so that reasoning which occurred
      # is never reduced to an omission.
      private def self.thinking(any : JSON::Any) : Block
        ThinkingBlock.new(
          any["thinking"]?.try(&.as_s?),
          signature: any["signature"]?.try(&.as_s?),
          redacted_data: any["data"]?.try(&.as_s?))
      end
    end
  end
end
