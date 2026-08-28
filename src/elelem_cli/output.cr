require "../elelem"

module Elelem::Cli
  # The reply is the only thing on stdout, so `elelem start ... | pbcopy`
  # gets exactly the text and nothing else. Everything about the call itself
  # — the session id, fidelity warnings — goes to stderr.
  module Output
    extend self

    def reply(message : MPSH::Message) : Nil
      puts message.text
    end

    def session_id(id : String) : Nil
      STDERR.puts "Session: #{id}"
    end

    # `Restructured` is business as usual for most protocols and says
    # nothing worth a warning on every call. `Degraded` and `Refused` are the
    # two outcomes `Outcome#lossy?` actually means — something the person
    # asked for didn't survive the trip, and staying silent about that here
    # is exactly the failure mode the annotation channel exists to prevent.
    def warn_lossy(report : Capability::Report) : Nil
      report.annotations.select(&.outcome.lossy?).each { |note| STDERR.puts "warning: #{note}" }
    end
  end
end
