require "../spec_helper"
require "../../src/elelem_cli/config"

# Pure by construction: `Config.from_yaml` is a string in, a `Config` or a
# raised `ConfigError` out. No `Dir.cd`, no temp files — see
# `sessions_spec.cr` for the specs that actually need a sandbox.
describe Elelem::Cli::Config do
  describe ".from_yaml" do
    it "parses a plain deployment" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          anthropic:
            protocol: anthropic
            server: https://api.anthropic.com
            credential_env: ANTHROPIC_API_KEY
            model: claude-haiku-4-5
        YAML

      d = config.deployment("anthropic")
      d.protocol.should eq(Elelem::ProtocolKind::Anthropic)
      d.server_url.should eq("https://api.anthropic.com")
      d.model.should eq("claude-haiku-4-5")
      d.credential_env.should eq("ANTHROPIC_API_KEY")
      d.azure?.should be_false
    end

    it "parses an azure deployment, including max_tokens_field" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          azure-mini:
            protocol: chat_completions
            azure: true
            server: https://oxaro-alpha.openai.azure.com
            api_version: "2025-04-01-preview"
            credential_env: AZURE_OPENAI_API_KEY
            model: gpt5.4mini
            max_tokens_field: max_completion_tokens
        YAML

      d = config.deployment("azure-mini")
      d.azure?.should be_true
      d.api_version.should eq("2025-04-01-preview")
      d.max_tokens_field.should eq(Elelem::Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens)
    end

    it "defaults azure to false and max_tokens_field to nil when absent" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          home-ollama:
            protocol: chat_completions
            server: http://localhost:11434
            model: llama3.2
        YAML

      d = config.deployment("home-ollama")
      d.azure?.should be_false
      d.max_tokens_field.should be_nil
    end

    it "raises when 'deployments' is missing entirely" do
      expect_raises(Elelem::Cli::ConfigError, /deployments/) do
        Elelem::Cli::Config.from_yaml("default_deployment: anthropic")
      end
    end

    it "raises naming the deployment when 'protocol' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"anthropic".*protocol/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            anthropic:
              server: https://api.anthropic.com
              model: claude-haiku-4-5
          YAML
      end
    end

    it "raises naming the deployment when 'server' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"anthropic".*server/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            anthropic:
              protocol: anthropic
              model: claude-haiku-4-5
          YAML
      end
    end

    it "raises naming the deployment when 'model' is missing" do
      expect_raises(Elelem::Cli::ConfigError, /"anthropic".*model/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            anthropic:
              protocol: anthropic
              server: https://api.anthropic.com
          YAML
      end
    end

    it "raises on an unrecognised protocol" do
      expect_raises(Elelem::Cli::ConfigError, /unrecognised protocol "azure-native"/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            weird:
              protocol: azure-native
              server: https://example.com
              model: whatever
          YAML
      end
    end

    it "raises on an unrecognised max_tokens_field" do
      expect_raises(Elelem::Cli::ConfigError, /unrecognised max_tokens_field "output_limit"/) do
        Elelem::Cli::Config.from_yaml(<<-YAML)
          deployments:
            weird:
              protocol: chat_completions
              server: https://example.com
              model: whatever
              max_tokens_field: output_limit
          YAML
      end
    end
  end

  describe "#deployment" do
    it "raises listing the known deployment names when asked for an unknown one" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          anthropic:
            protocol: anthropic
            server: https://api.anthropic.com
            model: claude-haiku-4-5
        YAML

      expect_raises(Elelem::Cli::ConfigError, /"azure-mini".*anthropic/) { config.deployment("azure-mini") }
    end
  end

  describe "#provider_for" do
    it "builds a plain Provider, named for the deployment" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          anthropic:
            protocol: anthropic
            server: https://api.anthropic.com
            model: claude-haiku-4-5
        YAML

      provider = config.provider_for("anthropic")
      provider.server.name.should eq("anthropic")
      provider.adapter.class.should eq(Elelem::AnthropicAdapter)
    end

    it "builds an Azure Provider via Provider.for_azure" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          azure-mini:
            protocol: chat_completions
            azure: true
            server: https://oxaro-alpha.openai.azure.com
            api_version: "2025-04-01-preview"
            model: gpt5.4mini
        YAML

      provider = config.provider_for("azure-mini")
      provider.server.name.should eq("azure-mini")
      provider.adapter.class.should eq(Elelem::AzureChatCompletionsAdapter)
    end

    it "raises when azure is true but api_version is missing" do
      config = Elelem::Cli::Config.from_yaml(<<-YAML)
        deployments:
          azure-mini:
            protocol: chat_completions
            azure: true
            server: https://oxaro-alpha.openai.azure.com
            model: gpt5.4mini
        YAML

      expect_raises(Elelem::Cli::ConfigError, /api_version/) { config.provider_for("azure-mini") }
    end
  end

  describe Elelem::Cli::Deployment do
    it "resolves credential from the named environment variable" do
      ENV["ELELEM_SPEC_TEST_KEY"] = "shh"
      begin
        d = Elelem::Cli::Deployment.new(Elelem::ProtocolKind::Anthropic, "https://example.com", "model",
          credential_env: "ELELEM_SPEC_TEST_KEY")
        d.credential.should eq("shh")
      ensure
        ENV.delete("ELELEM_SPEC_TEST_KEY")
      end
    end

    it "is nil when credential_env is unset" do
      d = Elelem::Cli::Deployment.new(Elelem::ProtocolKind::ChatCompletions, "http://localhost:11434", "llama3.2")
      d.credential.should be_nil
    end
  end
end
