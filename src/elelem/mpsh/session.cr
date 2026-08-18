require "./message"
require "./annotation"

module Elelem::MPSH
  # MPSH mints its own identifiers. Gemini pairs a call to its response by
  # function name and ordering, with no id at all, so a stored OpenAI
  # `call_...` cannot supply what a Gemini mapper needs — and a Gemini-born
  # session has nothing to store in the first place.
  module Ids
    @@counter = Atomic(Int64).new(0)

    def self.call_id : String
      "mc_#{Time.utc.to_unix_ms}_#{@@counter.add(1)}"
    end
  end

  # The canonical session. Flat by design: no tree, no branches, no bindings —
  # those arrive later and must be able to change without touching a mapper.
  #
  # Note what is absent: any `to_json` that a provider could accept. Storage
  # form is not wire form, and the surest way to keep it that way is for the
  # canonical types to have no serialization identity of their own. Persistence
  # is an explicit codec, added beside these types, not mixed into them.
  class Session
    property system_prompt : String?
    getter messages : Array(Message)
    getter annotations : Array(Annotation)

    def initialize(@system_prompt : String? = nil,
                   @messages : Array(Message) = [] of Message,
                   @annotations : Array(Annotation) = [] of Annotation)
    end

    def <<(message : Message) : self
      @messages << message
      self
    end

    def annotate(note : Annotation) : Nil
      @annotations << note
    end

    # A shallow copy sharing message objects — enough to hand the same history
    # to a second provider without either mapper mutating the other's view.
    def fork : Session
      Session.new(@system_prompt, @messages.dup, @annotations.dup)
    end

    def size : Int32
      @messages.size
    end
  end
end
