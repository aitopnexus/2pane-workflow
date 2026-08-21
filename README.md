# 2pane

A minimal workflow for running Main and Expert agent sessions in one repository.

## Install

Run this from the root of the target repository:

```bash
curl -fsSL https://gist.githubusercontent.com/aitopnexus/d75df86dcc4d7f849cc0e551f6dc47ac/raw/install-2pane.sh | bash
```

The installer uses your `github-aitopnexus` SSH credentials to download the private repository. It installs `2pane`, generates the agent skill, adds `.2pane/` to `.gitignore`, and creates the inbox.

[View the installer before running it.](https://gist.github.com/aitopnexus/d75df86dcc4d7f849cc0e551f6dc47ac)

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
