#!/bin/bash
# Extract and display all eval results from eval_results/ directory
#
# Usage:
#   ./print_eval_results.sh [eval_results_dir]
#
# Scans for lm_eval result JSONs, extracts metrics, and prints a summary table.

EVAL_DIR="${1:-$(dirname "$0")/eval_results}"

if [ ! -d "$EVAL_DIR" ]; then
    echo "No eval results directory found: $EVAL_DIR"
    exit 1
fi

python3 - "$EVAL_DIR" <<'PYEOF'
import json, os, sys
from pathlib import Path

eval_dir = Path(sys.argv[1])

METRIC_MAP = {
    "wikitext": ("word_perplexity,none", lambda v: f"{v:.2f}"),
    "mmlu": ("acc,none", lambda v: f"{v*100:.2f}%"),
    "gsm8k_platinum": ("exact_match,strict-match", lambda v: f"{v*100:.2f}%"),
}

rows = []

for model_dir in sorted(eval_dir.iterdir()):
    if not model_dir.is_dir():
        continue

    # Parse directory name: {model}-{scheme}-{technique}-{branch}
    parts = model_dir.name.split("-")
    # Find scheme (known schemes are uppercase like NVFP4A16, FP8)
    scheme_idx = None
    for i, p in enumerate(parts):
        if p in ("NVFP4A16", "FP8", "W4A16", "W8A8", "W4A4"):
            scheme_idx = i
            break
    if scheme_idx is None:
        if parts[-1] == "baseline":
            model = "-".join(parts[:-1])
            scheme = "baseline"
            technique = "baseline"
            branch = "baseline"
        else:
            continue
    else:
        model = "-".join(parts[:scheme_idx])
        scheme = parts[scheme_idx]
        rest = parts[scheme_idx + 1:]
        known_techniques = {"awq_rtn", "awq_smooth", "awq_no_up_down", "rtn", "rtn_mse", "gptq", "imatrix"}
        technique = None
        branch = None
        for t_len in range(1, len(rest)):
            candidate = "_".join(rest[:t_len])
            if candidate in known_techniques:
                technique = candidate
                branch = "-".join(rest[t_len:])
                break
        if technique is None:
            if len(rest) >= 2:
                technique = rest[-2]
                branch = rest[-1]
            else:
                continue

    for task_dir in sorted(model_dir.iterdir()):
        if not task_dir.is_dir():
            continue
        task = task_dir.name

        # Find latest results JSON (may be nested in a subdirectory)
        jsons = sorted(task_dir.rglob("results_*.json"))
        if not jsons:
            continue
        latest = jsons[-1]

        try:
            with open(latest) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        results = data.get("results", {})
        task_results = None
        for key in results:
            if task in key:
                task_results = results[key]
                break
        if task_results is None:
            continue

        # Extract metric
        metric_key, fmt = METRIC_MAP.get(task, (None, None))
        if metric_key and metric_key in task_results:
            val = task_results[metric_key]
            display = fmt(val)
        else:
            # Grab first numeric non-stderr metric
            display = None
            for k, v in task_results.items():
                if "stderr" not in k and k != "alias" and k != "name" and isinstance(v, (int, float)):
                    display = f"{v:.4f}"
                    break
            if display is None:
                display = "N/A"

        rows.append({
            "model": model,
            "scheme": scheme,
            "technique": technique,
            "branch": branch,
            "task": task,
            "metric": display,
        })

if not rows:
    print("No results found.")
    sys.exit()

# Collect unique tasks and branches
tasks = list(dict.fromkeys(r["task"] for r in rows))
branches = list(dict.fromkeys(r["branch"] for r in rows))

# Build lookup: (model, scheme, technique, branch) -> {task: metric}
lookup = {}
for r in rows:
    key = (r["model"], r["scheme"], r["technique"], r["branch"])
    lookup.setdefault(key, {})[r["task"]] = r["metric"]

# Determine column widths
model_w = max((len(k[0]) for k in lookup), default=10)
scheme_w = max((len(k[1]) for k in lookup), default=6)
tech_w = max((len(k[2]) for k in lookup), default=8)
branch_w = max((len(k[3]) for k in lookup), default=6)
task_w = max(max((len(t) for t in tasks), default=8), 10)

# Print header
print("")
print("=" * 120)
print("  EVAL RESULTS")
print("=" * 120)
print("")

header = (f"{'model':<{model_w}}  {'scheme':<{scheme_w}}  {'technique':<{tech_w}}  "
          f"{'branch':<{branch_w}}")
for t in tasks:
    header += f"  {t:>{task_w}}"
print(header)
print("-" * len(header))

for key in sorted(lookup):
    model, scheme, technique, branch = key
    line = f"{model:<{model_w}}  {scheme:<{scheme_w}}  {technique:<{tech_w}}  {branch:<{branch_w}}"
    for t in tasks:
        val = lookup[key].get(t, "—")
        line += f"  {val:>{task_w}}"
    print(line)

print("")

# Print comparison if multiple branches exist
if len(branches) > 1 and "main" in branches:
    pr_branches = [b for b in branches if b != "main"]

    print("=" * 120)
    print(f"  BRANCH COMPARISON (main vs {', '.join(pr_branches)})")
    print("=" * 120)
    print("")

    def parse_metric(s):
        s = s.strip()
        if s.endswith("%"):
            try: return float(s[:-1])
            except ValueError: return None
        try: return float(s)
        except ValueError: return None

    comp_header = (f"{'model':<{model_w}}  {'scheme':<{scheme_w}}  {'technique':<{tech_w}}  "
                   f"{'task':<{task_w}}  {'main':>12}")
    for pb in pr_branches:
        comp_header += f"  {pb:>12}  {'change':>10}"
    print(comp_header)
    print("-" * len(comp_header))

    for model, scheme, technique, _ in sorted(set(
        (k[0], k[1], k[2], "") for k in lookup
    )):
        main_key = (model, scheme, technique, "main")
        main_metrics = lookup.get(main_key, {})
        if not main_metrics:
            continue

        for task in tasks:
            m = main_metrics.get(task)
            if m is None:
                continue

            line = (f"{model:<{model_w}}  {scheme:<{scheme_w}}  {technique:<{tech_w}}  "
                    f"{task:<{task_w}}  {m:>12}")

            for pb in pr_branches:
                pr_key = (model, scheme, technique, pb)
                pr_metrics = lookup.get(pr_key, {})
                p = pr_metrics.get(task, "—")
                line += f"  {p:>12}"

                m_val = parse_metric(m)
                p_val = parse_metric(p)
                if m_val is not None and p_val is not None and m_val != 0:
                    if "wikitext" in task:
                        pct = (m_val - p_val) / m_val * 100
                    else:
                        pct = (p_val - m_val) / m_val * 100
                    sign = "+" if pct >= 0 else ""
                    line += f"  {sign}{pct:.2f}%".rjust(10)
                else:
                    line += f"  {'—':>10}"

            print(line)

    print("")

PYEOF
