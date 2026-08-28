require "../sessions"
require "../output"

module Elelem::Cli::Commands
  # `elelem list` — what conversations exist, and which deployment each one
  # was last having.
  #
  # Reads the newest snapshot per session and nothing else. That one file is
  # already a complete point-in-time record (`docs/CLI_DESIGN.md`, *Session
  # storage*), so the turn count and opening prompt come free from a read the
  # listing has to do anyway to prove the session is intact.
  module List
    extend self

    USAGE = "usage: elelem list"

    PREVIEW_WIDTH = 48

    def run(args : Array(String)) : Nil
      raise ArgumentError.new(USAGE) unless args.empty?

      ids = Sessions.list
      return Output.no_sessions if ids.empty?

      ids.each do |id|
        file = Sessions.snapshots(id).last
        at, deployment = Sessions.parse_snapshot(file)

        # A snapshot that will not parse is reported, not fatal. One corrupt
        # session should cost you that session, not the ability to find the
        # other nineteen.
        begin
          session = Sessions.latest(id)
          Output.session_line(id, session.messages.size, deployment, at, preview(session))
        rescue e : Exception
          Output.session_line(id, 0, deployment, at, "<unreadable: #{e.class}>")
        end
      end
    end

    # The opening user turn, which is what anyone scanning a list is actually
    # looking for — "which one was the tax thing?" Falls back to the first
    # message of any role, since a session may open with an assistant turn.
    private def preview(session : MPSH::Session) : String
      message = session.messages.find(&.role.user?) || session.messages.first?
      return "<empty>" unless message

      text = message.content.map { |block| Output.describe(block) }.join(" ")
      text = text.gsub(/\s+/, " ").strip
      text.size > PREVIEW_WIDTH ? "#{text[0, PREVIEW_WIDTH - 1]}…" : text
    end
  end
end
