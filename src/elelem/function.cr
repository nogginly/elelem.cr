require "./mpsh/block"
require "./options"

module Elelem
  # A tool the caller can declare *and* run.
  #
  # `Tool` is a declaration with no behaviour — it is what goes into `Options`
  # and onto the wire. `Function` is a declaration plus the handler behind it,
  # which is the part this shard could not previously express. Implement it,
  # hand the instances to a `Toolbox`, and the toolbox produces the declarations
  # on the way out and the results on the way back.
  #
  # ```
  # class Weather
  #   include Elelem::Function
  #
  #   def name : String
  #     "get_weather"
  #   end
  #
  #   def description : String?
  #     "Look up the current weather in a city"
  #   end
  #
  #   def parameters : String
  #     %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})
  #   end
  #
  #   def call(arguments : MPSH::Object) : Array(MPSH::Block)
  #     city = arguments["city"]?.as?(String) || "somewhere"
  #     [MPSH::TextBlock.new("18C, light rain in #{city}").as(MPSH::Block)]
  #   end
  # end
  # ```
  module Function
    # Matched against `ToolCallBlock#name`, so it must be what `parameters`
    # describes and what the model was told.
    abstract def name : String

    abstract def description : String?

    # JSON Schema, as text. Text rather than a structured type for the reason
    # `Tool` gives: schemas arrive already serialized from MCP servers and
    # config files, and a caller generating one from a Crystal type can hand
    # over the result without this shard knowing how it was made.
    abstract def parameters : String

    # Runs the tool. The returned blocks become the content of one
    # `MPSH::ToolResultBlock`, which is what makes a tool that returns an image,
    # an audio clip or a file representable without a second content type.
    #
    # Arguments arrive parsed, because `ToolCallBlock#arguments` is already an
    # `MPSH::Object` by the time a reply exists. Handing over a string would
    # mean serializing something already parsed so that it could be parsed
    # again, and parsing is the direction that fails. `MPSH::Value` is a real
    # union rather than a `JSON::Any`, so reach into it with `as?(String)` and
    # friends — there is no wire identity left to re-inspect.
    #
    # Raise `Failure` to report that the tool ran and could not do the job; the
    # message reaches the model. Any other exception is caught by `Toolbox` and
    # recorded as a dispatch that blew up. Neither ends the turn.
    #
    # **A `Function` outlives a single call.** A `Toolbox` holds instances and
    # is usually built once per process, so an instance variable written during
    # `call` does not leak between calls within a turn — it leaks between
    # *sessions*, which surfaces as one conversation seeing another's data.
    # Mint whatever state the work needs inside this method.
    abstract def call(arguments : MPSH::Object) : Array(MPSH::Block)

    # The declaration form, for `Options#tools`.
    def to_tool : Tool
      Tool.new(name, description, parameters)
    end

    # Reported to the model as a failed tool result, with `message` as its text.
    #
    # The consistency this buys is deliberate and provisional: every tool
    # failing in one shape is what stops a model learning a different error
    # dialect per tool, but no single shape survives contact with every tool.
    # Revisit when the CLI has real tools to be opinionated about, not before.
    class Failure < Exception
    end
  end
end
