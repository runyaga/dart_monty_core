#!/usr/bin/env bash
set -uo pipefail

rc=0
for command in \
  "python3 tool/render_docs_data.py --check" \
  "python3 tool/check_docs_data.py" \
  "python3 tool/check_doc_names.py" \
  "python3 tool/check_doc_snippets.py" \
  "python3 tool/check_doc_links.py" \
  "python3 tool/check_docs_index.py"
do
  if ! eval "$command"; then
    rc=1
  fi
done
exit "$rc"
