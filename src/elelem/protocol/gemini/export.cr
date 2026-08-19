require "./wire"
require "./mapper"
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
        MPSH::ToolCallBlock.new(
          calls.mpsh_id(calls.positional_key(part.name, ordinal)),
          part.name, parse_object(part.args))
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

    private def carrier?(content : Wire::Content,
                         pending : Array(MPSH::ToolResultBlock)) : Bool
      return false if pending.empty?
      return true if content.synthetic?
      return false unless content.role == "user"
      return false unless pending.any? { |result| placeholders(result) > 0 }
      content.parts.none?(Wire::TextPart)
    end

    private def absorb_carrier(content : Wire::Content,
                               pending : Array(MPSH::ToolResultBlock)) : Nil
      queue = content.parts.dup
      pending.each do |result|
        placeholders(result).times do
          part = queue.shift?
          break unless part
          block = to_block(part, Hash(String, Int32).new(0), Hash(String, Int32).new(0))
          replace_placeholder(result, block) if block
        end
      end
    end

    private def placeholders(result : MPSH::ToolResultBlock) : Int32
      result.content.count do |block|
        block.is_a?(MPSH::TextBlock) && block.text == COMPENSATION_PLACEHOLDER
      end
    end

    private def replace_placeholder(result : MPSH::ToolResultBlock,
                                    block : MPSH::Block) : Nil
      index = result.content.index do |existing|
        existing.is_a?(MPSH::TextBlock) && existing.text == COMPENSATION_PLACEHOLDER
      end
      result.content[index] = block if index
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      return [] of MPSH::Block if body.empty?

      blocks = [] of MPSH::Block
      segments = body.split(COMPENSATION_PLACEHOLDER)

      segments.each_with_index do |segment, index|
        trimmed = segment.strip('\n')
        blocks << MPSH::TextBlock.new(trimmed) unless trimmed.empty?
        blocks << MPSH::TextBlock.new(COMPENSATION_PLACEHOLDER) if index < segments.size - 1
      end

      blocks
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
