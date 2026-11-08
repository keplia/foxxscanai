#!/usr/bin/env bash
# fox-scan.sh — launcher recon DeepSeek untuk Ubuntu/Linux (mirror dari fox-scan.ps1)
# contoh:
#   ./tools/fox-scan.sh -m top
#   ./tools/fox-scan.sh -m hunt -s https://lazu.ai,https://orcarouter.ai
#   ./tools/fox-scan.sh -m probe -b https://api.orcarouter.ai/v1 -k sk-xxx
#   ./tools/fox-scan.sh -m ai
#   ./tools/fox-scan.sh -m all
set -euo pipefail

MODE="all"; SITES=""; BASE=""; KEY=""; MODEL="deepseek-v4.1-flash-1017"; SKIP_BAIDU=0

usage() {
  cat <<'EOF'
Usage: fox-scan.sh -m <mode> [options]
Modes:
  all      full sweep (discovery + probe + merge)
  relays   relay discovery (non-.ai)
  ai       .ai TLD discovery
  hunt     scan specific sites      -s "https://a,https://b"
  probe    test endpoint            -b <base_url> [-k key] [--model name]
  top      show last ranking
Options:
  -s, --sites     comma separated urls (hunt)
  -b, --base      base url (probe)
  -k, --key       api key (probe)
      --model     model name (default deepseek-v4.1-flash-1017)
      --skip-baidu
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)   MODE="${2:-}"; shift 2 ;;
    -s|--sites)  SITES="${2:-}"; shift 2 ;;
    -b|--base)   BASE="${2:-}"; shift 2 ;;
    -k|--key)    KEY="${2:-}"; shift 2 ;;
    --model)     MODEL="${2:-}"; shift 2 ;;
    --skip-baidu) SKIP_BAIDU=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "argumen tidak dikenal: $1" >&2; usage; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FOX_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FOX_ROOT="$ROOT"
export PYTHONIOENCODING=utf-8

mkdir -p "$ROOT/logs" "$ROOT/reports" "$ROOT/cache/tmp"

PY="python3"
command -v python3 >/dev/null 2>&1 || PY="python"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "python tidak ditemukan. install: sudo apt install -y python3 python3-pip" >&2
  exit 2
fi
"$PY" -c "import requests" 2>/dev/null || {
  echo "dependency 'requests' belum ada. jalankan: $PY -m pip install requests" >&2
  exit 2
}

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$ROOT/logs/fox-scan_${MODE}_${STAMP}.log"
echo "[fox] mode=$MODE root=$ROOT log=$LOG"

run() { "$PY" -u "$@" 2>&1 | tee -a "$LOG"; }

case "$MODE" in
  all)    run "$SCRIPT_DIR/scan_all.py" ;;
  relays) [[ "$SKIP_BAIDU" == "1" ]] && export SKIP_BAIDU=1; run "$SCRIPT_DIR/discover_relays.py" ;;
  ai)     run "$SCRIPT_DIR/discover_ai_tld.py" ;;
  hunt)
    [[ -z "$SITES" ]] && { echo "mode hunt butuh -s \"https://a,https://b\"" >&2; exit 1; }
    IFS=',' read -r -a ARR <<< "$SITES"
    CLEAN=()
    for u in "${ARR[@]}"; do
      u="$(echo "$u" | xargs)"
      [[ "$u" == http* ]] && CLEAN+=("$u")
    done
    [[ ${#CLEAN[@]} -eq 0 ]] && { echo "tidak ada URL valid" >&2; exit 1; }
    run "$SCRIPT_DIR/hunt_deepseek_flash.py" "${CLEAN[@]}" ;;
  probe)
    [[ -z "$BASE" ]] && { echo "mode probe butuh -b <base_url>" >&2; exit 1; }
    ARGS=("$BASE")
    [[ -n "$KEY" ]] && ARGS+=("$KEY")
    [[ -n "$MODEL" ]] && ARGS+=("$MODEL")
    run "$SCRIPT_DIR/probe_supplier.py" "${ARGS[@]}" ;;
  top)
    LATEST="$(ls -1t "$ROOT"/reports/global_deepseek_targets_*.json 2>/dev/null | head -n1 || true)"
    [[ -z "$LATEST" ]] && { echo "belum ada hasil. jalankan dulu: $0 -m all" >&2; exit 1; }
    "$PY" - "$LATEST" <<'PYEOF' | tee -a "$LOG"
import json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"== {sys.argv[1]} | total={j['total']} free={j['free']}")
for r in j["rows"][:30]:
    flag = "FREE" if r["free"] else "    "
    print(flag, str(r["price"]).ljust(7), r["url"], "|", ", ".join(r["models"][:3]))
PYEOF
    ;;
  *) echo "mode salah: $MODE" >&2; usage; exit 1 ;;
esac

echo "[fox] done -> $LOG"
