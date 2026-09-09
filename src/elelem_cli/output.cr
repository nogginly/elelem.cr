require "colorize"
require "../elelem"

module Elelem::Cli
  # The reply is the only thing on stdout, so `elelem start ... | pbcopy`
  # gets exactly the text and nothing else. Everything about the call itself
  # — the session id, fidelity warnings — goes to stderr.
  module Output
    extend self

    # Where the two streams go, injectable purely so specs can read them
    # back. `start` and `continue` predate this and never needed it — their
    # observable effect is a file on disk. `list` and `show` write nothing and
    # call nothing; their entire behaviour *is* what lands on stdout, so
    # without a seam here they can only be tested by asserting that they did
    # not raise, which is not a test.
    class_property stream : IO = STDOUT
    class_property error_stream : IO = STDERR

    def reply(message : MPSH::Message) : Nil
      stream.puts message.text
    end

    # A turn that did not finish, said once, on stderr.
    #
    # Not a fidelity annotation, and deliberately not routed through
    # `warn_lossy`: an annotation means damage this shard's mapping inflicted,
    # and an interrupted turn is something that happened to the connection or
    # the model. Mixing the two makes the annotation channel mean less.
    #
    # Silent when the turn completed, which is nearly always.
    def warn_cut(reply : MPSH::Message) : Nil
      return if reply.ending.complete?

      dropped = reply.content.count { |block| block.is_a?(MPSH::ToolCallBlock) }
      note = case reply.ending
             in MPSH::Ending::Complete    then return
             in MPSH::Ending::Truncated   then "the model stopped short — an output cap or a resource limit"
             in MPSH::Ending::Stopped     then "the turn was stopped"
             in MPSH::Ending::Interrupted then "the stream ended before the reply did"
             end

      error_stream.puts "warning: #{note}"
      return if dropped.zero?

      error_stream.puts "warning: #{dropped} unfinished tool #{dropped == 1 ? "call" : "calls"} " \
                        "left out of the saved session"
    end

    # Said out loud because it changes what is on disk. A session that arrives
    # holding a dangling call was written by something that did not repair it,
    # and quietly fixing a file someone may be reasoning about is worse than
    # one line on stderr.
    def repaired_on_load(id : String) : Nil
      error_stream.puts "note: #{id} held an unfinished turn from an earlier run; it was repaired on load"
    end

    # A fragment of the reply, as it arrives. Flushed immediately: a delta held
    # in a buffer is a delta that has not been streamed.
    #
    # No newline of its own. Deltas do not arrive on line boundaries, and
    # inventing them would put the streamed reply and the saved one at odds
    # over something as visible as where the lines break.
    def text_delta(text : String) : Nil
      stream.print text
      stream.flush
    end

    # Closes a streamed reply, so a shell prompt does not land on the last
    # line of it. Called once per turn, and only when something was printed.
    def end_stream : Nil
      stream.puts
    end

    # Reasoning goes to stderr, always, streamed or not.
    #
    # `Output.reply` prints `Message#text`, which concatenates text blocks
    # only, so reasoning has never reached stdout and streaming must not be
    # what changes that. `elelem start … > answer.txt` gets an answer, not an
    # answer with the model's thinking wrapped around it.
    #
    # A rule and a divider, so the two are distinguishable when both are on a
    # terminal and interleaved. Grey because thinking is not the answer and
    # should not compete with it for attention.
    def reasoning_open : Nil
      error_stream.print "\n┄┄┄ thinking ┄┄┄\n".colorize.dark_gray
      error_stream.flush
    end

    def reasoning_delta(text : String) : Nil
      error_stream.print text.colorize.dark_gray
      error_stream.flush
    end

    def reasoning_close : Nil
      error_stream.print "\n┄┄┄\n".colorize.dark_gray
      error_stream.flush
    end

    # Colour is decided on **stderr**, because that is the only stream the CLI
    # colours. The asymmetry with the streaming decision — which asks about
    # stdout — is deliberate: each asks about the stream it writes to, which is
    # the same reasoning that keeps `Progress` on `STDERR.tty?`.
    #
    # `Colorize.default_enabled?` is the whole test, `NO_COLOR` included, so
    # everything below can go on saying `.colorize.dark_gray` without asking.
    # A spec that has redirected `error_stream` into memory gets plain text for
    # free.
    def tune_colour : Nil
      Colorize.enabled = Colorize.default_enabled?(error_stream)
    end

    def session_id(id : String) : Nil
      error_stream.puts "Session: #{id}"
    end

    # `Restructured` is business as usual for most protocols and says
    # nothing worth a warning on every call. `Degraded` and `Refused` are the
    # two outcomes `Outcome#lossy?` actually means — something the person
    # asked for didn't survive the trip, and staying silent about that here
    # is exactly the failure mode the annotation channel exists to prevent.
    def warn_lossy(report : Capability::Report) : Nil
      report.annotations.select(&.outcome.lossy?).each { |note| error_stream.puts "warning: #{note}" }
    end

    # One line per session, most recent first. Columns rather than prose: the
    # obvious next thing anyone does with a listing is pipe it somewhere.
    def session_line(id : String, turns : Int32, deployment : String?, at : Time,
                     preview : String) : Nil
      stream.puts "#{id.ljust(18)} #{turns.to_s.rjust(3)} turns  " \
                  "#{(deployment || "?").ljust(14)} #{at.to_s("%Y-%m-%d %H:%M")}  #{preview}"
    end

    def no_sessions : Nil
      error_stream.puts "No sessions yet. Start one with: elelem start <deployment> <prompt...>"
    end

    # A session transcript.
    #
    # **Every block is rendered, not just the text ones.** `Message#text`
    # concatenates text blocks and silently omits everything else, which is
    # correct for printing a reply and wrong for an inspection verb: a
    # transcript that quietly drops the tool calls and reasoning would
    # misrepresent exactly the sessions this shard exists to carry around, and
    # would do it most convincingly on the sessions that matter most. Non-text
    # blocks get a bracketed one-line descriptor instead — enough to know the
    # block is there and what it is, without dumping base64 into a terminal.
    def transcript(session : MPSH::Session) : Nil
      if prompt = session.system_prompt
        stream.puts "system: #{prompt}"
        stream.puts
      end

      session.messages.each do |message|
        stream.puts "#{message.role.to_s.downcase}:"
        message.content.each { |block| stream.puts "  #{describe(block)}" }
        stream.puts
      end
    end

    def describe(block : MPSH::Block) : String
      case block
      in MPSH::TextBlock
        block.text
      in MPSH::ImageBlock, MPSH::AudioBlock
        "[#{block.kind.to_s.downcase} #{block.media_type}#{fallback(block.text_fallback)}]"
      in MPSH::DocumentBlock
        "[document #{block.media_type} #{block.name}#{fallback(block.text_fallback)}]"
      in MPSH::ToolCallBlock
        run_by = block.server_executed? ? ", server-run" : ""
        "[tool call #{block.name}(#{block.arguments.to_json})#{run_by}]"
      in MPSH::ToolResultBlock
        state = block.is_error? ? "error" : "result"
        inner = block.content.map { |nested| describe(nested) }.join(" ")
        "[tool #{state} #{inner}]"
      in MPSH::ReasoningBlock
        # Redacted reasoning has no text by definition; saying so is the whole
        # point, since its absence is otherwise indistinguishable from a block
        # that was never there.
        block.redacted? ? "[reasoning, redacted]" : "[reasoning] #{block.text}"
      in MPSH::RefusalBlock
        "[refusal#{block.reason.try { |reason| ": #{reason}" }}]"
      end
    end

    private def fallback(text : String?) : String
      text ? %( "#{text}") : ""
    end

    # The append-only turn history — the one part of the storage design that
    # is invisible from a transcript, since a transcript only ever shows the
    # newest snapshot.
    def snapshot_line(index : Int32, at : Time, deployment : String?) : Nil
      stream.puts "#{(index + 1).to_s.rjust(3)}. #{at.to_s("%Y-%m-%d %H:%M:%S")}  #{deployment || "unknown"}"
    end

    # What the destructive verbs removed.
    #
    # On stderr, with the session id and the fidelity warnings, rather than on
    # stdout with the listings. The rule at the top of this file is that stdout
    # carries the thing you would pipe somewhere and stderr carries everything
    # about the invocation itself; a receipt for work already done is the
    # second kind. It also keeps `delete` and `prune` from being the only
    # verbs whose stdout a script would have to learn to ignore.
    def deleted(id : String, snapshots : Int32) : Nil
      error_stream.puts "Deleted #{id} and its #{snapshots} #{snapshots == 1 ? "snapshot" : "snapshots"}."
    end

    # Named counts rather than a bare number: pruning is irreversible, and the
    # useful thing to read afterwards is what survived, not what went.
    def pruned(id : String, removed : Int32, kept : Int32) : Nil
      if removed.zero?
        error_stream.puts "Nothing to prune in #{id} — #{kept} #{kept == 1 ? "snapshot" : "snapshots"} kept."
      else
        error_stream.puts "Pruned #{removed} #{removed == 1 ? "snapshot" : "snapshots"} from #{id}, #{kept} kept."
      end
    end
  end
end
