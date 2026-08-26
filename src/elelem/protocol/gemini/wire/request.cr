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
    #
    # `thought_signature` is the exception, and arrived after the rest of this
    # struct did: Gemini 3 attaches it as a sibling of `functionCall` on the
    # same part, and enforces it strictly (mandatory on Gemini 3, optional on
    # 2.5) — confirmed live by a 400, not documentation. See
    # `spec/live/gemini_spec.cr` and `docs/protocols/GEMINI.md`.
    struct FunctionCallPart < Part
      getter name : String
      getter args : String
      getter thought_signature : String?

      def initialize(@name : String, @args : String, @thought_signature : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "functionCall" do
            json.object do
              json.field "name", @name
              json.field "args" { json.raw @args }
            end
          end
          @thought_signature.try { |value| json.field "thoughtSignature", value }
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
    # Doubly nested: declarations sit inside `functionDeclarations`, which sits
    # inside an entry of `tools`. The outer array exists because this protocol
    # groups function declarations alongside provider-run tools like code
    # execution — a distinction the other three draw with a block type rather
    # than with request structure.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter parameters : String

      def initialize(@name : String, @description : String?, @parameters : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "name", @name
          @description.try { |text| json.field "description", text }
          # Gemini accepts a restricted OpenAPI subset rather than full JSON
          # Schema, so a schema this protocol rejects may be valid elsewhere.
          # Emitted as given: silently rewriting a caller's schema would be a
          # worse failure than the provider's own error message.
          json.field("parameters") { json.raw @parameters }
        end
      end
    end

    struct Request
      getter model : String
      getter contents : Array(Content)
      getter system_instruction : String?
      getter tools : Array(ToolDeclaration)
      getter max_output_tokens : Int32?
      # `thinkingConfig`, inside `generationConfig`. Both units live in the
      # same object and **must not both be set** — that is a 400, not a
      # precedence rule — so the unit is resolved per model by
      # `Capability::Catalog` before anything is rendered. A budget of 0
      # disables thinking; -1 asks for dynamic thinking, which is what an
      # unconstrained request means here.
      getter thinking_budget : Int32?
      getter thinking_level : String?

      def initialize(@model : String, @contents : Array(Content),
                     @system_instruction : String? = nil,
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @max_output_tokens : Int32? = nil,
                     @thinking_budget : Int32? = nil,
                     @thinking_level : String? = nil)
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
          unless @tools.empty?
            json.field("tools") do
              json.array do
                json.object do
                  json.field("functionDeclarations") do
                    json.array { @tools.each(&.to_json(json)) }
                  end
                end
              end
            end
          end
          # The only protocol to put generation parameters in their own object
          # rather than at the top level — so the object appears once and every
          # generation setting has to be written inside it, rather than each
          # being emitted independently as on the other three.
          cap = @max_output_tokens
          budget = @thinking_budget
          level = @thinking_level
          if cap || budget || level
            json.field("generationConfig") do
              json.object do
                cap.try { |value| json.field "maxOutputTokens", value }
                if budget || level
                  json.field("thinkingConfig") do
                    json.object do
                      budget.try { |value| json.field "thinkingBudget", value }
                      level.try { |value| json.field "thinkingLevel", value }
                      # Without this, thinking still happens (and is billed)
                      # but neither thought text nor the signature a later
                      # turn needs to replay comes back — the API's default is
                      # to omit both, silently. Tied to asking for thinking at
                      # all rather than a separate `Options` field: there is
                      # no reason to request reasoning and not want to see it.
                      json.field "includeThoughts", true
                    end
                  end
                end
              end
            end
          end
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
