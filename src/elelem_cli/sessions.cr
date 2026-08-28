require "../elelem"

module Elelem::Cli
  class SessionError < Exception
  end

  # Folder-per-session, snapshot-per-turn — see docs/CLI_DESIGN.md for why a
  # full `Archive` per turn rather than a diff log: MPSH already rebuilds the
  # whole request from the whole history on every call, so a session's true
  # state at any point already *is* a complete snapshot.
  module Sessions
    extend self

    # Boring on purpose: no adjectives or nouns clever enough to need
    # explaining, easy to say over voice chat, easy to type without a typo.
    ADJECTIVES = %w[brisk quiet bold calm eager fond glad keen lively merry
      nimble proud sunny swift tidy witty amber coral dusty
      faint gentle honest jolly kind lucid mellow noble plain
      rustic sturdy vivid]
    NOUNS = %w[comet otter falcon cedar harbor meadow willow ember granite
      lagoon summit thicket brook canyon glacier heron ivy juniper
      knoll lantern maple nectar orchid pebble quarry ridge sparrow
      tundra vale wren]

    # `$ELELEM_HOME` first if set — explicit beats implicit, the same
    # reasoning `Config` now applies to `$ELELEM_CONFIG`. This is a change
    # from the original order (`$CWD`, then `$HOME`, then `$ELELEM_HOME` as
    # a last resort): a real invocation's `.elelem` sitting in `$CWD` or
    # `$HOME` gave a sandboxed test nothing to override it with, the same gap
    # that showed up first in `Config`. Checking `$CWD` before `$HOME` is
    # still right for ordinary use; explicit still beats both.
    def root : String
      return ENV["ELELEM_HOME"] if ENV["ELELEM_HOME"]?

      cwd_candidate = File.join(Dir.current, ".elelem")
      return cwd_candidate if Dir.exists?(cwd_candidate)

      if home = ENV["HOME"]?
        return File.join(home, ".elelem")
      end

      raise SessionError.new("no $HOME and no $ELELEM_HOME — nowhere to store sessions")
    end

    def folder : String
      File.join(root, "sessions")
    end

    def path_for(id : String) : String
      File.join(folder, id)
    end

    def exists?(id : String) : Bool
      Dir.exists?(path_for(id))
    end

    # Retried, not guaranteed — the id space is small enough on purpose (a
    # few hundred combinations) that a collision is worth handling cheaply
    # rather than reaching for a hash the person would never want to type.
    def generate_id : String
      20.times do
        id = "#{ADJECTIVES.sample}-#{NOUNS.sample}"
        return id unless exists?(id)
      end
      raise SessionError.new("could not find an unused session id after 20 tries")
    end

    # Writes a new timestamped snapshot. Nothing already on disk is touched —
    # every `continue` grows the folder, it never overwrites.
    #
    # The deployment name rides in the filename, not just the JSON body —
    # `<unix_ms>-<deployment>.json`. That's what makes `latest_deployment`
    # answer "what was this conversation already having" without touching
    # `Archive` at all: a session's `Provenance` records a vendor claim, not
    # a config deployment name, and those can legitimately differ (Azure, a
    # gateway) — this fact belongs to *how you're using elelem*, not to the
    # portable conversation itself, so it stays out of the archive proper.
    def snapshot(id : String, session : MPSH::Session, deployment : String) : String
      dir = path_for(id)
      Dir.mkdir_p(dir)
      file = File.join(dir, "#{Time.utc.to_unix_ms}-#{deployment}.json")
      File.write(file, MPSH::Archive.write(session))
      file
    end

    def latest(id : String) : MPSH::Session
      MPSH::Archive.read(File.read(File.join(path_for(id), latest_file(id))))
    end

    # `nil` for a snapshot written before this existed — `<unix_ms>.json`
    # with no deployment segment. Treated as genuinely unknown, not guessed
    # at: the caller asks for an explicit `--on` once, and every snapshot
    # after that carries the answer.
    def latest_deployment(id : String) : String?
      base = latest_file(id).chomp(".json")
      parts = base.split("-", 2)
      parts.size == 2 ? parts[1] : nil
    end

    private def latest_file(id : String) : String
      dir = path_for(id)
      raise SessionError.new("no session named #{id.inspect} in #{folder}") unless Dir.exists?(dir)

      files = Dir.children(dir).select(&.ends_with?(".json")).sort!
      raise SessionError.new("session #{id.inspect} has no saved turns") if files.empty?

      files.last
    end
  end
end
