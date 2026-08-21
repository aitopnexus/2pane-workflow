# Human is the only router and serializer

Sessions never poll the inbox, detect messages on their own, or route work to each other. Every read and write is triggered by the human, who also ensures only one session touches the inbox at a time. We rejected auto-routing, polling, and file locking because they add orchestration this protocol exists to avoid, and because the human is already in the loop deciding which session handles each task. Launching Expert initializes runtime state but does not read the inbox.
