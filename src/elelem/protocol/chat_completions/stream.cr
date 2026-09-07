require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Elelem::Protocol::ChatCompletions
  # Chunks from a Chat Completions stream, assembled into a `Wire::Response`.
  #
  # ## Left until last, for the reason that shows up here
  #
  # This protocol streams with the least structure of the four. There are no
  # frame names, no block boundaries, and **no signal that a tool call has
  # finished arriving** — Anthropic closes a block with `content_block_stop`
  # and Responses hands over a finished item, but here a call's arguments
  # simply stop growing, and nothing says so.
  #
  # That has a consequence worth stating plainly, because it is the strictest
  # reading of `Streaming::Assembler`'s rule anywhere in this shard: **a tool
  # call is materialised only once a `finish_reason` has arrived.** Until then
  # nothing distinguishes arguments that are complete from arguments that are
  # merely complete *so far*, and a JSON fragment that happens to parse is the
  # most dangerous case rather than the reassuring one — `{"city":"Par` does
  # not parse, but `{"city":"Paris"` followed by more is a call that would look
  # finished and be wrong. So a stream cut mid-generation yields its text and
  # its reasoning and no calls at all, even calls whose arguments look whole.
  #
  # Content and reasoning are kept, as everywhere else: a prefix of prose is
  # prose.
  #
  # ## Two shapes that exist only here
  #
  # **`[DONE]` is not JSON.** It is why `Sse::Frame#data` is a `String` rather
  # than a parsed object — a parser in the shared framing layer would have had
  # to fail on it or special-case one protocol.
  #
  # **Usage has to be asked for.** `stream_options.include_usage` is set by the
  # request; without it a streamed reply reports no token count at all. The
  # final chunk carrying it has an empty `choices` array, so a reader that
  # required a choice would throw the usage away.
  class Assembler < ::Elelem::Streaming::Assembler
    # One tool call being built. `id` and `name` arrive once, on the fragment
    # that introduces the call; `arguments` accumulates across every fragment
    # sharing an index.
    class Pending
      property id : String?
      property name : String?
      property arguments : String

      def initialize
        @arguments = ""
      end
    end

    def initialize(@exporter : Exporter)
      @content = ""
      @reasoning = ""
      @calls = {} of Int32 => Pending
      @role = "assistant"
      @refusal = nil.as(String?)
      @finish_reason = nil.as(String?)
      @id = nil.as(String?)
      @model = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @done = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      if frame.data.strip == "[DONE]"
        @done = true
        return
      end

      payload = decode(frame.data)
      return unless payload
      raise mid_stream(payload) if payload["error"]?

      @id = payload["id"]?.try(&.as_s?) || @id
      @model = payload["model"]?.try(&.as_s?) || @model
      Wire::Usage.parse(payload["usage"]?).try { |value| @usage = value }

      choice = payload["choices"]?.try(&.as_a?).try(&.first?)
      return unless choice

      choice["finish_reason"]?.try(&.as_s?).try { |value| @finish_reason = value }

      delta = choice["delta"]?
      return unless delta

      @role = delta["role"]?.try(&.as_s?) || @role
      @refusal = delta["refusal"]?.try(&.as_s?) || @refusal

      delta["content"]?.try(&.as_s?).try do |text|
        next if text.empty?
        @content += text
        yield Streaming::TextDelta.new(text)
      end

      # Both spellings, for the reason `Wire::Response.message` gives: vLLM and
      # DeepSeek emit `reasoning_content`, Ollama emits the bare `reasoning`,
      # and insisting on one silently drops the trace from servers that chose
      # the other.
      reasoning = delta["reasoning_content"]?.try(&.as_s?) || delta["reasoning"]?.try(&.as_s?)
      reasoning.try do |text|
        next if text.empty?
        @reasoning += text
        yield Streaming::ReasoningDelta.new(text)
      end

      delta["tool_calls"]?.try(&.as_a?).try do |fragments|
        fragments.each do |fragment|
          announced = accumulate(fragment)
          announced.try { |name| yield Streaming::ToolCallStarted.new(name) }
        end
      end
    end

    # A `finish_reason` or a `[DONE]`, either of which means generation ended
    # rather than the connection did.
    def complete? : Bool
      @done || !@finish_reason.nil?
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      choice = Wire::Choice.new(0,
        Wire::Response.from_message(rebuild),
        @finish_reason)

      Wire::Response.new([choice], id: @id, model: @model, usage: @usage)
    end

    # Folds one tool-call fragment into the call at its index, returning the
    # tool's name if this fragment is the one that introduced it.
    #
    # The name comes back rather than the event being yielded here, because a
    # `yield` cannot cross into a helper — and announcing a call twice, once
    # per fragment, would be worse than the small awkwardness of returning it.
    private def accumulate(fragment : JSON::Any) : String?
      index = fragment["index"]?.try(&.as_i?) || 0
      pending = @calls[index] ||= Pending.new

      pending.id = fragment["id"]?.try(&.as_s?) || pending.id

      function = fragment["function"]?
      return nil unless function

      function["arguments"]?.try(&.as_s?).try { |chunk| pending.arguments += chunk }

      name = function["name"]?.try(&.as_s?)
      return nil unless name && pending.name.nil?

      pending.name = name
      name
    end

    # Rebuilds the message object a non-streamed reply would have carried.
    private def rebuild : JSON::Any
      fields = {} of String => JSON::Any
      fields["role"] = JSON::Any.new(@role)
      fields["content"] = JSON::Any.new(@content) unless @content.empty?
      fields["reasoning_content"] = JSON::Any.new(@reasoning) unless @reasoning.empty?
      @refusal.try { |value| fields["refusal"] = JSON::Any.new(value) }

      calls = tool_calls
      fields["tool_calls"] = JSON::Any.new(calls) unless calls.empty?

      JSON::Any.new(fields)
    end

    # Calls, but only if generation finished.
    #
    # See the note at the top of this class. Without a per-call completion
    # signal there is nothing to distinguish finished arguments from arguments
    # that are merely finished so far, so a cut stream contributes no calls at
    # all rather than a call that might be a fabrication.
    private def tool_calls : Array(JSON::Any)
      return [] of JSON::Any unless complete?

      @calls.keys.sort!.compact_map do |index|
        pending = @calls[index]
        name = pending.name
        next nil unless name

        JSON::Any.new({
          "id"       => JSON::Any.new(pending.id || ""),
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"      => JSON::Any.new(name),
            "arguments" => JSON::Any.new(pending.arguments.presence || "{}"),
          } of String => JSON::Any),
        } of String => JSON::Any).as(JSON::Any?)
      end
    end

    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = payload["error"]?
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider sent an error chunk",
        error.try(&.["type"]?).try(&.as_s?))
    end
  end
end
