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
    # Which spelling of the output cap this deployment wants.
    #
    # OpenAI deprecated `max_tokens` in favour of `max_completion_tokens` for
    # its reasoning-model line, and a reasoning model now rejects the old
    # spelling outright rather than tolerating it — confirmed live, not
    # assumed, against `gpt5.4mini` on Azure.
    #
    # This is not a `Capability::Profile` fact: it is not what the *protocol*
    # can express, it is which spelling one *deployment* behind it wants, and
    # two deployments speaking the identical protocol can want different
    # answers. Ollama, LM Studio and llama.cpp — the emulators, not implementing
    # OpenAI's own service — only ever accept `max_tokens`;
    # `max_completion_tokens` support has been an open, unresolved request
    # against Ollama's compatible endpoint for over a year. Silently
    # defaulting to the new spelling would not degrade gracefully there, it
    # would stop capping output entirely — the exact silent-runaway failure
    # `spec_helper.cr` and `DEVELOPMENT.md` already record this shard being
    # burned by once. So `MaxTokens` stays the default everywhere, and a
    # deployment known to need the new spelling says so explicitly — see
    # `ChatCompletionsAdapter#initialize`.
    enum MaxTokensField
      MaxTokens
      MaxCompletionTokens
    end

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

    # A tool offered to the model. This protocol wraps the declaration in a
    # `function` object under a `type` discriminator — the only one of the four
    # to nest it, and the same hoisting instinct that puts tool *calls* on the
    # message rather than in the content.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter parameters : String

      def initialize(@name : String, @description : String?, @parameters : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "function"
          json.field("function") do
            json.object do
              json.field "name", @name
              @description.try { |text| json.field "description", text }
              # Emitted raw: the schema is already JSON, and re-encoding it
              # through a parsed form would only risk changing it.
              json.field("parameters") { json.raw @parameters }
            end
          end
        end
      end
    end

    struct Request
      getter model : String
      getter messages : Array(Message)
      getter tools : Array(ToolDeclaration)
      getter max_tokens : Int32?
      getter max_tokens_field : MaxTokensField
      # A bare string at the top level: the flattest of the four spellings of
      # this idea. `nil` omits the field, leaving the model's own default.
      getter reasoning_effort : String?

      def initialize(@model : String, @messages : Array(Message),
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @max_tokens : Int32? = nil,
                     @reasoning_effort : String? = nil,
                     @max_tokens_field : MaxTokensField = MaxTokensField::MaxTokens)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          json.field("messages") { json.array { @messages.each(&.to_json(json)) } }
          unless @tools.empty?
            json.field("tools") { json.array { @tools.each(&.to_json(json)) } }
          end
          @max_tokens.try do |value|
            field = @max_tokens_field.max_tokens? ? "max_tokens" : "max_completion_tokens"
            json.field field, value
          end
          @reasoning_effort.try { |value| json.field "reasoning_effort", value }
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
