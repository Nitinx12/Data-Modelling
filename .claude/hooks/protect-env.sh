#!/bin/bash
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
FILE_PATH="${FILE_PATH//\\//}"

if [[ "$FILE_PATH" == *".env" && "$FILE_PATH" != *".env.example" ]]; then
  echo "Blocked: editing .env directly. Edit .env.example instead, or edit .env manually outside Claude Code." >&2
  exit 2
fi

exit 0