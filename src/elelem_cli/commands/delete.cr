require "../sessions"
require "../output"

module Elelem::Cli::Commands
  # `elelem delete <session-id>` — removes a session and everything stored
  # under it.
  #
  # **Naming the id is the confirmation.** No prompt, and no `--yes` to make
  # the prompt go away. This CLI is non-interactive and single-shot by design
  # (`docs/CLI_DESIGN.md`, *What this is, and what it deliberately is not*),
  # prompting needs a stdin the recorded-command specs do not have, and `rm
  # foo` does not ask either.
  #
  # That posture only holds while the blast radius is one typed name, which is
  # why there is no `--all`, no glob and no bulk mode. A verb that can remove
  # an unknown number of sessions is a different verb and would need a
  # different answer to the confirmation question.
  module Delete
    extend self

    USAGE = "usage: elelem delete <session-id>"

    def run(args : Array(String)) : Nil
      id = args[0]?
      raise ArgumentError.new(USAGE) if id.nil? || args.size > 1

      snapshots = Sessions.delete(id)
      Output.deleted(id, snapshots)
    end
  end
end
