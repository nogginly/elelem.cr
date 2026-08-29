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
  # The requirement that motivated `CompletedTurns` is *model*-specific, not
  # protocol-specific — one model family asking that past reasoning be dropped
  # once a turn closes. Everything else in this shard is keyed on protocol,
  # which left an open question: should a model catalog exist for this?
  #
  # **Settled: no.** It is operator configuration, stated per deployment in
  # the CLI's `elelem.yaml`, not a table in this library. The line is between
  # hard protocol facts and soft quality preferences. `Capability::Catalog`
  # holds the former — get `SIGNED_TOOL_CALLS` wrong and the request 400s, and
  # the vendor is the authority. This is the latter: get it wrong and the
  # answers are merely worse, the source is a model card rather than an API
  # contract, and two people running the same model may reasonably disagree.
  #
  # Which is why this enum stays a plain caller-supplied preference and gains
  # no lookup of its own. See `Elelem::Cli::Deployment`.
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
