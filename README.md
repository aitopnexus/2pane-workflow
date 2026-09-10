# 2pane

A minimal workflow for running Main and Expert agent sessions in one repository.

## Install

Run this from the root of the target repository:

```bash
curl -fsSL https://raw.githubusercontent.com/aitopnexus/2pane-workflow/main/install-2pane.sh | bash
```

The installer downloads the public repository over HTTPS. It installs `2pane`, generates the agent skill, adds `.2pane/` to `.gitignore`, and creates the inbox.

[View the installer before running it.](https://github.com/aitopnexus/2pane-workflow/blob/main/install-2pane.sh)

Commit the installed workflow:

```bash
git add 2pane .agents/skills/two-pane-workflow/SKILL.md .gitignore
git commit -m "Add two-pane workflow"
```

## Use

```bash
./2pane dev             # Open the 4-pane herdr dev workspace (pi, shell, codex, fast pi)
./2pane expert          # Start the Expert session
./2pane send 'message'  # Send to the other session
./2pane take            # Read and consume a message
```

`./2pane dev` requires the [herdr](https://herdr.dev) CLI. It opens a workspace with Main (pi) and Expert (codex, lean defaults as in `./2pane expert`) panes plus two helper panes, and marks only the Expert pane with `AGENT_ROLE=expert`.

To update, repeat the install command.

### From a local checkout

If you keep a checkout of this repository, link the executable onto your PATH once:

```bash
ln -s /path/to/2pane-workflow/2pane ~/.local/bin/2pane
```

Then, from the root of any target repository, run `2pane init`. It installs `./2pane` into that repository from your checkout — no download — and initializes the workflow exactly like the bootstrap installer. Other commands run through the link target the current directory.
