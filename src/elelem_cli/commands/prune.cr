require "option_parser"
require "../sessions"
require "../output"

module Elelem::Cli::Commands
  # `elelem prune <session-id> --keep <n>` — trims a session's snapshot
  # history to its newest `n` turns, leaving the session itself alone.
  #
  # A separate verb rather than a mode of `delete`, because the two have very
  # different blast radii. Behind a flag on `delete`, a mistyped flag is a lost
  # conversation rather than a lost turn or two; separate words also match the
  # existing grammar, which is all plain verbs.
  #
  # `--keep` has no default deliberately. Every value is a judgement about how
  # much history is worth keeping, and guessing one on the person's behalf is
  # how an irreversible verb becomes a surprising one.
  module Prune
    extend self

    USAGE = "usage: elelem prune <session-id> --keep <n>"

    def run(args : Array(String)) : Nil
      keep : Int32? = nil

      OptionParser.parse(args) do |parser|
        parser.on("--keep N", "how many of the newest snapshots to keep") do |value|
          keep = value.to_i?
          raise ArgumentError.new("--keep wants a whole number, not #{value.inspect}") unless keep
        end
      end

      id = args[0]?
      count = keep
      raise ArgumentError.new(USAGE) if id.nil? || args.size > 1 || count.nil?

      before = Sessions.snapshots(id).size
      removed = Sessions.prune(id, count)
      Output.pruned(id, removed.size, before - removed.size)
    end
  end
end
