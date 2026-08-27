require "json"
require "./session"

module Elelem::MPSH
  # `Session` in, JSON out, and back — the only place a canonical type meets a
  # serialization format. Deliberately external rather than a `to_json` on
  # `Message`/`Block`/`Session` themselves: `DEVELOPMENT.md` rule 2 forbids
  # canonical types a serialization identity of their own, precisely so
  # nothing under `mpsh/` can be handed to an HTTP client by accident. This
  # module is the one place storage form is allowed to exist, and it walks
  # the canonical types from outside them, the same way a mapper does.
  #
  # Not wire form. A provider never sees this shape, and this shape never
  # narrows for a provider's capabilities — an archived session is meant to
  # be loaded back exactly as it was, then mapped fresh against whichever
  # deployment `continue` is aimed at. Losslessness here is the whole point;
  # `Conformance.compare` on a written-then-read session should never report
  # a divergence, for any fixture, ever.
  module Archive
    extend self

    FORMAT = "mpsh-archive-v1"

    class FormatError < Exception
    end

    def write(session : Session) : String
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "system_prompt", session.system_prompt
          json.field("messages") { json.array { session.messages.each { |message| write_message(json, message) } } }
          json.field("annotations") { json.array { session.annotations.each { |note| write_annotation(json, note) } } }
        end
      end
    end

    def read(source : String) : Session
      root = JSON.parse(source)
      format = root["format"]?.try(&.as_s?)
      raise FormatError.new("not an MPSH archive (missing or unrecognised 'format')") unless format == FORMAT

      messages = root["messages"].as_a.map { |message| read_message(message) }
      annotations = (root["annotations"]?.try(&.as_a) || [] of JSON::Any).map { |note| read_annotation(note) }
      Session.new(root["system_prompt"]?.try(&.as_s?), messages, annotations)
    end

    # -- Message ----------------------------------------------------------

    private def write_message(json : JSON::Builder, message : Message) : Nil
      json.object do
        json.field "role", message.role.user? ? "user" : "assistant"
        json.field("content") { json.array { message.content.each { |block| write_block(json, block) } } }
        if provenance = message.provenance
          json.field("provenance") do
            json.object do
              json.field "provider", provenance.provider
              json.field "model", provenance.model
              json.field "bias", provenance.bias
            end
          end
        end
        write_metadata(json, message.provider_metadata)
      end
    end

    private def read_message(node : JSON::Any) : Message
      role = node["role"].as_s == "user" ? Role::User : Role::Assistant
      content = node["content"].as_a.map { |block| read_block(block) }
      provenance = node["provenance"]?.try do |provenance_node|
        Provenance.new(provenance_node["provider"].as_s, provenance_node["model"].as_s,
          provenance_node["bias"]?.try(&.as_s?))
      end
      message = Message.new(role, content, provenance)
      message.provider_metadata = read_metadata(node)
      message
    end

    # -- Block --------------------------------------------------------------
    #
    # One case per `BlockKind`, exhaustive by hand rather than by the
    # compiler — a `String` discriminator can't give `case ... in` checking
    # the way the mapper/exporter pairs get it. A ninth block kind added
    # later and not extended here fails loudly on `read` (an unrecognised
    # `kind` raises) rather than silently dropping content on `write` (the
    # `case block; in ...` below is exhaustive over the `Block` union, so the
    # compiler catches that half).

    private def block_kind_name(kind : BlockKind) : String
      case kind
      in .text?        then "text"
      in .image?       then "image"
      in .audio?       then "audio"
      in .document?    then "document"
      in .tool_call?   then "tool_call"
      in .tool_result? then "tool_result"
      in .reasoning?   then "reasoning"
      in .refusal?     then "refusal"
      end
    end

    private def parse_block_kind(name : String) : BlockKind
      case name
      when "text"        then BlockKind::Text
      when "image"       then BlockKind::Image
      when "audio"       then BlockKind::Audio
      when "document"    then BlockKind::Document
      when "tool_call"   then BlockKind::ToolCall
      when "tool_result" then BlockKind::ToolResult
      when "reasoning"   then BlockKind::Reasoning
      when "refusal"     then BlockKind::Refusal
      else                    raise FormatError.new("unrecognised block kind #{name.inspect}")
      end
    end

    private def write_block(json : JSON::Builder, block : Block) : Nil
      json.object do
        case block
        in TextBlock
          json.field "kind", block_kind_name(BlockKind::Text)
          json.field "text", block.text
        in ImageBlock, AudioBlock, DocumentBlock
          write_binary_fields(json, block)
        in ToolCallBlock
          json.field "kind", block_kind_name(BlockKind::ToolCall)
          json.field "call_id", block.call_id
          json.field "name", block.name
          json.field("arguments") { write_value(json, block.arguments) }
          json.field "server_executed", block.server_executed?
        in ToolResultBlock
          json.field "kind", block_kind_name(BlockKind::ToolResult)
          json.field "call_id", block.call_id
          json.field("content") { json.array { block.content.each { |child| write_block(json, child) } } }
          json.field "is_error", block.is_error?
          json.field "exception", block.exception
          json.field "server_executed", block.server_executed?
        in ReasoningBlock
          json.field "kind", block_kind_name(BlockKind::Reasoning)
          json.field "text", block.text
          json.field "redacted", block.redacted?
        in RefusalBlock
          json.field "kind", block_kind_name(BlockKind::Refusal)
          json.field "reason", block.reason
        end
        write_metadata(json, block.provider_metadata)
      end
    end

    private def write_binary_fields(json : JSON::Builder, block : ImageBlock | AudioBlock | DocumentBlock) : Nil
      json.field "kind", block_kind_name(case block
      when ImageBlock then BlockKind::Image
      when AudioBlock then BlockKind::Audio
      else                 BlockKind::Document
      end)
      json.field("payload") { write_payload(json, block.payload) }
      json.field "text_fallback", block.text_fallback
      json.field "name", block.name
    end

    private def read_block(node : JSON::Any) : Block
      metadata = read_metadata(node)
      block = case parse_block_kind(node["kind"].as_s)
              in .text?
                TextBlock.new(node["text"].as_s)
              in .image?
                ImageBlock.new(read_payload(node["payload"]), node["text_fallback"]?.try(&.as_s?),
                  node["name"]?.try(&.as_s?))
              in .audio?
                AudioBlock.new(read_payload(node["payload"]), node["text_fallback"]?.try(&.as_s?),
                  node["name"]?.try(&.as_s?))
              in .document?
                DocumentBlock.new(read_payload(node["payload"]), node["name"].as_s,
                  node["text_fallback"]?.try(&.as_s?))
              in .tool_call?
                ToolCallBlock.new(node["call_id"].as_s, node["name"].as_s,
                  read_value(node["arguments"]).as(Object), node["server_executed"].as_bool)
              in .tool_result?
                ToolResultBlock.new(node["call_id"].as_s, node["content"].as_a.map { |child| read_block(child) },
                  node["is_error"].as_bool, node["exception"]?.try(&.as_s?), node["server_executed"].as_bool)
              in .reasoning?
                ReasoningBlock.new(node["text"]?.try(&.as_s?), node["redacted"].as_bool)
              in .refusal?
                RefusalBlock.new(node["reason"]?.try(&.as_s?))
              end
      block.provider_metadata = metadata
      block
    end

    # -- Payload --------------------------------------------------------------

    private def write_payload(json : JSON::Builder, payload : Payload) : Nil
      json.object do
        json.field "media_type", payload.media_type
        json.field "byte_size", payload.byte_size
        case payload
        when InlinePayload
          json.field "form", "inline"
          json.field "base64", payload.base64
        when ReferencePayload
          json.field "form", "reference"
          json.field "handle", payload.handle
        else
          raise FormatError.new("unrecognised Payload subclass #{payload.class}")
        end
      end
    end

    private def read_payload(node : JSON::Any) : Payload
      media_type = node["media_type"].as_s
      byte_size = node["byte_size"].as_i64
      case node["form"].as_s
      when "inline"    then InlinePayload.new(node["base64"].as_s, media_type, byte_size)
      when "reference" then ReferencePayload.new(node["handle"].as_s, media_type, byte_size)
      else
        raise FormatError.new("unrecognised payload form #{node["form"]?.inspect}")
      end
    end

    # -- Annotation -----------------------------------------------------------

    private def outcome_name(outcome : Outcome) : String
      case outcome
      in .exact?        then "exact"
      in .restructured? then "restructured"
      in .compensated?  then "compensated"
      in .degraded?     then "degraded"
      in .refused?      then "refused"
      end
    end

    private def parse_outcome(name : String) : Outcome
      case name
      when "exact"        then Outcome::Exact
      when "restructured" then Outcome::Restructured
      when "compensated"  then Outcome::Compensated
      when "degraded"     then Outcome::Degraded
      when "refused"      then Outcome::Refused
      else                     raise FormatError.new("unrecognised outcome #{name.inspect}")
      end
    end

    private def write_annotation(json : JSON::Builder, a : Annotation) : Nil
      json.object do
        json.field "outcome", outcome_name(a.outcome)
        json.field "provider", a.provider
        json.field "detail", a.detail
        json.field "message_index", a.message_index
        json.field "block_kind", a.block_kind.try { |k| block_kind_name(k) }
        json.field "at", a.at.to_unix_ms
      end
    end

    private def read_annotation(node : JSON::Any) : Annotation
      block_kind = node["block_kind"]?.try(&.as_s?).try { |kind_name| parse_block_kind(kind_name) }
      Annotation.new(parse_outcome(node["outcome"].as_s), node["provider"].as_s, node["detail"].as_s,
        node["message_index"]?.try(&.as_i?), block_kind, Time.unix_ms(node["at"].as_i64))
    end

    # -- Metadata / Value -------------------------------------------------
    #
    # `Value` mirrors JSON's own value model exactly, but generic type
    # parameters are invariant in Crystal — `Object` (`Hash(String, Value)`)
    # being a member of the `Value` union doesn't make `Hash(String, Object)`
    # the same type as `Hash(String, Value)`. So this is a per-value
    # widen-then-narrow, not a direct cast of the outer `Hash`.

    private def write_metadata(json : JSON::Builder, metadata : Metadata) : Nil
      return if metadata.empty?
      json.field("provider_metadata") { write_value(json, metadata.transform_values(&.as(Value))) }
    end

    private def read_metadata(node : JSON::Any) : Metadata
      raw = node["provider_metadata"]?
      return Metadata.new unless raw
      read_value(raw).as(Hash(String, Value)).transform_values(&.as(Object))
    end

    private def write_value(json : JSON::Builder, value : Value) : Nil
      case value
      in Nil          then json.null
      in Bool         then json.bool(value)
      in Int64        then json.number(value)
      in Float64      then json.number(value)
      in String       then json.string(value)
      in Array(Value) then json.array { value.each { |v| write_value(json, v) } }
      in Hash(String, Value)
        json.object { value.each { |k, v| json.field(k) { write_value(json, v) } } }
      end
    end

    private def read_value(any : JSON::Any) : Value
      raw = any.raw
      case raw
      when Nil                     then nil
      when Bool                    then raw
      when Int64                   then raw
      when Float64                 then raw
      when String                  then raw
      when Array(JSON::Any)        then raw.map { |v| read_value(v) }
      when Hash(String, JSON::Any) then raw.transform_values { |v| read_value(v) }
      else
        raise FormatError.new("unrecognised JSON value #{raw.class}")
      end
    end
  end
end
