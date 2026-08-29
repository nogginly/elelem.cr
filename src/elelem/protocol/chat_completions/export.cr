require "./wire/request"
require "./wire/response"
require "./mapper"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Elelem::Protocol::ChatCompletions
  # Wire in, MPSH out.
  #
  # This direction carries obligations the map direction does not, and all of
  # them are the same shape: the wire form fuses or hoists things that MPSH
  # keeps separate, and separating them again is the direction that can fail.
  #
  # Three signals are available, in descending reliability:
  #
  # 1. **`call_id` pairing** — explicit in the wire, exact. `assistant → tool →
  #    tool` is never inferred from adjacency; each result names the call it
  #    answers.
  # 2. **Position plus the placeholder marker** — strong, because the
  #    placeholder is our own constant. Distinguishes a compensation carrier
  #    from genuine user input.
  # 3. **Message boundaries between adjacent tool results** — *not recoverable*.
  #    The wire cannot express whether two results arrived as one turn or two,
  #    and renders both identically. A consecutive run collapses into one MPSH
  #    user message, which is a declared adaptation rather than a bug.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      export(request.messages)
    end

    # The response direction.
    #
    # A request is a conversation; a response is one assistant turn. None of
    # the machinery above applies — no system prompt to merge, no carrier to
    # absorb, no placeholder to unpick, no run of tool results to collapse —
    # because a reply cannot contain user content, and compensation
    # scaffolding is something this client invents on the way out, never
    # something a provider sends back.
    #
    # What remains is the un-hoisting: `tool_calls` is a message field here and
    # blocks in MPSH, exactly as it is on the request side, so the same code
    # does the job.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      choice = response.choice
      unless choice
        raise MalformedResponseError.new(NAME, "response has no choices")
      end

      reply = MPSH::Message.new(MPSH::Role::Assistant,
        assistant_blocks(choice.message),
        response.model.try { |model| MPSH::Provenance.new(NAME, model) })

      # Namespaced, because none of it is canonical. A finish reason is not
      # consulted for control flow — "are there client-executed tool calls in
      # the reply" is the whole condition — and it is recorded only so a
      # caller that wants it can find it.
      choice.finish_reason.try { |value| reply.put_meta(METADATA_KEY, "finish_reason", value) }
      response.id.try { |value| reply.put_meta(METADATA_KEY, "response_id", value) }
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    def export(messages : Array(Wire::Message)) : MPSH::Session
      session = MPSH::Session.new
      # Tool results awaiting either a carrier or a boundary.
      run = [] of MPSH::ToolResultBlock

      messages.each do |message|
        case message.role
        when "system"
          session.system_prompt = merge_system(session.system_prompt, text_of(message))
        when "tool"
          run << tool_result(message)
        when "assistant"
          flush_run(session, run)
          assistant(session, message)
        when "user"
          if carrier?(message, run)
            absorb_carrier(message, run)
          else
            flush_run(session, run)
            session << MPSH::Message.new(MPSH::Role::User, parts_to_blocks(message))
          end
        end
      end

      flush_run(session, run)
      session
    end

    # A trailing `user` message after tool results is ambiguous on the wire: it
    # is either a compensation carrier belonging to the results above it, or
    # genuine input opening a new turn. This is the same distinction
    # `MPSH::Turns` draws for retention, approached from the other side. The
    # signals, and the honest limits of all three, are in
    # `Capability::Carrier`.
    #
    # Local to this protocol: content here may be a bare `String` rather than
    # parts, in which case there is nothing to inspect and it is not a carrier.
    private def carrier?(message : Wire::Message, run : Array(MPSH::ToolResultBlock)) : Bool
      body = message.content
      parts = body.is_a?(Array(Wire::Part)) ? body : [] of Wire::Part

      Capability::Carrier.carrier?(run, message.synthetic?, parts,
        eligible: body.is_a?(Array(Wire::Part))) { |part| part.is_a?(Wire::TextPart) }
    end

    # Carrier content is returned to the result that referenced it, in order.
    private def absorb_carrier(message : Wire::Message, run : Array(MPSH::ToolResultBlock)) : Nil
      body = message.content
      return unless body.is_a?(Array(Wire::Part))

      Capability::Carrier.absorb(run, body) { |part| part_to_block(part) }
    end

    # A consecutive run of `role: "tool"` messages becomes one user message.
    # The boundary between them is the one thing the wire genuinely cannot
    # express, so a history that held them as separate turns comes back joined.
    private def flush_run(session : MPSH::Session, run : Array(MPSH::ToolResultBlock)) : Nil
      return if run.empty?
      blocks = run.map(&.as(MPSH::Block))
      session << MPSH::Message.new(MPSH::Role::User, blocks)
      run.clear
    end

    private def tool_result(message : Wire::Message) : MPSH::ToolResultBlock
      provider_id = message.tool_call_id || ""
      MPSH::ToolResultBlock.new(calls.mpsh_id(provider_id), split_placeholders(text_of(message)))
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      Capability::Carrier.split(body)
    end

    private def assistant(session : MPSH::Session, message : Wire::Message) : Nil
      session << MPSH::Message.new(MPSH::Role::Assistant, assistant_blocks(message))
    end

    # Shared by both directions. A reply and an assistant message already in a
    # request carry the same fields and mean the same things, so reading them
    # twice would be two places to forget the same rule.
    private def assistant_blocks(message : Wire::Message) : Array(MPSH::Block)
      blocks = [] of MPSH::Block

      # Reasoning first, matching where providers place it in a turn.
      if reasoning = message.reasoning_content
        blocks << MPSH::ReasoningBlock.new(reasoning)
      end

      blocks.concat(parts_to_blocks(message))

      if refusal = message.refusal
        blocks << MPSH::RefusalBlock.new(refusal)
      end

      # Un-hoisting: a message-level field becomes blocks. This is the direction
      # the specification calls invention, and the reason MPSH stores the block
      # form in the first place.
      message.tool_calls.try &.each do |call|
        blocks << MPSH::ToolCallBlock.new(
          calls.mpsh_id(call.id), call.name, parse_arguments(call.arguments))
      end

      blocks
    end

    private def parts_to_blocks(message : Wire::Message) : Array(MPSH::Block)
      case body = message.content
      in String
        body.empty? ? [] of MPSH::Block : [MPSH::TextBlock.new(body).as(MPSH::Block)]
      in Array(Wire::Part)
        # `compact_map` infers the union of what `part_to_block` can actually
        # return — four block kinds — which is narrower than `MPSH::Block`.
        # Widen at the element, not the array.
        body.compact_map { |part| part_to_block(part).as(MPSH::Block?) }
      in Nil
        [] of MPSH::Block
      end
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

    # Splitting a fused representation. Synthesizing the URI was concatenation;
    # this is parsing, which is why MPSH never stores the fused form.
    private def split_data_uri(url : String) : {String, String}
      unless url.starts_with?("data:") && url.includes?(";base64,")
        raise Capability::RefusedError.new(NAME, "image URL is not an inline data URI: #{url[0, 32]}")
      end

      head, _, body = url[5..].partition(";base64,")
      {head, body}
    end

    private def parse_arguments(json : String) : MPSH::Object
      parsed = JSON.parse(json)
      raw = parsed.as_h?
      return MPSH::Object.new unless raw

      raw.each_with_object(MPSH::Object.new) do |(key, value), acc|
        acc[key] = to_value(value)
      end
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

    private def merge_system(existing : String?, addition : String) : String
      return addition unless existing
      "#{existing}\n\n#{addition}"
    end

    private def text_of(message : Wire::Message) : String
      case body = message.content
      in String            then body
      in Array(Wire::Part) then body.compact_map { |part| part.as?(Wire::TextPart).try &.text }.join("\n")
      in Nil               then ""
      end
    end

    private def byte_size(base64 : String) : Int64
      (base64.size * 3 // 4).to_i64
    end
  end
end
