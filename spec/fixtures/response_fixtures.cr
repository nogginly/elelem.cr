require "../../src/elelem"

# Response bodies, one set per protocol.
#
# These are the shapes providers actually send, transcribed from published
# examples rather than composed to suit the reader. That distinction is the
# whole value of the file: a body I invented would test my assumptions about
# the wire, which is precisely the thing under test. Where a field looked
# redundant it was kept, because a reader that only tolerates the fields it
# expects is a reader that breaks on the first real response.
#
# Payloads are trimmed — token counts made small, base64 made short, encrypted
# blobs shortened — but no field is removed and no shape is flattened.
module Elelem::ResponseFixtures
  extend self

  # ---- Chat Completions -------------------------------------------------

  CHAT_TEXT = <<-JSON
    {
      "id": "chatcmpl-B9MHDbslfkBeAs8l4bebGdFOJ6PeG",
      "object": "chat.completion",
      "created": 1741570283,
      "model": "llama3.2",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Mount Everest, at 8,849 metres.",
            "refusal": null,
            "annotations": []
          },
          "logprobs": null,
          "finish_reason": "stop"
        }
      ],
      "usage": {
        "prompt_tokens": 19,
        "completion_tokens": 11,
        "total_tokens": 30
      },
      "service_tier": "default"
    }
    JSON

  CHAT_TOOL_CALL = <<-JSON
    {
      "id": "chatcmpl-abc123",
      "object": "chat.completion",
      "created": 1741570283,
      "model": "llama3.2",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [
              {
                "id": "call_12345xyz",
                "type": "function",
                "function": {
                  "name": "get_weather",
                  "arguments": "{\\"location\\":\\"Paris, France\\"}"
                }
              },
              {
                "id": "call_67890abc",
                "type": "function",
                "function": {
                  "name": "get_weather",
                  "arguments": "{\\"location\\":\\"Bogota, Colombia\\"}"
                }
              }
            ],
            "refusal": null
          },
          "finish_reason": "tool_calls"
        }
      ],
      "usage": {"prompt_tokens": 82, "completion_tokens": 40, "total_tokens": 122}
    }
    JSON

  # `reasoning_content` is not in OpenAI's specification. Ollama, vLLM and
  # others emit it for reasoning models over this protocol, which is exactly
  # the set of servers this protocol reaches — and the Ollama run is the next
  # milestone, so this shape is not hypothetical.
  CHAT_REASONING = <<-JSON
    {
      "id": "chatcmpl-reason1",
      "object": "chat.completion",
      "created": 1741570283,
      "model": "deepseek-r1",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "reasoning_content": "The user wants the highest peak. That is Everest.",
            "content": "Mount Everest."
          },
          "finish_reason": "stop"
        }
      ],
      "usage": {"prompt_tokens": 12, "completion_tokens": 30, "total_tokens": 42}
    }
    JSON

  CHAT_REFUSAL = <<-JSON
    {
      "id": "chatcmpl-refusal1",
      "object": "chat.completion",
      "created": 1741570283,
      "model": "llama3.2",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "refusal": "I'm sorry, I can't help with that."
          },
          "finish_reason": "stop"
        }
      ],
      "usage": {"prompt_tokens": 20, "completion_tokens": 9, "total_tokens": 29}
    }
    JSON

  # ---- Responses --------------------------------------------------------

  RESPONSES_TEXT = <<-JSON
    {
      "id": "resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b",
      "object": "response",
      "created_at": 1741476777,
      "status": "completed",
      "model": "gpt-4.1-2025-04-14",
      "output": [
        {
          "type": "message",
          "id": "msg_67ccd2bf17f0819081ff3bb2cf6508e60bb6a6b452d3795b",
          "status": "completed",
          "role": "assistant",
          "content": [
            {
              "type": "output_text",
              "text": "Mount Everest, at 8,849 metres.",
              "annotations": []
            }
          ]
        }
      ],
      "usage": {
        "input_tokens": 36,
        "output_tokens": 11,
        "total_tokens": 47
      }
    }
    JSON

  # Reasoning arrives as its own item, ahead of the call it justifies. The
  # encrypted payload is the reason this protocol can replay a reasoning trace
  # at all, and it must survive byte-identical.
  RESPONSES_REASONING_AND_CALL = <<-JSON
    {
      "id": "resp_reason1",
      "object": "response",
      "status": "completed",
      "model": "o4-mini",
      "output": [
        {
          "type": "reasoning",
          "id": "rs_67ccd7eca01881908ff0b5146584e408",
          "summary": [
            {"type": "summary_text", "text": "Need the weather tool for Paris."}
          ],
          "encrypted_content": "gAAAAABn0zBxAbCdEf1234=="
        },
        {
          "type": "function_call",
          "id": "fc_12345xyz",
          "call_id": "call_12345xyz",
          "name": "get_weather",
          "arguments": "{\\"location\\":\\"Paris, France\\"}",
          "status": "completed"
        }
      ],
      "usage": {"input_tokens": 40, "output_tokens": 25, "total_tokens": 65}
    }
    JSON

  # A message carrying both text and a refusal. The request vocabulary models a
  # refusal as an item in its own right, so this one wire item becomes two.
  RESPONSES_REFUSAL = <<-JSON
    {
      "id": "resp_refusal1",
      "object": "response",
      "status": "completed",
      "model": "gpt-4.1",
      "output": [
        {
          "type": "message",
          "id": "msg_refusal1",
          "role": "assistant",
          "content": [
            {"type": "output_text", "text": "Here is what I can say.", "annotations": []},
            {"type": "refusal", "refusal": "I won't provide the rest."}
          ]
        }
      ],
      "usage": {"input_tokens": 15, "output_tokens": 12, "total_tokens": 27}
    }
    JSON

  # ---- Anthropic --------------------------------------------------------

  ANTHROPIC_TEXT = <<-JSON
    {
      "id": "msg_013Zva2CMHLNnXjNJJKqJ2EF",
      "type": "message",
      "role": "assistant",
      "model": "claude-sonnet-4-6",
      "content": [
        {"type": "text", "text": "Mount Everest, at 8,849 metres."}
      ],
      "stop_reason": "end_turn",
      "stop_sequence": null,
      "usage": {"input_tokens": 2095, "output_tokens": 503}
    }
    JSON

  # `input` is a structured object here, not a JSON string as on the OpenAI
  # protocols. The reader re-serializes it; parsing happens once, at export.
  ANTHROPIC_TOOL_USE = <<-JSON
    {
      "id": "msg_01Aq9w938a90dw8q",
      "type": "message",
      "role": "assistant",
      "model": "claude-sonnet-4-6",
      "content": [
        {"type": "text", "text": "Let me check the weather."},
        {
          "type": "tool_use",
          "id": "toolu_01A09q90qw90lq917835lq9",
          "name": "get_weather",
          "input": {"location": "San Francisco, CA", "unit": "celsius"}
        }
      ],
      "stop_reason": "tool_use",
      "stop_sequence": null,
      "usage": {"input_tokens": 472, "output_tokens": 91}
    }
    JSON

  # Thinking with its signature. The signature must be replayed unmodified or
  # the trace is rejected on the next turn.
  ANTHROPIC_THINKING = <<-JSON
    {
      "id": "msg_thinking1",
      "type": "message",
      "role": "assistant",
      "model": "claude-sonnet-4-6",
      "content": [
        {
          "type": "thinking",
          "thinking": "The tallest mountain above sea level is Everest.",
          "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1KwiMOYds"
        },
        {"type": "text", "text": "Mount Everest."}
      ],
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 30, "output_tokens": 60}
    }
    JSON

  # The correctness case. `server_tool_use` arrives already executed, with its
  # result alongside; reading either as an ordinary `tool_use` would hand the
  # caller a call to dispatch, and dispatching it means running a tool it does
  # not have.
  ANTHROPIC_SERVER_TOOL = <<-JSON
    {
      "id": "msg_server1",
      "type": "message",
      "role": "assistant",
      "model": "claude-sonnet-4-6",
      "content": [
        {"type": "text", "text": "I'll look that up."},
        {
          "type": "server_tool_use",
          "id": "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE",
          "name": "web_search",
          "input": {"query": "tallest mountain"}
        },
        {
          "type": "web_search_tool_result",
          "tool_use_id": "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE",
          "content": [
            {
              "type": "web_search_result",
              "url": "https://example.org/everest",
              "title": "Everest",
              "encrypted_content": "EqgfCioIARgBIiQ3YTAwMjY1Mi1mZjM5LTQ1NGUt"
            }
          ]
        },
        {"type": "text", "text": "Mount Everest, at 8,849 metres."}
      ],
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 100, "output_tokens": 200}
    }
    JSON

  # ---- Gemini -----------------------------------------------------------

  GEMINI_TEXT = <<-JSON
    {
      "candidates": [
        {
          "content": {
            "parts": [{"text": "Mount Everest, at 8,849 metres."}],
            "role": "model"
          },
          "finishReason": "STOP",
          "index": 0
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 8,
        "candidatesTokenCount": 11,
        "totalTokenCount": 19
      },
      "modelVersion": "gemini-2.0-flash"
    }
    JSON

  # No identifier on the wire anywhere — pairing is reconstructed from name and
  # ordering, which is why two calls to the same function is the case worth
  # recording.
  GEMINI_FUNCTION_CALL = <<-JSON
    {
      "candidates": [
        {
          "content": {
            "parts": [
              {"functionCall": {"name": "get_weather", "args": {"location": "Paris"}}},
              {"functionCall": {"name": "get_weather", "args": {"location": "Bogota"}}}
            ],
            "role": "model"
          },
          "finishReason": "STOP",
          "index": 0
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 40,
        "candidatesTokenCount": 20,
        "totalTokenCount": 60
      },
      "modelVersion": "gemini-2.0-flash"
    }
    JSON

  # A thought is a `text` part wearing a flag, not a part type of its own.
  # Read in the wrong order it becomes ordinary assistant prose — a fidelity
  # bug with no symptom, which is why it has a fixture.
  GEMINI_THOUGHT = <<-JSON
    {
      "candidates": [
        {
          "content": {
            "parts": [
              {
                "text": "The user wants the highest peak.",
                "thought": true,
                "thoughtSignature": "CtEHAdHtim9Cn1t7A0hSFtT8yTWM0"
              },
              {"text": "Mount Everest."}
            ],
            "role": "model"
          },
          "finishReason": "STOP",
          "index": 0
        }
      ],
      "usageMetadata": {
        "promptTokenCount": 10,
        "candidatesTokenCount": 15,
        "thoughtsTokenCount": 8,
        "totalTokenCount": 33
      },
      "modelVersion": "gemini-2.5-flash"
    }
    JSON
end
