require "../spec_helper"
require "file_utils"
require "../../src/elelem_cli/sessions"

# `Sessions.root` checks `$CWD/.elelem` *exists* before choosing it — it
# doesn't create one speculatively — so sandboxing means pre-creating an
# empty `.elelem` in a temp dir and `Dir.cd`-ing into it, not just changing
# directory. No source change needed for this: it's exactly the resolution
# order `docs/CLI_DESIGN.md` documents, exercised for real rather than routed
# around.
private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "elelem-cli-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".elelem"))
  begin
    Dir.cd(tmp) { yield }
  ensure
    FileUtils.rm_rf(tmp)
  end
end

describe Elelem::Cli::Sessions do
  it "resolves root to $CWD/.elelem when it exists" do
    with_sandbox do
      Elelem::Cli::Sessions.root.should eq(File.join(Dir.current, ".elelem"))
    end
  end

  it "generates a short, memorable, unused id" do
    with_sandbox do
      id = Elelem::Cli::Sessions.generate_id
      id.should match(/\A[a-z]+-[a-z]+\z/)
      Elelem::Cli::Sessions.exists?(id).should be_false
    end
  end

  it "round-trips a snapshot and reports which deployment produced it" do
    with_sandbox do
      session = M::Session.new("be terse")
      session << M::Message.user("hi")

      id = Elelem::Cli::Sessions.generate_id
      Elelem::Cli::Sessions.snapshot(id, session, "anthropic")

      Elelem::Cli::Sessions.exists?(id).should be_true
      Elelem::Cli::Sessions.latest_deployment(id).should eq("anthropic")

      restored = Elelem::Cli::Sessions.latest(id)
      restored.messages.size.should eq(session.messages.size)
      restored.system_prompt.should eq("be terse")
    end
  end

  it "keeps every snapshot rather than overwriting the last one" do
    with_sandbox do
      id = Elelem::Cli::Sessions.generate_id
      Elelem::Cli::Sessions.snapshot(id, M::Session.new, "anthropic")
      Elelem::Cli::Sessions.snapshot(id, M::Session.new, "azure-mini")

      Dir.children(Elelem::Cli::Sessions.path_for(id)).size.should eq(2)
      Elelem::Cli::Sessions.latest_deployment(id).should eq("azure-mini")
    end
  end

  # The CI failure this fixes, reproduced without needing a fast runner.
  #
  # Two writes with no sleep between them land in the same millisecond on any
  # machine worth the name. Before the stamp bump, `snapshots` then sorted on
  # the segment after the timestamp, where `ollama-responses` precedes
  # `ollama` — `-` is 0x2D, `.` is 0x2E — so the *newer* snapshot sorted first
  # and `latest_deployment` named the deployment just switched away from.
  #
  # The deployment names are load-bearing and deliberately the ones from
  # `continue_spec.cr`: the bug needs one name to be a prefix of the other, so
  # a pair like `anthropic`/`azure-mini` cannot show it. It also only fails in
  # one direction — switching from the shorter name to the longer — which is
  # why the reverse is asserted too rather than assumed symmetric.
  it "orders snapshots written in the same millisecond by write order, not by name" do
    with_sandbox do
      id = Elelem::Cli::Sessions.generate_id
      Elelem::Cli::Sessions.snapshot(id, M::Session.new, "ollama")
      Elelem::Cli::Sessions.snapshot(id, M::Session.new, "ollama-responses")

      Elelem::Cli::Sessions.snapshots(id).size.should eq(2)
      Elelem::Cli::Sessions.latest_deployment(id).should eq("ollama-responses")

      other = Elelem::Cli::Sessions.generate_id
      Elelem::Cli::Sessions.snapshot(other, M::Session.new, "ollama-responses")
      Elelem::Cli::Sessions.snapshot(other, M::Session.new, "ollama")

      Elelem::Cli::Sessions.latest_deployment(other).should eq("ollama")
    end
  end

  # A tight run, to prove the bump keeps ordering rather than merely avoiding a
  # collision: every stamp distinct, and the sorted filenames in write order.
  it "keeps a burst of snapshots distinct and in order" do
    with_sandbox do
      id = Elelem::Cli::Sessions.generate_id
      written = (1..8).map { |n| Elelem::Cli::Sessions.snapshot(id, M::Session.new, "d#{n}") }

      files = Elelem::Cli::Sessions.snapshots(id)
      files.size.should eq(8)
      files.should eq(written.map { |path| File.basename(path) })
      files.map { |file| Elelem::Cli::Sessions.parse_snapshot(file)[0] }.uniq.size.should eq(8)
    end
  end

  it "returns nil for a snapshot with no deployment segment in its filename" do
    with_sandbox do
      # Simulates a session saved before deployment-in-filename existed —
      # see docs/CLI_DESIGN.md, "A snapshot written before this existed."
      id = Elelem::Cli::Sessions.generate_id
      dir = Elelem::Cli::Sessions.path_for(id)
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "#{Time.utc.to_unix_ms}.json"), M::Archive.write(M::Session.new))

      Elelem::Cli::Sessions.latest_deployment(id).should be_nil
    end
  end

  it "raises, naming the session id, when asked for one that doesn't exist" do
    with_sandbox do
      expect_raises(Elelem::Cli::SessionError, /nonexistent-session/) do
        Elelem::Cli::Sessions.latest("nonexistent-session")
      end
    end
  end

  describe ".validate_id" do
    it "accepts the shapes people actually use" do
      %w[brisk-comet nightly_run_42 v2.1-tax-questions A1].each do |id|
        Elelem::Cli::Sessions.validate_id(id).should eq(id)
      end
    end

    # The hole this closes. `show`/`continue` have always taken an id straight
    # from argv, and `path_for` used to join it unchecked.
    it "refuses anything that would leave the sessions folder" do
      ["../escape", "a/b", "a\\b", "..", "nested/../..", ".hidden"].each do |id|
        expect_raises(Elelem::Cli::SessionError, /not a usable session id/) do
          Elelem::Cli::Sessions.validate_id(id)
        end
      end
    end

    it "refuses an empty or over-long id" do
      expect_raises(Elelem::Cli::SessionError) { Elelem::Cli::Sessions.validate_id("") }
      expect_raises(Elelem::Cli::SessionError) { Elelem::Cli::Sessions.validate_id("x" * 65) }
    end

    it "is enforced through path_for, so no verb can bypass it" do
      with_sandbox do
        expect_raises(Elelem::Cli::SessionError, /not a usable session id/) do
          Elelem::Cli::Sessions.path_for("../escape")
        end
      end
    end
  end

  # The old failure mode was twenty misses and a raise. Filling every
  # combination makes the first twenty tries certain to miss.
  it "falls back to a numbered name rather than failing when the space is full" do
    with_sandbox do
      Elelem::Cli::Sessions::ADJECTIVES.each do |adjective|
        Elelem::Cli::Sessions::NOUNS.each do |noun|
          Dir.mkdir_p(Elelem::Cli::Sessions.path_for("#{adjective}-#{noun}"))
        end
      end

      id = Elelem::Cli::Sessions.generate_id
      id.should match(/\A[a-z]+-[a-z]+-\d+\z/)
      Elelem::Cli::Sessions.exists?(id).should be_false
    end
  end
end
