require "json"

module Elelem::Protocol::ChatCompletions
  # The wire form, and nothing but the wire form.
  #
  # These types exist so that no canonical type ever serializes into a request
  # body. That separation is the whole reason this shard can be portable: the
  # moment storage form *is* wire form, there is no mapping layer, and there is
  # nothing left to make portable.
  #
  # They are therefore deliberately shaped like OpenAI's JSON and not like MPSH:
  # roles are strings including `system` and `tool`, tool calls are a message
  # field, content is either a string or a part array, and images are fused into
  # `data:` URIs. Every one of those is a thing MPSH refuses to store.
  module Wire
    # A single piece of message content.
    abstract struct Part
      abstract def to_json(json : JSON::Builder)
    end

    struct TextPart < Part
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

    # The fused form. Built here, at map time, and never stored: parsing a
    # `data:` URI back apart is the direction that fails.
    struct ImagePart < Part
      getter url : String

      def initialize(media_type : String, base64 : String)
        @url = "data:#{media_type};base64,#{base64}"
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "image_url"
          json.field "image_url" do
            json.object { json.field "url", @url }
          end
        end
      end
    end

    struct AudioPart < Part
      getter base64 : String
      getter format : String

      def initialize(@base64 : String, @format : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "input_audio"
          json.field "input_audio" do
            json.object do
              json.field "data", @base64
              json.field "format", @format
            end
          end
        end
      end
    end

    struct FilePart < Part
      getter base64 : String
      getter name : String

      def initialize(@base64 : String, @name : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "file"
          json.field "file" do
            json.object do
              json.field "filename", @name
              json.field "file_data", @base64
            end
          end
        end
      end
    end

    # A tool call, hoisted out of content and onto the message — mechanical in
    # this direction, which is exactly why MPSH stores the block form.
    struct ToolCall
      getter id : String
      getter name : String
      getter arguments : String

      def initialize(@id : String, @name : String, @arguments : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "id", @id
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", @name
              json.field "arguments", @arguments
            end
          end
        end
      end
    end

    # Roles here are provider spellings. MPSH knows only `user` and
    # `assistant`; `system` and `tool` are resolved at map time and unresolved
    # on export.
    struct Message
      getter role : String
      getter content : String | Array(Part) | Nil
      getter tool_calls : Array(ToolCall)?
      getter tool_call_id : String?
      getter refusal : String?
      getter reasoning_content : String?
      # True when this message was invented to make the request legal. Never
      # serialized; consulted by the export direction, which must discard it.
      getter? synthetic : Bool

      def initialize(@role : String,
                     @content : String | Array(Part) | Nil = nil,
                     @tool_calls : Array(ToolCall)? = nil,
                     @tool_call_id : String? = nil,
                     @refusal : String? = nil,
                     @reasoning_content : String? = nil,
                     @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          case body = @content
          in String      then json.field "content", body
          in Array(Part) then json.field("content") { json.array { body.each(&.to_json(json)) } }
          in Nil         then json.field "content", nil
          end
          if calls = @tool_calls
            json.field("tool_calls") { json.array { calls.each(&.to_json(json)) } }
          end
          if id = @tool_call_id
            json.field "tool_call_id", id
          end
          if text = @refusal
            json.field "refusal", text
          end
          if text = @reasoning_content
            json.field "reasoning_content", text
          end
        end
      end
    end

    struct Request
      getter model : String
      getter messages : Array(Message)

      def initialize(@model : String, @messages : Array(Message))
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          json.field("messages") { json.array { @messages.each(&.to_json(json)) } }
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
