require "json"

module Elelem::Protocol::Responses
  # The wire form for the Responses API.
  #
  # The structural difference from Chat Completions is worth stating plainly:
  # there are no messages with sibling fields. There is one flat `input` array
  # of **items**, and a message is merely one item type among several. A tool
  # call is not a field on a message — it is an item in its own right, as is its
  # output, and as is a reasoning trace.
  #
  # That shape is closer to MPSH's block list than Chat Completions is, which
  # makes the mapping shallower in places and is the reason redacted reasoning
  # survives here: an item can carry an opaque payload, a text field cannot.
  module Wire
    abstract struct Part
      abstract def to_json(json : JSON::Builder)
    end

    struct TextPart < Part
      getter text : String
      # Input and output text are distinct types on this protocol.
      getter role : String

      def initialize(@text : String, @role : String = "user")
      end

      def type : String
        @role == "assistant" ? "output_text" : "input_text"
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", type
          json.field "text", @text
        end
      end
    end

    struct ImagePart < Part
      getter url : String

      def initialize(media_type : String, base64 : String)
        @url = "data:#{media_type};base64,#{base64}"
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "input_image"
          json.field "image_url", @url
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
          json.field "type", "input_file"
          json.field "filename", @name
          json.field "file_data", @base64
        end
      end
    end

    # Every entry in `input` is an Item. This is the protocol's defining shape.
    abstract struct Item
      abstract def to_json(json : JSON::Builder)

      # Marks scaffolding invented to make a request legal. Never serialized;
      # the export direction must discard it. A real export reading JSON has no
      # such flag and recognises compensation structurally.
      def synthetic? : Bool
        false
      end
    end

    struct MessageItem < Item
      getter role : String
      getter content : Array(Part)
      getter? synthetic : Bool

      def initialize(@role : String, @content : Array(Part), @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "message"
          json.field "role", @role
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    struct FunctionCallItem < Item
      getter call_id : String
      getter name : String
      getter arguments : String

      def initialize(@call_id : String, @name : String, @arguments : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "function_call"
          json.field "call_id", @call_id
          json.field "name", @name
          json.field "arguments", @arguments
        end
      end
    end

    # `output` is a string on this protocol too, which is why the compensation
    # path is needed here exactly as it is on Chat Completions.
    struct FunctionCallOutputItem < Item
      getter call_id : String
      getter output : String

      def initialize(@call_id : String, @output : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "function_call_output"
          json.field "call_id", @call_id
          json.field "output", @output
        end
      end
    end

    # The item that Chat Completions has no equivalent of. `encrypted_content`
    # is opaque and must be replayed unmodified, which is precisely what a text
    # field cannot do and an item can.
    struct ReasoningItem < Item
      getter id : String?
      getter summary : Array(String)
      getter encrypted_content : String?

      def initialize(@summary : Array(String) = [] of String,
                     @id : String? = nil,
                     @encrypted_content : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "reasoning"
          if value = @id
            json.field "id", value
          end
          json.field("summary") do
            json.array do
              @summary.each do |text|
                json.object do
                  json.field "type", "summary_text"
                  json.field "text", text
                end
              end
            end
          end
          if value = @encrypted_content
            json.field "encrypted_content", value
          end
        end
      end
    end

    struct RefusalItem < Item
      getter reason : String

      def initialize(@reason : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "message"
          json.field "role", "assistant"
          json.field("content") do
            json.array do
              json.object do
                json.field "type", "refusal"
                json.field "refusal", @reason
              end
            end
          end
        end
      end
    end

    # Flat, unlike Chat Completions' nested `function` object — the same
    # flattening this protocol applies to tool calls, which are items in their
    # own right here rather than a field hoisted onto a message.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter parameters : String

      def initialize(@name : String, @description : String?, @parameters : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "function"
          json.field "name", @name
          @description.try { |text| json.field "description", text }
          json.field("parameters") { json.raw @parameters }
        end
      end
    end

    struct Request
      getter model : String
      getter instructions : String?
      getter input : Array(Item)
      getter tools : Array(ToolDeclaration)
      getter max_output_tokens : Int32?

      def initialize(@model : String, @input : Array(Item), @instructions : String? = nil,
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @max_output_tokens : Int32? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          if text = @instructions
            json.field "instructions", text
          end
          json.field("input") { json.array { @input.each(&.to_json(json)) } }
          unless @tools.empty?
            json.field("tools") { json.array { @tools.each(&.to_json(json)) } }
          end
          # `max_output_tokens` here, `max_tokens` on the other three. One idea,
          # four spellings.
          @max_output_tokens.try { |value| json.field "max_output_tokens", value }
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
