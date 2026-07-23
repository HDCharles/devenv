# Dev Environment Instructions

## GPU Commands

When running commands that require GPUs, always use `dolog run <N> <command>` where N is the number of GPUs needed. This logs output to `~/logs/` and dispatches the command to available GPUs via `chg`. Both `dolog` and `run` are defined in the bash profile — do not redefine or wrap them.

Example: `dolog run 2 python train.py --batch-size 64`

## Git Workflow

When rebasing a branch onto latest main, always update local main in the same operation:
```
git fetch origin
git branch -f main origin/main
git rebase main
```
This avoids checking out main (which would disrupt in-progress work) while keeping the local main ref current.

## Virtual Environments

There are 2 uv venvs in `$HOME`:
- **rhdev** — use for all quantization work
- **vllm** — use for all evaluation work

## Debugging

When debugging and there is uncertainty about why something is happening, run a small targeted experiment to gain certainty rather than reasoning from assumptions. Prefer adding a print/log statement or writing a minimal repro script over speculating about root causes.
