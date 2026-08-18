require "./wire"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::ChatCompletions
  # MPSH view in, request body out.
  #
  # Every outcome passes through `Report#record`, which is where policy is
  # enforced. A mapper that wants to lose something has to say so — there is no
  # path from here to the wire that quietly drops content.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      wire = [] of Wire::Message

      if prompt = session.system_prompt
        # `InMessages` placement: the prompt becomes a message rather than a
        # parameter. Restructured, not a loss.
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt), "system prompt to messages array")
        wire << Wire::Message.new("system", prompt)
      end

      session.messages.each_with_index do |message, index|
        case message.role
        in MPSH::Role::User      then map_user(message, index, wire, report)
        in MPSH::Role::Assistant then map_assistant(message, index, wire, report, plan)
        end
      end

      {Wire::Request.new(model, wire), report}
    end

    # A user message may become several wire messages: tool results split out
    # into `role: "tool"` messages, and compensation may append another.
    private def map_user(message : MPSH::Message, index : Int32,
                         wire : Array(Wire::Message), report : Capability::Report) : Nil
      parts = [] of Wire::Part
      compensation = [] of Wire::Part

      message.content.each do |block|
        case block
        when MPSH::ToolResultBlock
          wire << tool_result_message(block, index, report, compensation)
        else
          part = render(block, index, report)
          parts << part if part
        end
      end

      wire << Wire::Message.new("user", parts) unless parts.empty?

      unless compensation.empty?
        # The synthetic turn. It exists so the request is legal, carries content
        # the protocol could not put where it belonged, and is marked so the
        # export direction discards it rather than re-importing an OpenAI
        # workaround as though it were conversation.
        wire << Wire::Message.new("user", compensation, synthetic: true)
      end
    end

    private def map_assistant(message : MPSH::Message, index : Int32,
                              wire : Array(Wire::Message), report : Capability::Report,
                              plan : Capability::Retention::Plan) : Nil
      parts = [] of Wire::Part
      calls = [] of Wire::ToolCall
      refusal : String? = nil
      reasoning : String? = nil

      message.content.each do |block|
        case block
        in MPSH::ToolCallBlock
          rendered = tool_call(block, index, report)
          calls << rendered if rendered
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          reasoning = reasoning_text(block, index, report)
        in MPSH::RefusalBlock
          refusal = refusal_text(block, index, report, parts)
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock,
           MPSH::DocumentBlock, MPSH::ToolResultBlock
          part = render(block, index, report)
          parts << part if part
        end
      end

      content = parts.empty? ? nil : parts
      return if content.nil? && calls.empty? && refusal.nil? && reasoning.nil?

      wire << Wire::Message.new("assistant", content,
        tool_calls: calls.empty? ? nil : calls,
        refusal: refusal,
        reasoning_content: reasoning)
    end

    # The compensation path, and the reason Phase 1 is this protocol.
    #
    # A tool result here can only be a string. Where the canonical result holds
    # anything else, the non-text content is lifted into `compensation`, which
    # the caller appends as a synthesized user message.
    private def tool_result_message(block : MPSH::ToolResultBlock, index : Int32,
                                    report : Capability::Report,
                                    compensation : Array(Wire::Part)) : Wire::Message
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result rendered as a role:tool message",
        index, MPSH::BlockKind::ToolResult)

      text = [] of String
      block.content.each do |nested|
        case nested
        when MPSH::TextBlock
          text << nested.text
        else
          part = render(nested, index, report, Capability::Resolver::Nesting::InsideToolResult)
          if part
            compensation << part
            text << "[content returned separately: #{nested.kind.to_s.downcase}]"
          end
        end
      end

      Wire::Message.new("tool", text.join("\n"),
        tool_call_id: calls.provider_id(block.call_id) || block.call_id)
    end

    private def tool_call(block : MPSH::ToolCallBlock, index : Int32,
                          report : Capability::Report) : Wire::ToolCall?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call hoisted to the tool_calls field",
        index, MPSH::BlockKind::ToolCall)
      return nil if outcome.lossy?

      provider_id = calls.provider_id(block.call_id) || block.call_id
      calls.bind(block.call_id, provider_id)
      Wire::ToolCall.new(provider_id, block.name, block.arguments.to_json)
    end

    private def reasoning_text(block : MPSH::ReasoningBlock, index : Int32,
                               report : Capability::Report) : String?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning carried as reasoning_content",
        index, MPSH::BlockKind::Reasoning)
      block.text
    end

    private def refusal_text(block : MPSH::RefusalBlock, index : Int32,
                             report : Capability::Report,
                             parts : Array(Wire::Part)) : String?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "refusal", index, MPSH::BlockKind::Refusal)
      block.reason
    end

    # Returns nil where the block has no wire representation at all; the report
    # already carries why.
    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Part?
      case block
      in MPSH::TextBlock
        Wire::TextPart.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock
        nil # handled by their own paths
      in MPSH::ReasoningBlock
        nil
      in MPSH::RefusalBlock
        block.reason.try { |reason| Wire::TextPart.new(reason) }
      end
    end

    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}",
        index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextPart.new(text) }
      when MPSH::Outcome::Refused
        nil # unreachable: record raises first
      else
        payload = materialize(block.payload)
        case block
        when MPSH::ImageBlock    then Wire::ImagePart.new(payload.media_type, payload.base64)
        when MPSH::AudioBlock    then Wire::AudioPart.new(payload.base64, format_of(payload.media_type))
        when MPSH::DocumentBlock then Wire::FilePart.new(payload.base64, block.name)
        end
      end
    end

    # Reference payloads are resolved at map time and never stored inline.
    # Without a blob store wired in, a reference cannot be sent.
    private def materialize(payload : MPSH::Payload) : MPSH::InlinePayload
      case payload
      when MPSH::InlinePayload then payload
      else
        raise Capability::RefusedError.new(NAME,
          "reference payload #{payload.media_type} cannot be materialized: no blob store configured")
      end
    end

    private def format_of(media_type : String) : String
      media_type.split('/').last
    end
  end
end
