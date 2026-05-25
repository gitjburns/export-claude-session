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
- Ambiguous filename matches
- Ambiguous content/name/title matches

Even if you pass a full file path as an argument, the file is accepted only if its resolved physical parent directory exactly matches the configured `PROJECT_DIR`.

## Requirements

The script requires:

- Bash
- `jq`
- Standard Unix utilities: `find`, `sort`, `sed`, `basename`, `dirname`, `xargs`, `ls`, `date`, `grep`

The script assumes `jq` is installed.

## Configuration

Before running the script, edit the `PROJECT_DIR` constant near the top:

```bash
PROJECT_DIR="$HOME/.claude/projects/REPLACE_WITH_SPECIFIC_PROJECT_DIR"
```

Set it to the specific Claude Code project directory containing the session `.jsonl` files you want to export.

Example:

```bash
PROJECT_DIR="$HOME/.claude/projects/-Users-jake-src-my-project"
```

The output directory defaults to:

```bash
EXPORT_DIR="$HOME/claude_exports"
```

You can change that constant if desired.

## Usage

Make the script executable:

```bash
chmod +x export_claude_transcript.sh
```

Run it without arguments to export the newest direct `.jsonl` session file in `PROJECT_DIR`:

```bash
./export_claude_transcript.sh
```

Run it with a specific session filename:

```bash
./export_claude_transcript.sh 12345678-abcd-1234-abcd-1234567890ab.jsonl
```

Run it with a session id without the `.jsonl` extension:

```bash
./export_claude_transcript.sh 12345678-abcd-1234-abcd-1234567890ab
```

Run it with a partial session id or partial filename:

```bash
./export_claude_transcript.sh 12345678
```

Run it with a human-readable session name/title:

```bash
./export_claude_transcript.sh "Refactor auth flow"
```

Session lookup is literal and case-insensitive for partial filename and content/name/title search. Characters such as spaces, brackets, punctuation, `*`, and `?` are treated as ordinary text.

Partial matches are allowed only if they resolve to exactly one matching `.jsonl` file. If multiple files match, the script exits and lists the matching sessions.

## Session Resolution Order

When a session argument is provided, the script resolves it in this order:

1. Full or relative path, accepted only if it is a direct `.jsonl` child of `PROJECT_DIR`
2. Exact filename inside `PROJECT_DIR`
3. Exact session id without `.jsonl`
4. Literal partial filename match
5. Literal content/name/title match

The content/name/title fallback searches only direct `.jsonl` children of `PROJECT_DIR`.

It first checks likely structured fields such as:

```text
title
name
summary
sessionName
session_name
conversationTitle
conversation_title
message.title
message.name
message.summary
message.sessionName
message.session_name
message.conversationTitle
message.conversation_title
```

Then it falls back to a raw fixed-string search over each direct `.jsonl` file.

## Output

Exports are written to:

```bash
$HOME/claude_exports
```

The generated filename uses this format:

```text
export_YYYYMMDD_HHMMSS_NAME.md
```

If you provide a session argument, that argument is used in the final filename after sanitization.

Example:

```bash
./export_claude_transcript.sh "Refactor auth flow"
```

May produce:

```text
export_20260524_143012_Refactor_auth_flow.md
```

If you run the script without a session argument, the actual session id is used instead:

```text
export_20260524_143012_12345678-abcd-1234-abcd-1234567890ab.md
```

The output filename is sanitized so spaces, slashes, punctuation, and unusual characters do not create unsafe or invalid filenames.

At completion, the script prints:

```text
Export complete. Your transcript with reasoning traces is saved at:
/path/to/exported/file.md
```

The final output uses plain `printf '%s\n'` formatting to avoid Unicode or format-string issues in terminal output.

## Markdown Front Matter

The Markdown file starts with front matter:

```yaml
---
title: Claude Code Custom Transcript
date: ...
session_id: ...
source_file: ...
---
```

Then it emits the conversation as Markdown sections.

## Export Format

User messages are written as:

```markdown
### User

Message text...
```

Claude messages are written as:

```markdown
### Claude

#### Reasoning

    Reasoning text is written as an indented code block.
    This avoids breakage if the reasoning contains triple backticks.

Visible response text...
```

Reasoning blocks are written as indented Markdown code blocks instead of fenced code blocks. This makes the output structurally robust even when the reasoning itself contains Markdown fences such as:

````markdown
```text
example
```
````

## Handling Missing Reasoning Blocks

The script does not silently skip missing reasoning.

If an assistant message lacks a reasoning block, the export includes:

```markdown
#### Reasoning

    [No reasoning block found in this assistant message.]
```

This makes missing reasoning explicit in the generated transcript.

## What Is Not Exported

The script intentionally omits:

- Tool calls
- Tool inputs
- Tool outputs
- Non-text content blocks
- Files outside the configured project directory
- Files inside subdirectories of the configured project directory

Only user text, assistant text, and assistant reasoning/thinking blocks are exported.

## Supported JSON Shapes

The script supports both top-level and nested message structures.

It checks for roles in either:

```jq
.role
```

or:

```jq
.message.role
```

It checks for content in either:

```jq
.content
```

or:

```jq
.message.content
```

Content may be either:

```json
"plain string content"
```

or an array of typed content blocks:

```json
[
  {
    "type": "text",
    "text": "Visible message text"
  },
  {
    "type": "thinking",
    "text": "Reasoning block"
  }
]
```

Reasoning is extracted from content blocks with type:

```text
thinking
reasoning
```

The script checks these fields inside reasoning blocks:

```jq
.text
.thinking
.content
```

## File Confinement Behavior

The script resolves `PROJECT_DIR` with:

```bash
pwd -P
```

It validates every selected session file by resolving the candidate file’s parent directory physically and comparing it to the resolved `PROJECT_DIR`.

A session file is accepted only if:

1. Its resolved parent directory exactly equals the resolved `PROJECT_DIR`
2. It is a regular file
3. Its basename ends in `.jsonl`
4. It is a direct child of `PROJECT_DIR`

This prevents accidental reads from sibling directories, parent directories, symlink escapes, and project subdirectories.

## Common Errors

### `PROJECT_DIR does not exist`

The configured project directory is wrong or no longer exists.

Check the value of:

```bash
PROJECT_DIR="..."
```

### `No direct .jsonl session files found`

The configured project directory exists, but it does not contain any direct `.jsonl` files.

Confirm that you pointed `PROJECT_DIR` at the specific Claude Code project history directory, not the parent `~/.claude/projects` directory.

### `Session parameter is ambiguous as a filename match`

Your session argument matched more than one filename.

Use a longer session id, a full `.jsonl` filename, or the human-readable session name if that is more precise.

### `Session parameter is ambiguous as a content/name/title match`

Your session argument appeared in more than one session file.

Use a more specific name/title fragment or pass the exact session filename.

### `Could not find a session matching ...`

The supplied session argument did not match any direct `.jsonl` file by filename, session id, or content/name/title search.

Run the script without arguments to export the newest available session, or inspect the listed available sessions.

## Limitations

This script depends on the current structure of Claude Code local JSONL session files. Claude Code’s internal storage format is not guaranteed to remain stable.

If Claude Code changes its transcript schema, the script may need updates.

The script does not attempt to repair malformed JSONL. If a session file contains invalid JSON lines, `jq` may fail.

The script does not redact secrets. Review output before sharing.

The content/name/title search is intentionally broad. It may match ordinary transcript content, not only formal session titles. This is useful when schemas vary, but it can also produce ambiguous matches.

## Recommended Workflow

Use this script for private local exports.

Suggested flow:

```bash
./export_claude_transcript.sh "Refactor auth flow"
open "$HOME/claude_exports"
```

Then review the Markdown file before moving, publishing, or sending it anywhere.

Use at your own risk. No warranty is provided.
