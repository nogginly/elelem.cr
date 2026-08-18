require "./block"

module Elelem::MPSH
  # Two roles. `system`, `developer`, `tool` and `model` are provider spellings
  # and are resolved at map time, in both directions.
  enum Role
    User
    Assistant
  end

  # Who produced an assistant turn. Historical only — it never influences mapping.
  struct Provenance
    getter provider : String
    getter model : String
    getter bias : String?

    def initialize(@provider : String, @model : String, @bias : String? = nil)
    end
  end

  class Message
    include ProviderScoped

    getter role : Role
    getter content : Array(Block)
    getter provenance : Provenance?

    def initialize(@role : Role, @content : Array(Block) = [] of Block,
                   @provenance : Provenance? = nil)
    end

    def self.user(text : String)
      new(Role::User, [TextBlock.new(text).as(Block)])
    end

    def self.assistant(text : String, provenance : Provenance? = nil)
      new(Role::Assistant, [TextBlock.new(text).as(Block)], provenance)
    end

    def text : String
      content.compact_map { |block| block.as?(TextBlock).try &.text }.join("\n\n")
    end
  end
end
