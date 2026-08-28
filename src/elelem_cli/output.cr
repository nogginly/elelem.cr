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
  end
end
