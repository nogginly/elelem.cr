require "./wire/request"
require "./wire/response"
require "./mapper"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Gemini
  # Wire in, MPSH out.
  #
  # The unwrapping is mechanical. The interesting work is pairing, because the
  # wire carries no identifiers: a `functionResponse` names the function it
  # answers and nothing more.
  #
  # Reconstruction therefore counts. The nth call to a given function name is
  # answered by the nth response naming that function, and `name#ordinal` is
  # the key both directions agree on. That key is minted into an MPSH `call_id`
  # through the same translation table the other protocols use for real ids —
  # which is what the table was designed for, and the reason MPSH refuses to
  # store provider identifiers as canonical content.
  #
  # The limit is worth stating: this holds because responses arrive in the order
  # their calls were made. A provider that reordered them, or omitted one,
  # would break the correspondence and there would be nothing in the wire to
  # detect it with.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.system_instruction)
      call_ordinals = Hash(String, Int32).new(0)
      response_ordinals = Hash(String, Int32).new(0)
      pending_results = [] of MPSH::ToolResultBlock

      request.contents.each do |content|
        if carrier?(content, pending_results)
          absorb_carrier(content, pending_results)
          next
        end

        pending_results.clear
        role = content.role == "model" ? MPSH::Role::Assistant : MPSH::Role::User
        blocks = [] of MPSH::Block

        content.parts.each do |part|
          block = to_block(part, call_ordinals, response_ordinals)
          next unless block
          pending_results << block if block.is_a?(MPSH::ToolResultBlock)
          blocks << block
        end

        session << MPSH::Message.new(role, blocks) unless blocks.empty?
      end

      session
    end

    # The response direction.
    #
    # `candidates[]` is the alternatives plural, so index 0 is the reply.
    #
    # The awkward part is pairing, and it is awkward in a new way here. On the
    # request side an ordinal is counted across the whole session, so
    # `name#0` is stable and both directions agree on it. A reply is not part
    # of that count: its calls have not been mapped yet, and minting against
    # `name#0` would collide with a key the request side has already bound,
    # handing back an existing call's identifier.
    #
    # So reply calls are keyed in their own space. Only the function *name*
    # has to survive — `function_name` recovers it by splitting at the last
    # `#` — and the next `map` rebinds every call to its real session ordinal
    # before any result is rendered. The reply-scoped key is provisional by
    # construction, which is why it is safe for it to be arbitrary.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      candidate = response.candidate
      unless candidate
        raise MalformedResponseError.new(NAME, "response has no candidates")
      end

      blocks = [] of MPSH::Block
      ordinals = Hash(String, Int32).new(0)

      candidate.content.parts.each do |part|
        block = reply_block(part, ordinals)
        blocks << block if block
      end

      reply = MPSH::Message.new(MPSH::Role::Assistant, blocks,
        response.model_version.try { |model| MPSH::Provenance.new(NAME, model) })

      candidate.finish_reason.try { |value| reply.put_meta(METADATA_KEY, "finishReason", value) }
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    # A reply carries no tool *results* — those are something the caller sends
    # — so only calls need keying, and they get the provisional space
    # described above.
    private def reply_block(part : Wire::Part, ordinals : Hash(String, Int32)) : MPSH::Block?
      case part
      when Wire::FunctionCallPart
        ordinal = ordinals[part.name]
        ordinals[part.name] = ordinal + 1
        tool_call(calls.mpsh_id("#{part.name}#reply:#{ordinal}"), part)
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::InlineDataPart
        binary(part)
      when Wire::ThoughtPart
        thought(part)
      end
    end

    private def to_block(part : Wire::Part,
                         call_ordinals : Hash(String, Int32),
                         response_ordinals : Hash(String, Int32)) : MPSH::Block?
      case part
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::InlineDataPart
        binary(part)
      when Wire::FunctionCallPart
        ordinal = call_ordinals[part.name]
        call_ordinals[part.name] = ordinal + 1
        tool_call(calls.mpsh_id(calls.positional_key(part.name, ordinal)), part)
      when Wire::FunctionResponsePart
        ordinal = response_ordinals[part.name]
        response_ordinals[part.name] = ordinal + 1
        MPSH::ToolResultBlock.new(
          calls.mpsh_id(calls.positional_key(part.name, ordinal)),
          split_placeholders(response_text(part.response)))
      when Wire::ThoughtPart
        thought(part)
      end
    end

    # Gemini 3 attaches a `thoughtSignature` to a `functionCall` part and
    # enforces it strictly on replay — confirmed live by a 400, not
    # documentation (`spec/live/gemini_spec.cr`). Stored the same way a
    # `ThoughtPart`'s signature is: `provider_metadata`, same key, so a tool
    # call minted on another protocol and handed to this one is
    # indistinguishable from one this protocol never signed — both have
    # nothing under `METADATA_KEY`, and both need the same answer once the
    # mapper is taught to check.
    private def tool_call(mpsh_id : String, part : Wire::FunctionCallPart) : MPSH::ToolCallBlock
      block = MPSH::ToolCallBlock.new(mpsh_id, part.name, parse_object(part.args))
      if value = part.thought_signature
        block.put_meta(METADATA_KEY, "thought_signature", value)
      end
      block
    end

    # The response payload is an object rather than a string on this protocol.
    # We write `{"output": ...}`; anything else is kept whole as text rather
    # than guessed at.
    private def response_text(json : String) : String
      parsed = JSON.parse(json)
      parsed["output"]?.try(&.as_s?) || json
    rescue JSON::ParseException
      json
    end

    private def thought(part : Wire::ThoughtPart) : MPSH::ReasoningBlock
      text = part.text.try { |value| value.empty? ? nil : value }
      block = MPSH::ReasoningBlock.new(text, redacted: text.nil?)
      if value = part.signature
        block.put_meta(METADATA_KEY, "thought_signature", value)
      end
      block
    end

    private def binary(part : Wire::InlineDataPart) : MPSH::Block
      payload = MPSH::InlinePayload.new(part.base64, part.mime_type, byte_size(part.base64))

      case part.mime_type.partition('/')[0]
      when "image" then MPSH::ImageBlock.new(payload)
      when "audio" then MPSH::AudioBlock.new(payload)
      else              MPSH::DocumentBlock.new(payload, "document")
      end
    end

    # Local to this protocol: a carrier is a `user` content, and a `model` one
    # never is. That check sat *below* the synthetic test in the original and
    # stays below it here, which is what `eligible` is for — an early return
    # would outrank `synthetic?` and change the answer.
    private def carrier?(content : Wire::Content,
                         pending : Array(MPSH::ToolResultBlock)) : Bool
      Capability::Carrier.carrier?(pending, content.synthetic?, content.parts,
        eligible: content.role == "user") { |part| part.is_a?(Wire::TextPart) }
    end

    # Fresh ordinal tables per part: a carrier holds lifted media, never a
    # function call or response, so nothing in it participates in the ordinal
    # pairing this protocol uses in place of identifiers.
    private def absorb_carrier(content : Wire::Content,
                               pending : Array(MPSH::ToolResultBlock)) : Nil
      Capability::Carrier.absorb(pending, content.parts) do |part|
        to_block(part, Hash(String, Int32).new(0), Hash(String, Int32).new(0))
      end
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      Capability::Carrier.split(body)
    end

    private def parse_object(json : String) : MPSH::Object
      raw = JSON.parse(json).as_h?
      return MPSH::Object.new unless raw
      raw.each_with_object(MPSH::Object.new) { |(key, value), acc| acc[key] = to_value(value) }
    rescue JSON::ParseException
      MPSH::Object.new
    end

    private def to_value(any : JSON::Any) : MPSH::Value
      case raw = any.raw
      when Nil, Bool, Int64, Float64, String
        raw
      when Array
        raw.map { |item| to_value(item).as(MPSH::Value) }
      when Hash
        raw.each_with_object(MPSH::Object.new) { |(key, item), acc| acc[key] = to_value(item) }
      else
        nil
      end
    end

    private def byte_size(base64 : String) : Int64
      (base64.size * 3 // 4).to_i64
    end
  end
end
