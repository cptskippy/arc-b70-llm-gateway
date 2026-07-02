#!/usr/bin/env bash
# =============================================================================
# End-to-end API benchmark: direct llama-server vs through llama-swap proxy.
#
# Measures TTFT, token throughput, and total time for streaming completions.
# Usage:
#   ./bench-api.sh                              # all models in llama-swap config
#   ./bench-api.sh qwen3-6-27b-q4-k-m           # specific model only
# =============================================================================

set -euo pipefail

LLAMA_SWAP_CONFIG="$HOME/.config/llama-swap/llama-swap.yaml"
MODELS_DIR="$HOME/.lmstudio/models"

SWAP_URL="http://127.0.0.1:8080/v1/chat/completions"

PROMPT="Write a detailed explanation of how neural networks learn through backpropagation, including the mathematical intuition behind gradient descent."
MAX_TOKENS=512
TEMPERATURE=0.2
SEED=42
WARMUP_REQUESTS=1
RESULTS_DIR="bench-results"

mkdir -p "$RESULTS_DIR"

# ── Python benchmark worker ───────────────────────────────────────────────────
BENCH_PYTHON='
import sys, json, time, urllib.request

url = sys.argv[1]
model = sys.argv[2]
prompt = sys.argv[3]
max_tokens = int(sys.argv[4])
temperature = float(sys.argv[5])
seed = int(sys.argv[6])
warmup = int(sys.argv[7])
runs = int(sys.argv[8])

payload = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": max_tokens,
    "stream": True,
    "temperature": temperature,
    "seed": seed
}).encode()

results = []

for run_idx in range(warmup + runs):
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    start = time.time()
    first_token_time = None
    tokens = 0
    content_len = 0

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            for raw_line in resp:
                line = raw_line.decode().strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                    delta = obj.get("choices", [{}])[0].get("delta", {})
                    tok = delta.get("content", "") or delta.get("reasoning_content", "")
                    if tok:
                        tokens += 1
                        content_len += len(tok)
                        now = time.time()
                        if first_token_time is None:
                            first_token_time = now
                except json.JSONDecodeError:
                    pass
    except Exception as e:
        print(f"ERROR on run {run_idx}: {e}", file=sys.stderr)
        continue

    total = time.time() - start
    ttft = (first_token_time - start) if first_token_time else None
    throughput = tokens / total if total > 0 else 0

    if run_idx >= warmup:
        results.append({
            "run": len(results) + 1,
            "ttft": ttft,
            "tokens": tokens,
            "content_chars": content_len,
            "throughput": throughput,
            "total": total
        })

# Output JSON summary
print(json.dumps(results))
'

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET_MODEL="${1:-}"

# ── Collect models from llama-swap.yaml ───────────────────────────────────────
declare -a MODELS=()

if [[ -n "$TARGET_MODEL" ]]; then
    MODELS=("$TARGET_MODEL")
else
    in_models=0
    while IFS= read -r line; do
        if [[ "$line" == "models:" ]]; then
            in_models=1
            continue
        fi
        if [[ $in_models -eq 1 ]]; then
            if [[ "$line" =~ ^[a-z] ]] || [[ "$line" == "groups:" ]]; then
                break
            fi
            if [[ "$line" =~ ^\ \ ([a-zA-Z0-9][-a-zA-Z0-9]*):$ ]]; then
                MODELS+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$LLAMA_SWAP_CONFIG"
fi

[[ ${#MODELS[@]} -gt 0 ]] || { echo "No models found."; exit 1; }

echo "Models to benchmark: ${MODELS[*]}"
echo ""

# ── Check services are running ────────────────────────────────────────────────
if ! systemctl --user is-active --quiet llama-swap.service 2>/dev/null; then
    echo "ERROR: llama-swap service is not running. Start it first:"
    echo "  systemctl --user start llama-swap.service"
    exit 1
fi

# ── Run benchmarks ────────────────────────────────────────────────────────────
for model_alias in "${MODELS[@]}"; do
    echo "==============================================================================="
    echo "  Benchmarking: $model_alias"
    echo "==============================================================================="

    # Find the direct port for this model from llama-swap.yaml
    direct_port=""
    current_model=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ \ ([a-zA-Z0-9][-a-zA-Z0-9]*):$ ]]; then
            current_model="${BASH_REMATCH[1]}"
        fi
        if [[ "$current_model" == "$model_alias" && "$line" =~ proxy:\ http://127\.0\.0\.1:([0-9]+) ]]; then
            direct_port="${BASH_REMATCH[1]}"
            break
        fi
    done < "$LLAMA_SWAP_CONFIG"

    [[ -n "$direct_port" ]] || { echo "  WARN: Could not find port for $model_alias — skipping."; continue; }

    direct_url="http://127.0.0.1:${direct_port}/v1/chat/completions"

    # Preload model via llama-swap so it's warm
    echo "  Preloading model (warm-up)..."
    llm-swap "$model_alias" 2>/dev/null || true
    sleep 3

    # ── Direct benchmark ─────────────────────────────────────────────────────
    echo ""
    echo "  [1/2] Direct llama-server (port $direct_port)..."
    direct_json=$(python3 -c "$BENCH_PYTHON" "$direct_url" "$model_alias" "$PROMPT" "$MAX_TOKENS" "$TEMPERATURE" "$SEED" "$WARMUP_REQUESTS" "3")

    # ── Proxy benchmark ──────────────────────────────────────────────────────
    echo "  [2/2] Via llama-swap proxy (port 8080)..."
    proxy_json=$(python3 -c "$BENCH_PYTHON" "$SWAP_URL" "$model_alias" "$PROMPT" "$MAX_TOKENS" "$TEMPERATURE" "$SEED" "$WARMUP_REQUESTS" "3")

    # ── Summarize ────────────────────────────────────────────────────────────
    outfile="$RESULTS_DIR/${model_alias}.api-bench.txt"

    {
        echo "Model: $model_alias"
        echo "Prompt length: ${#PROMPT} chars"
        echo "Max tokens: $MAX_TOKENS"
        echo "Temperature: $TEMPERATURE"
        echo "Seed: $SEED"
        echo ""
        echo "=== Direct (port $direct_port) ==="
        echo "$direct_json" | python3 -c "
import sys, json
results = json.loads(sys.stdin.read())
if not results:
    print('  No valid results')
else:
    ttfts = [r['ttft'] for r in results if r.get('ttft') is not None]
    tps = [r['throughput'] for r in results]
    totals = [r['total'] for r in results]
    toks = [r['tokens'] for r in results]
    print(f'  Runs: {len(results)}')
    if ttfts:
        print(f'  Avg TTFT:      {sum(ttfts)/len(ttfts):.3f}s (min {min(ttfts):.3f}, max {max(ttfts):.3f})')
    else:
        print('  Avg TTFT:      N/A (no tokens received)')
    if tps:
        print(f'  Avg Throughput: {sum(tps)/len(tps):.1f} tok/s (min {min(tps):.1f}, max {max(tps):.1f})')
    else:
        print('  Avg Throughput: N/A')
    if toks:
        print(f'  Avg Tokens:    {sum(toks)/len(toks):.0f}')
    else:
        print('  Avg Tokens:    0')
    if totals:
        print(f'  Avg Total:     {sum(totals)/len(totals):.3f}s')
    else:
        print('  Avg Total:     N/A')
    print()
    for r in results:
        ttft_str = f'{r[\"ttft\"]:.3f}s' if r.get('ttft') is not None else 'N/A'
        print(f'  Run {r[\"run\"]}: TTFT={ttft_str}, {r[\"tokens\"]} tok, {r[\"throughput\"]:.1f} tok/s, total={r[\"total\"]:.3f}s')
"
        echo ""
        echo "=== Via llama-swap (port 8080) ==="
        echo "$proxy_json" | python3 -c "
import sys, json
results = json.loads(sys.stdin.read())
if not results:
    print('  No valid results')
else:
    ttfts = [r['ttft'] for r in results if r.get('ttft') is not None]
    tps = [r['throughput'] for r in results]
    totals = [r['total'] for r in results]
    toks = [r['tokens'] for r in results]
    print(f'  Runs: {len(results)}')
    if ttfts:
        print(f'  Avg TTFT:      {sum(ttfts)/len(ttfts):.3f}s (min {min(ttfts):.3f}, max {max(ttfts):.3f})')
    else:
        print('  Avg TTFT:      N/A (no tokens received)')
    if tps:
        print(f'  Avg Throughput: {sum(tps)/len(tps):.1f} tok/s (min {min(tps):.1f}, max {max(tps):.1f})')
    else:
        print('  Avg Throughput: N/A')
    if toks:
        print(f'  Avg Tokens:    {sum(toks)/len(toks):.0f}')
    else:
        print('  Avg Tokens:    0')
    if totals:
        print(f'  Avg Total:     {sum(totals)/len(totals):.3f}s')
    else:
        print('  Avg Total:     N/A')
    print()
    for r in results:
        ttft_str = f'{r[\"ttft\"]:.3f}s' if r.get('ttft') is not None else 'N/A'
        print(f'  Run {r[\"run\"]}: TTFT={ttft_str}, {r[\"tokens\"]} tok, {r[\"throughput\"]:.1f} tok/s, total={r[\"total\"]:.3f}s')
"
        echo ""
        echo "=== Raw JSON ==="
        echo "Direct: $direct_json"
        echo "Proxy:  $proxy_json"
    } | tee "$outfile"

    echo ""
    echo "  Results saved to $outfile"
    echo ""
done

echo "==============================================================================="
echo "  All API benchmarks complete. Results in $RESULTS_DIR/"
echo "==============================================================================="
ls -la "$RESULTS_DIR/"*.api-bench.txt 2>/dev/null || true
