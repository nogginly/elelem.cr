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

    # Letters, digits, dot, dash, underscore; must start with a letter or
    # digit; 64 characters at most.
    #
    # Permissive enough for anything someone would sensibly name a
    # conversation, strict enough that an id can never be anything but a
    # single folder name directly under `folder`.
    ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/

    # Ids have always been user input — `continue SESSID` and `show SESSID`
    # take one straight from argv — and `path_for` used to join it unchecked,
    # so `show ../../somewhere` walked out of the sessions folder. `--id`
    # makes that a *write* path as well, which is why this landed with it,
    # but it is a fix to something that predates it.
    #
    # Enforced in `path_for` rather than at each call site, deliberately: an
    # id becomes dangerous at exactly the moment it becomes a path, so that is
    # the one place a future verb cannot forget to check.
    def validate_id(id : String) : String
      unless ID_PATTERN.matches?(id)
        raise SessionError.new(
          "#{id.inspect} is not a usable session id — letters, digits, dot, dash and underscore only, " \
          "starting with a letter or digit, 64 characters at most")
      end

      # `a..b` satisfies the pattern and is a perfectly good folder name, but
      # nothing good is ever named that, and refusing it means no reader has
      # to reason about whether some path normalisation elsewhere could turn
      # it into a traversal.
      raise SessionError.new("#{id.inspect} is not a usable session id — '..' is not allowed") if id.includes?("..")

      id
    end

    # The same question without the exception, for callers *enumerating* the
    # folder rather than being handed an id.
    #
    # Those are genuinely different situations. An id from argv that fails
    # validation is a mistake worth reporting; a directory entry that fails is
    # debris — `.DS_Store`, an editor swap file, whatever else a filesystem
    # leaves lying about — and listing sessions should no more die on it than
    # on a session folder with no snapshots in it.
    def valid_id?(id : String) : Bool
      ID_PATTERN.matches?(id) && !id.includes?("..")
    end

    def path_for(id : String) : String
      File.join(folder, validate_id(id))
    end

    def exists?(id : String) : Bool
      Dir.exists?(path_for(id))
    end

    # 31 adjectives by 30 nouns is 930 names, and this checks before it
    # returns, so a duplicate is never produced — the old failure mode was
    # running out of *tries*. Twenty tries is comfortable to around 500 stored
    # sessions, deteriorating past 700 and hopeless near 900, which at a few
    # conversations a day is months rather than years. Nothing prunes, so it
    # only ever grows.
    #
    # Hence the fallback: when the two-word space is crowded, number it.
    # Deliberately *only* then — a `-2` never appears until the day it has to,
    # so the first several hundred sessions pay nothing for it, unlike a random
    # suffix that would tax every name from day one against a problem most
    # users will never have. And because the numbering is unbounded, this can
    # no longer fail at all.
    #
    # The real answer for anyone generating sessions in bulk is `--id`, which
    # sidesteps this entirely.
    def generate_id : String
      20.times do
        id = "#{ADJECTIVES.sample}-#{NOUNS.sample}"
        return id unless exists?(id)
      end

      base = "#{ADJECTIVES.sample}-#{NOUNS.sample}"
      suffix = 2
      while exists?("#{base}-#{suffix}")
        suffix += 1
      end
      "#{base}-#{suffix}"
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
      MPSH::Archive.read(latest_archive(id))
    end

    # The newest snapshot's bytes, unparsed. Exists so `show --json` can hand
    # over exactly what is on disk rather than a re-serialization of it.
    def latest_archive(id : String) : String
      File.read(File.join(path_for(id), latest_file(id)))
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

    # One session's snapshots, oldest first, as `<unix_ms>-<deployment>.json`
    # filenames. Sorted lexically, which is also chronological: the timestamp
    # is fixed-width unix milliseconds and leads the name. That will hold
    # until the year 33658, which is later than this comment needs to worry
    # about.
    def snapshots(id : String) : Array(String)
      dir = path_for(id)
      raise SessionError.new("no session named #{id.inspect} in #{folder}") unless Dir.exists?(dir)
      Dir.children(dir).select(&.ends_with?(".json")).sort!
    end

    # Parse a snapshot filename back into the two facts it carries. `nil`
    # deployment for the pre-tracking form, exactly as `latest_deployment`
    # treats it — unknown, never guessed.
    def parse_snapshot(file : String) : {Time, String?}
      base = file.chomp(".json")
      stamp, _, deployment = base.partition("-")
      time = Time.unix_ms(stamp.to_i64? || 0_i64)
      {time, deployment.empty? ? nil : deployment}
    end

    # Every session on disk, most recently active first.
    #
    # Deliberately returns ids rather than loaded `Session`s: listing is the
    # cheap verb and a caller wanting content can ask for it per id.
    #
    # Two kinds of debris are skipped rather than raised on. A folder with no
    # snapshots is what a crashed `start` leaves. An entry that is not a valid
    # id at all is what the filesystem leaves — `.DS_Store` being the one that
    # found this the hard way. A listing that dies on either is worse than one
    # that omits them.
    def list : Array(String)
      return [] of String unless Dir.exists?(folder)

      Dir.children(folder)
        .select { |id| valid_id?(id) && Dir.exists?(path_for(id)) }
        .compact_map { |id| (last = snapshots(id).last?) ? {id, last} : nil }
        .sort_by! { |(_, last)| last }
        .reverse!
        .map { |(id, _)| id }
    end

    private def latest_file(id : String) : String
      files = snapshots(id)
      raise SessionError.new("session #{id.inspect} has no saved turns") if files.empty?
      files.last
    end
  end
end
