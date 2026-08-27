require "../spec_helper"

# Live specs against a real Azure OpenAI resource — the deployment that
# amends `Adapter` rather than exercising it. Chat Completions and Responses
# are otherwise proven live nowhere but Ollama's compatible port
# (`docs/servers/OLLAMA.md`), which validates nothing about auth or path,
# since it ignores both. This file's job is narrow: prove
# `AzureChatCompletionsAdapter` and `AzureResponsesAdapter` build a request
# a real Azure resource accepts. It is not re-proving reasoning, tools, or
# compensation — those are protocol-level claims already covered elsewhere.
#
# **Recording.** Needs `AZURE_OPENAI_API_KEY` in the environment and
# `RECORD=1` to cut a transcript. Once committed it replays offline like
# every other live spec — CI sets no key at all, same as the Anthropic and
# Gemini suites, because the credential plays no part in matching a
# recording: Wiretap keys on method, URL and body, and headers are filtered
# before anything is written to disk.
#
# Endpoint, deployment and api-version are **not** environment-sourced,
# unlike the credential. All three are baked into the URL Wiretap matches
# against, so — like the pinned `MODEL` in `anthropic_spec.cr` and
# `gemini_spec.cr` — they have to be committed constants, not `ops` env
# values a CI run might not set. An empty-string fallback here would build a
# URL nothing was ever recorded against and fail every replay.
#
# **Model.** `gpt5.4mini` — cheapest available, and a reasoning model. Found
# live, not assumed: it rejects `max_tokens` outright and wants
# `max_completion_tokens`, OpenAI's replacement field for the reasoning-model
# line. `ChatCompletionsAdapter` still defaults to the old spelling — Ollama's
# compatible endpoint has no support for the new one, so switching the
# default would silently stop capping output there. See
# `Protocol::ChatCompletions::Wire::MaxTokensField`. This deployment states
# its need explicitly, the same way `reasoning_unit` already lets a caller
# override what a deployment name alone cannot say.
private ENDPOINT    = "https://oxaro-alpha.openai.azure.com"
private DEPLOYMENT  = "gpt5.4mini"
private API_VERSION = "2025-04-01-preview"

private def azure : Elelem::Server
  Elelem::Server.new("azure", ENDPOINT, ENV["AZURE_OPENAI_API_KEY"]?)
end

private def client(protocol : Elelem::ProtocolKind) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for_azure(azure, protocol, API_VERSION,
    max_tokens_field: protocol.chat_completions? ? Elelem::Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens : nil))
end

private CAP = Elelem::Options.new(max_output_tokens: 64)

describe "Azure OpenAI" do
  describe "Chat Completions" do
    it "accepts a request built by AzureChatCompletionsAdapter" do
      Wiretap.intercept("azure_chat_completions_text") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("Say hello in one short sentence.")

        reply, report = client(Elelem::ProtocolKind::ChatCompletions)
          .send(session, DEPLOYMENT, options: CAP)

        reply.content.should_not be_empty
        # Not `Exact`: a system prompt is unconditionally Restructured on this
        # protocol too, by design — MPSH holds it as a session field, and
        # turning it into a message is a restructuring regardless of the
        # protocol calling that placement native. Pinned by
        # `spec/conformance/layer_spec.cr` ("Any session with a system prompt
        # is Restructured here, so Exact was never on offer"). What this call
        # actually proves is narrower and is what's asserted: nothing refused.
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "Responses" do
    it "accepts a request built by AzureResponsesAdapter" do
      Wiretap.intercept("azure_responses_text") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("Say hello in one short sentence.")

        reply, report = client(Elelem::ProtocolKind::Responses)
          .send(session, DEPLOYMENT, options: CAP)

        reply.content.should_not be_empty
        # Not `Exact`: a system prompt always reports Restructured here — it
        # moves to the top-level `instructions` field on every call, not just
        # this one. See RESPONSES.md, "Declared capabilities". What this call
        # actually proves is narrower and is what's asserted: nothing refused.
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end
end
