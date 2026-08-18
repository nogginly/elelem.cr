require "./profile"
require "./policy"
require "../mpsh/message"

module Elelem::Capability
  # The specification's capability matrix is block-centric. Some adaptations are
  # not: merging consecutive same-role messages for Anthropic, or prepending a
  # placeholder when history starts with the assistant, happen at the level of
  # the message sequence and have outcomes of their own.
  #
  # This matters for conformance rather than aesthetics. Merging two user
  # messages into one is *not* round-trippable — the export side gets one
  # message where MPSH held two, and cannot know where to cut. Classified as
  # Compensated, the divergence is predicted by the matrix and the fixture
  # passes; left undeclared, it reads as a mapper bug forever.
  module Structural
    extend self

    enum Adaptation
      MergeConsecutiveRoles
      PrependUserPlaceholder
      DropEmptyMessage
      MoveSystemPrompt
      # A compensation carrier held back until every tool result answering one
      # assistant turn has been emitted. Strict servers reject scaffolding
      # interleaved between tool responses.
      DeferCompensationCarrier
    end

    def outcome(adaptation : Adaptation) : MPSH::Outcome
      case adaptation
      in Adaptation::MoveSystemPrompt         then MPSH::Outcome::Restructured
      in Adaptation::MergeConsecutiveRoles    then MPSH::Outcome::Compensated
      in Adaptation::PrependUserPlaceholder   then MPSH::Outcome::Compensated
      in Adaptation::DropEmptyMessage         then MPSH::Outcome::Degraded
      in Adaptation::DeferCompensationCarrier then MPSH::Outcome::Compensated
      end
    end

    # Which adaptations a given history will need for a given profile, computed
    # before anything is sent so a caller can be told in advance.
    def required(messages : Array(MPSH::Message), profile : Profile) : Array(Adaptation)
      needed = [] of Adaptation

      if profile.first_message_must_be_user?
        first = messages.first?
        needed << Adaptation::PrependUserPlaceholder if first && first.role.assistant?
      end

      if profile.alternation_required?
        messages.each_cons(2) do |pair|
          if pair[0].role == pair[1].role
            needed << Adaptation::MergeConsecutiveRoles
            break
          end
        end
      end

      needed << Adaptation::MoveSystemPrompt unless profile.system_placement.in_messages?
      needed
    end
  end
end
