"""
smoke_test.py - Calls Ollama's OpenAI-compatible API (http://localhost:11434/v1).

Measures the two numbers that matter in this lab:
  - TTFT (time to first token): how long it takes to START answering. Dominated by
    prefill, the processing of the prompt, which scales with compute.
  - generation tok/s: output speed, which scales with VRAM memory bandwidth.

Usage:
    python -m venv .venv
    .\\.venv\\Scripts\\Activate.ps1
    pip install -r clients\\requirements.txt
    python clients\\smoke_test.py                # qwen3:8b by default
    python clients\\smoke_test.py gpt-oss:20b    # pick another model
"""
import sys
import time

from openai import OpenAI

# UTF-8 output on the Windows console
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3:8b"
PROMPT = "Explain in 3 sentences what quantization of an LLM is."

# api_key is a placeholder: Ollama does not check it, but the SDK requires one.
client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

print(f"== Model: {MODEL} ==")
print(f"Prompt: {PROMPT}\n")

start = time.perf_counter()
first_token_at = None
n_chunks = 0

stream = client.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", "content": PROMPT}],
    stream=True,
)
for chunk in stream:
    delta = chunk.choices[0].delta.content
    if delta:
        if first_token_at is None:
            first_token_at = time.perf_counter()
        n_chunks += 1
        print(delta, end="", flush=True)

end = time.perf_counter()
ttft = (first_token_at - start) if first_token_at else 0.0
gen_time = (end - first_token_at) if first_token_at else 0.0
tok_s = (n_chunks / gen_time) if gen_time > 0 else 0.0

print("\n\n--- metrics (baseline) ---")
print(f"TTFT (time to first token): {ttft:.2f} s")
print(f"Tokens (approx., 1 per chunk): {n_chunks}")
print(f"Generation speed          : {tok_s:.1f} tok/s")
