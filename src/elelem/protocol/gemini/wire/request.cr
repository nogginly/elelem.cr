require "json"

module Elelem::Protocol::Gemini
  # The wire form for `generateContent`.
  #
  # Structurally the most divergent of the four, and the divergences compound:
  # the assistant role is spelled `model`, every message is a `{role, parts}`
  # object with no string shorthand anywhere, the model name lives in the URL
  # path rather than the body, and generation settings sit inside a nested
  # `generationConfig`.
  #
  # The consequential one is none of those. **A function call carries no
  # identifier.** Calls are paired to responses by function name and ordering
  # alone, which is why MPSH mints its own `call_id` and keeps provider ids in
  # translation state — a stored OpenAI id cannot supply what this mapper needs,
  # and a Gemini-originated session has no id to store in the first place.
  module Wire
    abstract struct Part
      abstract def to_json(json : JSON::Builder)
    end

    struct TextPart < Part
      getter text : String

      def initialize(@text : String)
      end

      def to_json(json : JSON::Builder)
        json.object { json.field "text", @text }
      end
    end

    # `inline_data` keeps mime type and base64 separate, as MPSH stores them.
    struct InlineDataPart < Part
      getter mime_type : String
      getter base64 : String

      def initialize(@mime_type : String, @base64 : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "inline_data" do
            json.object do
              json.field "mime_type", @mime_type
              json.field "data", @base64
            end
          end
        end
      end
    end

    # No id field exists on this part, and none may be invented: an unexpected
    # key is a request the provider can reject.
    struct FunctionCallPart < Part
      getter name : String
      getter args : String

      def initialize(@name : String, @args : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "functionCall" do
            json.object do
              json.field "name", @name
              json.field "args" { json.raw @args }
            end
          end
        end
      end
    end

    # Paired to its call by `name`, and by ordering where a name repeats.
    struct FunctionResponsePart < Part
      getter name : String
      getter response : String

      def initialize(@name : String, @response : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "functionResponse" do
            json.object do
              json.field "name", @name
              json.field "response" { json.raw @response }
            end
          end
        end
      end
    end

    # A thought part. Gemini omits these unless thought inclusion is requested,
    # and may return a signature that must be replayed unmodified.
    struct ThoughtPart < Part
      getter text : String?
      getter signature : String?

      def initialize(@text : String? = nil, @signature : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "thought", true
          json.field "text", @text || ""
          if value = @signature
            json.field "thoughtSignature", value
          end
        end
      end
    end

    # The assistant role is literally the string `model`. Nothing else in the
    # four protocols spells it that way, which is the single most common source
    # of a silently wrong mapping.
    struct Content
      getter role : String
      getter parts : Array(Part)
      getter? synthetic : Bool

      def initialize(@role : String, @parts : Array(Part), @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          json.field("parts") { json.array { @parts.each(&.to_json(json)) } }
        end
      end
    end

    # The model is *not* a body field here — it goes in the URL path. `model` is
    # carried so a client can build `.../models/{model}:generateContent`, and is
    # deliberately excluded from `to_json`.
    struct Request
      getter model : String
      getter contents : Array(Content)
      getter system_instruction : String?

      def initialize(@model : String, @contents : Array(Content),
                     @system_instruction : String? = nil)
      end

      def path : String
        "models/#{@model}:generateContent"
      end

      def to_json(json : JSON::Builder)
        json.object do
          if text = @system_instruction
            # Structured like any other content object, not a bare string.
            json.field "systemInstruction" do
              json.object do
                json.field("parts") do
                  json.array { json.object { json.field "text", text } }
                end
              end
            end
          end
          json.field("contents") { json.array { @contents.each(&.to_json(json)) } }
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
