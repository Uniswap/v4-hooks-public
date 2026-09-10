#!/bin/bash
set -e
rm -rf docs/autogen
# generate docs
# forge 1.8 parses sources with solar instead of compiling them, so no `forge build` is
# needed first, and the output is a vocs site (MDX pages under src/pages plus a scaffold)
# rather than an mdbook — the `-b` flag that built the book is gone.
forge doc -o docs/autogen

# forge doc derives the [Git Source] links from the repo it runs in, so generating here
# stamps every page with v4-hooks-internal. This tree is mirrored to v4-hooks-public, where
# those links 404 for anyone outside the org and where the repo's own doc check regenerates
# them as v4-hooks-public and fails on the difference. Pin them to the public repo so the
# generated tree is identical whichever side runs this.
# (`find -exec +` rather than `grep -l | xargs`: with no matches, GNU xargs still runs perl,
# which then reads stdin and hangs the hook in the public repo, where there is nothing to fix.)
find docs/autogen -type f -exec perl -pi -e 's#Uniswap/v4-hooks-internal#Uniswap/v4-hooks-public#g' {} +

# index.mdx is the README rendered with its relative links rewritten to absolute GitHub
# URLs pinned at HEAD, so all of them would churn on every commit. Pin them to `main`
# instead, so the committed tree depends only on the sources. The per-page
# `[Git Source]` links keep their commit hash; the loop below discards the files where
# that line is the only change.
perl -pi -e 's#(/blob/)[0-9a-f]{40}/#${1}main/#g' docs/autogen/src/pages/index.mdx

# Unstage all docs where only the commit hash changed
# Get a list of all unstaged files in the directory
files=$(git diff --name-only -- 'docs/autogen/*')

# Loop over each file
for file in $files; do
    # Check if the file exists
    if [[ -f $file ]]; then
        # Get the diff for the file, strip metadata and only keep lines that start with - or +
        diff=$(git diff $file | sed '/^diff --git/d; /^index /d; /^--- /d; /^\+\+\+ /d; /^@@ /d' | grep '^[+-]')

        # Filter lines that start with -[Git Source] or +[Git Source]
        filtered_diff=$(echo "$diff" | grep '^\-\[Git Source\]\|^\+\[Git Source\]' || true)

        # Compare the original diff with the filtered diff
        if [[ "$diff" == "$filtered_diff" ]]; then
            # If they are equal, discard the changes for the file
            git reset HEAD $file
            git checkout -- $file
        fi
    fi
done
