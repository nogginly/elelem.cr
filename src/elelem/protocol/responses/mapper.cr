require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/reasoning_control"
require "../../capability/structural"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::Responses
  # Same marker as Chat Completions, and the same rules apply: it is a protocol
  # marker rather than a note to a human, it must stay byte-identical in both
  # directions, and improving the wording is a breaking change.
  COMPENSATION_PLACEHOLDER = "[elelem: content returned separately in the following message]"

  # MPSH view in, request body out.
  #
  # Structurally shallower than the Chat Completions mapper: there is no
  # hoisting, because there are no message-level fields to hoist into. A tool
  # call is an item, which is nearly the block form MPSH already stores.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      items = [] of Wire::Item
      pending = [] of Wire::Part

      if session.system_prompt
        # `Instructions` placement: a parameter rather than a message. The one
        # structural difference from Chat Completions that shows up on every
        # request.
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt), "system prompt to instructions")
      end

      session.messages.each_with_index do |message, index|
        case message.role
        in MPSH::Role::User      then map_user(message, index, items, report, pending)
        in MPSH::Role::Assistant then map_assistant(message, index, items, report, plan, pending)
        end
      end

      flush_compensation(items, pending, report)
      {Wire::Request.new(model, items, session.system_prompt, declarations(options),
        options.max_output_tokens, reasoning_effort(options, report)), report}
    end

    # Identical to Chat Completions in unit and vocabulary, differing only in
    # where the value lands in the body — which is this family's pattern
    # everywhere, and the reason passing both protocols proves less than it
    # looks.
    private def reasoning_effort(options : Options,
                                 report : Capability::Report) : String?
      request = options.reasoning
      return nil unless request

      rendering, outcome = Capability::ReasoningControl.resolve(request, profile.reasoning_unit)
      report.record(outcome,
        Capability::ReasoningControl.detail(request, rendering, profile.reasoning_unit))

      case rendering
      in Capability::ReasoningControl::Rendering::AsEffort
        case request
        in Reasoning::Effort then request.wire_name
        in Reasoning::Budget then request.to_effort.wire_name
        in Reasoning::Off    then "none"
        end
      in Capability::ReasoningControl::Rendering::Disable
        "none"
      in Capability::ReasoningControl::Rendering::AsBudget
        nil
      in Capability::ReasoningControl::Rendering::Drop
        nil
      end
    end

    # Carriers are deferred here for the same reason as on Chat Completions:
    # every `function_call_output` answering one assistant turn should precede
    # anything else, and several results' content may ride in one carrier.
    # Tool declarations and generation options, translated per protocol.
    #
    # Added as a trailing parameter rather than folded in with `policy` and
    # `retention`: those govern what may be lost translating *history*, these
    # govern what the model is asked to do *next*. Two questions that happen to
    # ride on one call.
    private def declarations(options : Options) : Array(Wire::ToolDeclaration)
      options.tools.map do |tool|
        Wire::ToolDeclaration.new(tool.name, tool.description, tool.parameters)
      end
    end

    private def flush_compensation(items : Array(Wire::Item),
                                   pending : Array(Wire::Part),
                                   report : Capability::Report) : Nil
      return if pending.empty?

      report.record(
        Capability::Structural.outcome(Capability::Structural::Adaptation::DeferCompensationCarrier),
        "compensation carrier deferred past #{pending.size} tool result(s)")

      items << Wire::MessageItem.new("user", pending.dup, synthetic: true)
      pending.clear
    end

    private def map_user(message : MPSH::Message, index : Int32,
                         items : Array(Wire::Item), report : Capability::Report,
                         pending : Array(Wire::Part)) : Nil
      parts = [] of Wire::Part

      message.content.each do |block|
        case block
        when MPSH::ToolResultBlock
          items << tool_output(block, index, report, pending)
        else
          part = render(block, index, report, "user")
          parts << part if part
        end
      end

      return if parts.empty?
      flush_compensation(items, pending, report)
      items << Wire::MessageItem.new("user", parts)
    end

    private def map_assistant(message : MPSH::Message, index : Int32,
                              items : Array(Wire::Item), report : Capability::Report,
                              plan : Capability::Retention::Plan,
                              pending : Array(Wire::Part)) : Nil
      flush_compensation(items, pending, report)
      parts = [] of Wire::Part

      message.content.each do |block|
        case block
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          item = reasoning(block, index, report)
          items << item if item
        in MPSH::ToolCallBlock
          item = tool_call(block, index, report)
          items << item if item
        in MPSH::RefusalBlock
          items << refusal(block, index, report)
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock,
           MPSH::DocumentBlock, MPSH::ToolResultBlock
          part = render(block, index, report, "assistant")
          parts << part if part
        end
      end

      # Emitted after any reasoning or call items, matching the order a provider
      # returns them within a turn.
      items << Wire::MessageItem.new("assistant", parts) unless parts.empty?
    end

    # A reasoning **item** rather than a text field, which is the one place the
    # two OpenAI protocols genuinely differ: an item can carry the opaque
    # payload a redacted trace consists of.
    private def reasoning(block : MPSH::ReasoningBlock, index : Int32,
                          report : Capability::Report) : Wire::Item?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning as an item", index, MPSH::BlockKind::Reasoning)
      return nil if outcome.lossy?

      meta = block.meta_for(profile.metadata_key)
      summary = [] of String
      if text = block.text
        summary << text
      end

      Wire::ReasoningItem.new(summary,
        id: meta.try(&.["item_id"]?).try(&.as?(String)),
        encrypted_content: meta.try(&.["encrypted_content"]?).try(&.as?(String)))
    end

    private def tool_call(block : MPSH::ToolCallBlock, index : Int32,
                          report : Capability::Report) : Wire::Item?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call as a function_call item", index, MPSH::BlockKind::ToolCall)
      return nil if outcome.lossy?

      provider_id = calls.provider_id(block.call_id) || block.call_id
      calls.bind(block.call_id, provider_id)
      Wire::FunctionCallItem.new(provider_id, block.name, block.arguments.to_json)
    end

    private def tool_output(block : MPSH::ToolResultBlock, index : Int32,
                            report : Capability::Report,
                            pending : Array(Wire::Part)) : Wire::Item
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result as a function_call_output item",
        index, MPSH::BlockKind::ToolResult)

      text = [] of String
      block.content.each do |nested|
        case nested
        when MPSH::TextBlock
          text << nested.text
        else
          part = render(nested, index, report, "user",
            Capability::Resolver::Nesting::InsideToolResult)
          if part
            pending << part
            text << COMPENSATION_PLACEHOLDER
          end
        end
      end

      Wire::FunctionCallOutputItem.new(
        calls.provider_id(block.call_id) || block.call_id, text.join("\n"))
    end

    private def refusal(block : MPSH::RefusalBlock, index : Int32,
                        report : Capability::Report) : Wire::Item
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "refusal", index, MPSH::BlockKind::Refusal)
      Wire::RefusalItem.new(block.reason || "")
    end

    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       role : String,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Part?
      case block
      in MPSH::TextBlock
        Wire::TextPart.new(block.text, role)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, role, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock, MPSH::ReasoningBlock
        nil # each has its own item type
      in MPSH::RefusalBlock
        block.reason.try { |reason| Wire::TextPart.new(reason, role) }
      end
    end

    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report, role : String,
                       nesting : Capability::Resolver::Nesting) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}", index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextPart.new(text, role) }
      when MPSH::Outcome::Refused
        nil
      else
        payload = materialize(block.payload)
        case block
        when MPSH::ImageBlock    then Wire::ImagePart.new(payload.media_type, payload.base64)
        when MPSH::AudioBlock    then Wire::AudioPart.new(payload.base64, format_of(payload.media_type))
        when MPSH::DocumentBlock then Wire::FilePart.new(payload.base64, block.name)
        end
      end
    end

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
