require "./wire/request"
require "./mapper"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Anthropic
  # Wire in, MPSH out.
  #
  # The shallowest of the three exporters, because this protocol already models
  # tool calls, results and thinking as content blocks. There is nothing to
  # un-hoist, no fused representation to split, and no compensation scaffolding
  # to recognise — the capability that forces scaffolding elsewhere is native
  # here.
  #
  # What is *not* recoverable is structural, and it is the mirror of that
  # strictness. Merged messages cannot be unmerged, and a prepended placeholder
  # is indistinguishable from a real opening turn except by its exact text. Both
  # are declared Compensated, so the conformance suite asserts the predicted
  # divergence rather than fidelity.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.system)

      request.messages.each do |message|
        next if placeholder?(message)

        role = message.role == "assistant" ? MPSH::Role::Assistant : MPSH::Role::User
        session << MPSH::Message.new(role, blocks_for(message))
      end

      session
    end

    # Scaffolding invented to satisfy the first-user rule. Recognised by its
    # exact text, on the same terms as the compensation placeholder: a foreign
    # session using different wording is undetectable, and a genuine opening
    # message with this text would be misread. Both limits are inherent.
    private def placeholder?(message : Wire::Message) : Bool
      return true if message.synthetic?
      return false unless message.role == "user" && message.content.size == 1

      first = message.content.first
      first.is_a?(Wire::TextBlock) && first.text == FIRST_USER_PLACEHOLDER
    end

    private def blocks_for(message : Wire::Message) : Array(MPSH::Block)
      message.content.compact_map { |block| to_block(block).as(MPSH::Block?) }
    end

    private def to_block(block : Wire::Block) : MPSH::Block?
      case block
      when Wire::TextBlock
        MPSH::TextBlock.new(block.text)
      when Wire::ImageBlock
        MPSH::ImageBlock.new(
          MPSH::InlinePayload.new(block.base64, block.media_type, byte_size(block.base64)))
      when Wire::DocumentBlock
        MPSH::DocumentBlock.new(
          MPSH::InlinePayload.new(block.base64, block.media_type, byte_size(block.base64)),
          block.title || "document")
      when Wire::ToolUseBlock
        MPSH::ToolCallBlock.new(
          calls.mpsh_id(block.id), block.name, parse_input(block.input))
      when Wire::ToolResultBlock
        # The exact path in reverse: nested content comes straight back, in
        # position, with no placeholder to unpick.
        MPSH::ToolResultBlock.new(
          calls.mpsh_id(block.tool_use_id),
          block.content.compact_map { |nested| to_block(nested).as(MPSH::Block?) },
          is_error: block.is_error?)
      when Wire::ServerToolUseBlock
        MPSH::ToolCallBlock.new(calls.mpsh_id(block.id), block.name,
          parse_input(block.input), server_executed: true)
      when Wire::ServerToolResultBlock
        server_result(block)
      when Wire::ThinkingBlock
        thinking(block)
      end
    end

    # The result block type is tool-specific and not derivable, so it is kept
    # under the vendor namespace rather than guessed at on the next mapping.
    private def server_result(block : Wire::ServerToolResultBlock) : MPSH::ToolResultBlock
      exported = MPSH::ToolResultBlock.new(
        calls.mpsh_id(block.tool_use_id),
        block.content.compact_map { |nested| to_block(nested).as(MPSH::Block?) },
        server_executed: true)
      exported.put_meta(METADATA_KEY, "result_type", block.block_type)
      exported
    end

    # A signature must be replayed unmodified, which is what namespaced
    # metadata is for. `redacted_thinking` carries no text at all, so the
    # structural fact that reasoning occurred is retained as a redacted block
    # rather than becoming an omission.
    private def thinking(block : Wire::ThinkingBlock) : MPSH::ReasoningBlock
      redacted = block.redacted_data != nil
      text = redacted ? nil : block.thinking
      exported = MPSH::ReasoningBlock.new(text, redacted: redacted || text.nil?)

      if value = block.signature
        exported.put_meta(METADATA_KEY, "signature", value)
      end
      if value = block.redacted_data
        exported.put_meta(METADATA_KEY, "redacted_data", value)
      end

      exported
    end

    private def parse_input(json : String) : MPSH::Object
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
