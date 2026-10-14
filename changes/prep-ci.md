### Internal

- CI: the merged-coverage ratchet on a push to main (and on a manual run) now compares with the commit's first parent, so a merge that deletes library files counts them as deleted instead of vanished; before, such a merge failed the run before the merged tracefile was uploaded, and the after-merge baseline could not be recorded. Pull requests are compared with their base branch as before. A `release` label on a pull request, or `force_all: true` on a manual run, makes the `changes` job report `code=true`, so every job runs on a Markdown-only change.
