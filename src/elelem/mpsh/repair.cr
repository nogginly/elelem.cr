require "./message"
require "./session"

module Elelem::MPSH
  # Makes a cut turn safe to build on.
  #
  # **The invariant**: no `ToolCallBlock` without a matching `ToolResultBlock`.
  # A dangling call is the one shape Anthropic rejects outright and the others
  # merely tolerate, so a session carrying one is not portable — which is the
  # single property this format exists to keep.
  #
  # Pure MPSH, and deliberately so. Repair reads and rewrites canonical types
  # and nothing else; it has no protocol, no provider and no transport, so a
  # session reloaded from an archive can be repaired without any of them being
  # available.
  #
  # ## Why the calls go and the text stays
  #
  # Text's partial form is valid text: a prefix is a legitimate short answer.
  # A tool call's is not — half an arguments blob cannot be dispatched. Worse
  # than being unusable, a *complete-looking* partial set may be half a parallel
  # plan, and nothing in the reply says whether another call was about to
  # arrive. So every call goes, whether or not it parses.
  #
  # The four assemblers already reach this outcome for a cut stream, each by
  # refusing to emit a call it cannot vouch for. What is left for this module is
  # the non-streamed case, where a complete 200 body legitimately carries a call
  # set the model never finished planning.
  module Repair
    extend self

    # Whether the message holds anything the invariant forbids.
    def needed?(message : Message) : Bool
      message.ending.cut? && message.content.any?(ToolCallBlock)
    end

    # The same turn, made sendable — or `nil` when nothing survives, which is a
    # cut that produced only tool calls. An empty message is content removed to
    # satisfy a validator, so the caller appends nothing rather than appending a
    # message that says nothing.
    #
    # A new `Message`; the original is untouched, so a caller holding one for
    # display keeps what actually arrived.
    def repaired(message : Message) : Message?
      return message unless needed?(message)

      # ameba:disable Style/IsAFilter - Need T in Array(T) to retain ToolCallBlock
      kept = message.content.reject(&.is_a?(ToolCallBlock))
      return nil if kept.empty?

      repaired = Message.new(message.role, kept, message.provenance)
      repaired.ending = message.ending
      repaired.provider_metadata = message.provider_metadata
      repaired
    end

    # Repairs a session in place, returning whether anything changed.
    #
    # For the reload path: an archive may hold a turn that was never repaired
    # before it was written, since the exporter is honest and repair is the
    # caller's to invoke.
    #
    # Only messages this method emptied are removed. A message that arrived
    # empty is left alone — divergent provider handling of empty messages is
    # its own fixture, and quietly deleting one here would change what a
    # session says while claiming to repair it.
    def repair!(session : Session) : Bool
      emptied = [] of Int32
      changed = false

      session.messages.each_with_index do |message, index|
        next unless needed?(message)
        changed = true
        if fixed = repaired(message)
          session.messages[index] = fixed
        else
          emptied << index
        end
      end

      emptied.reverse_each { |index| session.messages.delete_at(index) }
      changed
    end

    # The acceptance test, expressed once: every tool call has its result.
    #
    # Server-executed calls are included. Their result arrives with them, so a
    # missing one is as dangling as any other — and it is the target protocol's
    # validator that decides, not the flag.
    def sendable?(session : Session) : Bool
      answered = Set(String).new
      session.messages.each do |message|
        message.content.each do |block|
          answered << block.call_id if block.is_a?(ToolResultBlock)
        end
      end

      session.messages.all? do |message|
        message.content.all? do |block|
          !block.is_a?(ToolCallBlock) || answered.includes?(block.call_id)
        end
      end
    end
  end
end
