# 2pane

A minimal workflow for running Main and Expert agent sessions in one repository.

## Install

Authenticate `gh`, then run this from the root of the target repository:

```bash
gh api repos/aitopnexus/2pane-workflow/contents/2pane \
  -H 'Accept: application/vnd.github.raw+json' > 2pane.tmp &&
chmod +x 2pane.tmp &&
mv 2pane.tmp 2pane &&
./2pane init
```

`init` installs the agent skill, adds `.2pane/` to `.gitignore`, and creates the inbox.

Commit the installed workflow:

```bash
git add 2pane .agents/skills/two-pane-workflow/SKILL.md .gitignore
git commit -m "Add two-pane workflow"
```

## Use

```bash
./2pane expert          # Start the Expert session
./2pane send 'message'  # Send to the other session
./2pane take            # Read and consume a message
```

To update, repeat the install command.
