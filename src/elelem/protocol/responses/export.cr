require "./wire"
require "./mapper"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Responses
  # Wire in, MPSH out.
  #
  # Shallower than the Chat Completions exporter, and the reason is structural
  # rather than incidental: there are no message-level fields here, so there is
  # nothing to un-hoist. An item maps almost one-to-one onto a block.
  #
  # The two hard parts are the same as before, because they arise from the
  # protocol's *constraints* rather than its shape: a tool output is a string,
  # so compensation must be recognised and absorbed; and adjacent outputs
  # collapse, because the wire cannot say whether they arrived as one turn or
  # several.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.instructions)
      run = [] of MPSH::ToolResultBlock
      # Assistant items arrive separately — reasoning, then calls, then a
      # message — but describe one MPSH message. They are gathered rather than
      # emitted one per item.
      assistant = [] of MPSH::Block

      request.input.each do |item|
        case item
        when Wire::ReasoningItem
          flush_run(session, run)
          assistant << reasoning(item)
        when Wire::FunctionCallItem
          flush_run(session, run)
          assistant << MPSH::ToolCallBlock.new(
            calls.mpsh_id(item.call_id), item.name, parse_arguments(item.arguments))
        when Wire::FunctionCallOutputItem
          flush_assistant(session, assistant)
          run << MPSH::ToolResultBlock.new(
            calls.mpsh_id(item.call_id), split_placeholders(item.output))
        when Wire::RefusalItem
          flush_run(session, run)
          assistant << MPSH::RefusalBlock.new(item.reason)
        when Wire::MessageItem
          message_item(session, item, run, assistant)
        end
      end

      flush_assistant(session, assistant)
      flush_run(session, run)
      session
    end

    private def message_item(session : MPSH::Session, item : Wire::MessageItem,
                             run : Array(MPSH::ToolResultBlock),
                             assistant : Array(MPSH::Block)) : Nil
      if item.role == "assistant"
        flush_run(session, run)
        assistant.concat(parts_to_blocks(item.content))
        return
      end

      if carrier?(item, run)
        absorb_carrier(item, run)
        return
      end

      flush_assistant(session, assistant)
      flush_run(session, run)
      session << MPSH::Message.new(MPSH::Role::User, parts_to_blocks(item.content))
    end

    # Same ambiguity as on Chat Completions, and the same limits: a foreign
    # session using different placeholder text is undetectable, and a genuine
    # user message following a tool output and carrying an image is
    # indistinguishable from a carrier.
    private def carrier?(item : Wire::MessageItem, run : Array(MPSH::ToolResultBlock)) : Bool
      return false if run.empty?
      return true if item.synthetic?
      return false unless run.any? { |result| placeholders(result) > 0 }
      item.content.none?(Wire::TextPart)
    end

    private def absorb_carrier(item : Wire::MessageItem,
                               run : Array(MPSH::ToolResultBlock)) : Nil
      queue = item.content.dup
      run.each do |result|
        placeholders(result).times do
          part = queue.shift?
          break unless part
          block = part_to_block(part)
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

    private def flush_assistant(session : MPSH::Session,
                                assistant : Array(MPSH::Block)) : Nil
      return if assistant.empty?
      session << MPSH::Message.new(MPSH::Role::Assistant, assistant.dup)
      assistant.clear
    end

    # Adjacent tool outputs become one user message. Declared as
    # `CollapseAdjacentToolResults`: pairing survives via `call_id`, only the
    # message boundary is lost.
    private def flush_run(session : MPSH::Session,
                          run : Array(MPSH::ToolResultBlock)) : Nil
      return if run.empty?
      session << MPSH::Message.new(MPSH::Role::User, run.map(&.as(MPSH::Block)))
      run.clear
    end

    # An item can carry the opaque payload a text field could not, so this is
    # where the two OpenAI protocols part company.
    private def reasoning(item : Wire::ReasoningItem) : MPSH::ReasoningBlock
      text = item.summary.empty? ? nil : item.summary.join("\n")
      block = MPSH::ReasoningBlock.new(text, redacted: text.nil?)

      if value = item.encrypted_content
        block.put_meta(METADATA_KEY, "encrypted_content", value)
      end
      if value = item.id
        block.put_meta(METADATA_KEY, "item_id", value)
      end

      block
    end

    private def parts_to_blocks(parts : Array(Wire::Part)) : Array(MPSH::Block)
      parts.compact_map { |part| part_to_block(part).as(MPSH::Block?) }
    end

    private def part_to_block(part : Wire::Part) : MPSH::Block?
      case part
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::ImagePart
        media_type, base64 = split_data_uri(part.url)
        MPSH::ImageBlock.new(MPSH::InlinePayload.new(base64, media_type, byte_size(base64)))
      when Wire::AudioPart
        MPSH::AudioBlock.new(
          MPSH::InlinePayload.new(part.base64, "audio/#{part.format}", byte_size(part.base64)))
      when Wire::FilePart
        MPSH::DocumentBlock.new(
          MPSH::InlinePayload.new(part.base64, "application/pdf", byte_size(part.base64)),
          part.name)
      end
    end

    private def split_data_uri(url : String) : {String, String}
      unless url.starts_with?("data:") && url.includes?(";base64,")
        raise Capability::RefusedError.new(NAME, "image URL is not an inline data URI: #{url[0, 32]}")
      end

      head, _, body = url[5..].partition(";base64,")
      {head, body}
    end

    private def parse_arguments(json : String) : MPSH::Object
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
