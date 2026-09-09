require "./config"

module Elelem::Cli
  # What the terminal does while an answer arrives: whether to show it as it
  # comes, and whether to show the model thinking.
  #
  # One module rather than a few lines in each command, because the precedence
  # has an asymmetry in it that is worth stating once and worth nobody
  # re-deriving. Both verbs resolve through here.
  struct Display
    getter? streaming : Bool
    getter? show_reasoning : Bool

    def initialize(@streaming : Bool, @show_reasoning : Bool)
    end

    # Flag, then configuration, then the terminal — with the terminal acting
    # as a floor that configuration does not lift.
    #
    # `defaults.streaming: true` says how someone likes to watch answers
    # arrive. It is not a claim that a cron job redirecting stdout into a file
    # wants a failure mode nobody will see: a stream that ends without its
    # terminal frame is a way to be truncated that only exists when you
    # stream, and a redirected run gets nothing back for accepting it. So a
    # non-terminal stdout declines to stream even when the config asked.
    #
    # `--stream` goes through that floor, because a flag is typed with one
    # particular run in view — the caller who has just asked for a very large
    # output and would rather the connection stayed warm.
    #
    # Reasoning has no such floor. It is a question about what to show, not
    # about how to fetch, so nothing is risked by honouring it into a pipe.
    def self.resolve(defaults : Defaults,
                     stream : Bool? = nil,
                     show_reasoning : Bool? = nil,
                     stdout : IO = STDOUT) : Display
      streaming = if stream.nil?
                    defaults.streaming? && stdout.tty?
                  else
                    stream
                  end

      new(streaming, show_reasoning.nil? ? defaults.show_reasoning? : show_reasoning)
    end
  end
end
