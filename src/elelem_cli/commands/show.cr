require "option_parser"
require "../sessions"
require "../output"

module Elelem::Cli::Commands
  # `elelem show <session-id>` — the whole conversation as it currently
  # stands, every block rendered.
  #
  # Two flags, each answering a question the plain transcript cannot:
  #
  # - `--snapshots` lists the append-only turn history. A transcript only ever
  #   shows the newest snapshot, so without this the per-turn storage design
  #   is invisible from the CLI that implements it.
  # - `--json` emits the raw `Archive` form on stdout. This is the portable
  #   artefact the whole shard is about, so being able to get it out without
  #   knowing the on-disk folder convention is worth one flag. It is the
  #   stored bytes, not a re-serialization, so it round-trips by construction.
  module Show
    extend self

    USAGE = "usage: elelem show <session-id> [--snapshots] [--json]"

    def run(args : Array(String)) : Nil
      snapshots = false
      json = false

      OptionParser.parse(args) do |parser|
        parser.on("--snapshots", "list the saved turns instead of the transcript") { snapshots = true }
        parser.on("--json", "emit the stored archive form") { json = true }
      end

      id = args[0]?
      raise ArgumentError.new(USAGE) if id.nil? || args.size > 1
      raise ArgumentError.new("--snapshots and --json ask for different things") if snapshots && json

      if snapshots
        Sessions.snapshots(id).each_with_index do |file, index|
          at, deployment = Sessions.parse_snapshot(file)
          Output.snapshot_line(index, at, deployment)
        end
        return
      end

      if json
        # Deliberately the file's own bytes rather than
        # `Archive.write(Sessions.latest(id))`: a read-then-write would put
        # this command's understanding of the format between the person and
        # their data, and quietly rewrite anything it did not understand.
        Output.stream.puts Sessions.latest_archive(id)
        return
      end

      Output.transcript(Sessions.latest(id))
    end
  end
end
