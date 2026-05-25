# Claude Code Reasoning Transcript Exporter

Export a Claude Code session JSONL transcript into a readable Markdown file, including internal reasoning blocks when present.

This script is intentionally narrow in scope. It exports from one explicitly configured Claude Code project directory and will not search for projects based on the current working directory. It also does not export tool calls.

## Purpose

Claude Code stores local session history as JSONL files inside project-specific directories. This script converts a selected session file into Markdown with sections for:

- User messages
- Claude responses
- Claude internal reasoning / thinking blocks

The reasoning export is deliberate. This tool is intended for private review, debugging, research, and transcript analysis.

## Safety Model

The script is designed to avoid accidental reads outside the configured project directory.

It only accepts `.jsonl` files that are direct children of the configured `PROJECT_DIR`.

It rejects:

- Files outside `PROJECT_DIR`
- Files inside subdirectories of `PROJECT_DIR`
- Non-`.jsonl` files
- Ambiguous partial session matches

Even if you pass a full file path as an argument, the file is accepted only if its resolved physical parent directory exactly matches the configured `PROJECT_DIR`.

## Requirements

The script requires:

- Bash
- `jq`
- Standard Unix utilities: `find`, `sort`, `sed`, `basename`, `dirname`, `xargs`, `ls`, `date`

The script assumes `jq` is installed.

## Configuration

Before running the script, edit the `PROJECT_DIR` constant near the top:

```bash
PROJECT_DIR="$HOME/.claude/projects/REPLACE_WITH_SPECIFIC_PROJECT_DIR"
