require "../mpsh/turns"

module Elelem::Capability
  # A **playback preference**, not a capability.
  #
  # Capability answers "can this protocol carry the block". Retention answers
  # "does the caller want it replayed". They are separate axes and must not be
  # conflated: a protocol that carries reasoning perfectly may still be asked to
  # receive none of it, and no annotation is warranted when that happens.
  # Annotations record loss the caller did not ask for. Burying a deliberate
  # choice in the same channel as silent damage makes the channel worthless.
  enum ReasoningRetention
    All            # replay everything the target can read; the default
    CompletedTurns # drop reasoning from closed turns, own and foreign alike
    None           # drop every reasoning block

    # `index` is the position of the containing message in the history.
    def retain?(index : Int32, completed : Set(Int32)) : Bool
      case self
      in All            then true
      in None           then false
      in CompletedTurns then !completed.includes?(index)
      end
    end
  end

  # Applies retention to a history at map time. Returns indices only — nothing
  # is copied, nothing is mutated, and the canonical session is untouched.
  #
  # NOTE (open, deliberately not designed yet): the requirement that motivated
  # `CompletedTurns` is *model*-specific, not protocol-specific — one model
  # family asking that past reasoning be dropped once a turn closes. Everything
  # else in this shard is keyed on protocol. Whether a model catalog should
  # exist, independent of the protocol a model is reached through, and what
  # minimal set of preferences it would carry, is an open design question
  # parked until the protocol layer exists.
  module Retention
    extend self

    struct Plan
      getter dropped : Int32
      getter retain : Set(Int32)

      def initialize(@retain : Set(Int32), @dropped : Int32)
      end

      # Reasoning blocks in this message survive playback.
      def retain?(message_index : Int32) : Bool
        @retain.includes?(message_index)
      end
    end

    def plan(messages : Array(MPSH::Message), retention : ReasoningRetention) : Plan
      completed = retention.completed_turns? ? MPSH::Turns.completed_indices(messages) : Set(Int32).new
      retain = Set(Int32).new
      dropped = 0

      messages.each_with_index do |message, index|
        next unless message.content.any?(MPSH::ReasoningBlock)
        if retention.retain?(index, completed)
          retain << index
        else
          dropped += message.content.count { |block| block.is_a?(MPSH::ReasoningBlock) }
        end
      end

      Plan.new(retain, dropped)
    end
  end
end
