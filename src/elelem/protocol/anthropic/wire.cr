require "json"

module Elelem::Protocol::Anthropic
  # The wire form for the Messages API.
  #
  # Closest of the four to MPSH, and not by coincidence: tool calls and results
  # are content blocks here, as is thinking. Two of four protocols model them
  # this way, which is what settled the field-vs-block rule in MPSH's favour.
  #
  # The decisive capability is `tool_result.content`: an array of blocks,
  # including images. A tool returning a screenshot is natively expressible,
  # which no OpenAI protocol can manage. That single fact is why MPSH is the
  # union of provider capabilities rather than the intersection — an
  # intersection format would have deleted a capability this protocol offers.
  module Wire
    abstract struct Block
      abstract def to_json(json : JSON::Builder)
    end

    struct TextBlock < Block
      getter text : String

      def initialize(@text : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "text"
          json.field "text", @text
        end
      end
    end

    # Media type and base64 stay separate, exactly as MPSH stores them. No
    # fusing, no `data:` URI, nothing to parse back apart.
    struct ImageBlock < Block
      getter media_type : String
      getter base64 : String

      def initialize(@media_type : String, @base64 : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "image"
          json.field "source" do
            json.object do
              json.field "type", "base64"
              json.field "media_type", @media_type
              json.field "data", @base64
            end
          end
        end
      end
    end

    struct DocumentBlock < Block
      getter media_type : String
      getter base64 : String
      getter title : String?

      def initialize(@media_type : String, @base64 : String, @title : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "document"
          json.field "source" do
            json.object do
              json.field "type", "base64"
              json.field "media_type", @media_type
              json.field "data", @base64
            end
          end
          if value = @title
            json.field "title", value
          end
        end
      end
    end

    struct ToolUseBlock < Block
      getter id : String
      getter name : String
      getter input : String

      def initialize(@id : String, @name : String, @input : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "tool_use"
          json.field "id", @id
          json.field "name", @name
          # `input` is a structured object here, not a JSON string as on the
          # OpenAI protocols. MPSH stores it structured, so this is the
          # direction that needs no parsing.
          json.field "input" { json.raw @input }
        end
      end
    end

    # The block that forced the capability model. `content` is a nested block
    # array, so `[text, image]` is expressible with no compensation at all.
    struct ToolResultBlock < Block
      getter tool_use_id : String
      getter content : Array(Block)
      getter? is_error : Bool

      def initialize(@tool_use_id : String, @content : Array(Block), @is_error : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "tool_result"
          json.field "tool_use_id", @tool_use_id
          json.field "is_error", @is_error if @is_error
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    # Provider-run tools are a distinct block type here, not a flag on an
    # ordinary tool call. That distinction is the protocol agreeing with MPSH:
    # a server-executed call is a different category, not a variation, and a
    # client must never dispatch one.
    struct ServerToolUseBlock < Block
      getter id : String
      getter name : String
      getter input : String

      def initialize(@id : String, @name : String, @input : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "server_tool_use"
          json.field "id", @id
          json.field "name", @name
          json.field "input" { json.raw @input }
        end
      end
    end

    # The result block type is tool-specific — `web_search_tool_result` and
    # friends — so it is carried rather than assumed, and preserved through
    # `provider_metadata` on export.
    struct ServerToolResultBlock < Block
      getter tool_use_id : String
      getter content : Array(Block)
      getter block_type : String

      def initialize(@tool_use_id : String, @content : Array(Block),
                     @block_type : String = "web_search_tool_result")
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", @block_type
          json.field "tool_use_id", @tool_use_id
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    # Thinking carries a signature that must be replayed unmodified. Like the
    # Responses API's reasoning item and unlike a text field, it can hold an
    # opaque payload.
    struct ThinkingBlock < Block
      getter thinking : String?
      getter signature : String?
      getter redacted_data : String?

      def initialize(@thinking : String? = nil, @signature : String? = nil,
                     @redacted_data : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          if data = @redacted_data
            json.field "type", "redacted_thinking"
            json.field "data", data
          else
            json.field "type", "thinking"
            json.field "thinking", @thinking || ""
            if value = @signature
              json.field "signature", value
            end
          end
        end
      end
    end

    struct Message
      getter role : String
      getter content : Array(Block)
      # Scaffolding invented to satisfy alternation or the first-user rule.
      # Never serialized; export must discard it.
      getter? synthetic : Bool

      def initialize(@role : String, @content : Array(Block), @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    struct Request
      getter model : String
      getter system : String?
      getter messages : Array(Message)
      getter max_tokens : Int32

      def initialize(@model : String, @messages : Array(Message),
                     @max_tokens : Int32, @system : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          # Required, with no default. The one parameter this protocol will
          # reject a request for omitting.
          json.field "max_tokens", @max_tokens
          if text = @system
            json.field "system", text
          end
          json.field("messages") { json.array { @messages.each(&.to_json(json)) } }
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
