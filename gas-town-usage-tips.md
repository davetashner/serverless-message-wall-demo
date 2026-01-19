# Gas Town Usage Tips

Observations from a debugging session on 2026-01-19.

## Checking Polecat Status

```bash
# Overview of all agents
gt status

# List polecats and their work state
gt polecat list messagewall

# Detailed status including last activity time
gt polecat status messagewall/<name>

# Check what's on a polecat's hook (assigned work)
gt hook show messagewall/<name>
```

## Polecats Getting Stuck

**Symptom**: Polecats show "done" status but no commits appeared in git. Session capture shows they asked a question and are waiting for input.

**Cause**: Claude sessions can become unresponsive after receiving user input - they process the input but don't continue execution.

**Solution**: Nudge them to wake up:
```bash
gt nudge messagewall/<name> "please continue with your work"
```

This was needed multiple times in one session - after "commit" and again after "push".

## Viewing Polecat Work

```bash
# Capture recent terminal output (most useful)
gt session capture messagewall/<name>

# Check session health
gt session check messagewall
```

The capture shows what the polecat is doing, including pending questions and current processing status indicators like "Determining...", "Generating...", "Computing...".

## Stale Mail in Witness Inbox

**Symptom**: Witness shows `📬N` indicator but merge queue is empty.

**Check inbox**:
```bash
gt mail inbox messagewall/witness
gt mail inbox messagewall/witness --json  # for details
```

**Cause**: POLECAT_DONE messages from days ago that were never processed. The referenced branches/beads may no longer exist.

**Solution**: Either:
1. Archive stale messages: `gt mail archive <message-id>`
2. Clear all: `gt mail clear messagewall/witness` (if safe)

## Merge Queue Flow

The expected flow:
1. Polecat completes work → calls `gt done`
2. Witness receives POLECAT_DONE mail
3. Witness forwards MERGE_REQUEST to Refinery
4. Refinery rebases branch and merges to main

**If stuck at witness**:
```bash
gt nudge messagewall/witness "process pending POLECAT_DONE messages"
```

**If stuck at refinery**:
```bash
gt nudge messagewall/refinery "check inbox and process merge requests"
# Or inject directly:
gt session inject messagewall/refinery -m "run gt prime to process merge queue"
```

## Branch Divergence Issues

Polecat branches may diverge significantly from main if other work lands first.

**Check divergence**:
```bash
cd messagewall/polecats/<name>/messagewall
git log --oneline origin/main..HEAD  # commits to merge
git log --oneline HEAD..origin/main  # commits behind
```

The refinery handles rebasing, but complex conflicts may require manual intervention.

## Useful Diagnostic Commands

```bash
# Recent events across town
gt trail

# Check for orphaned work
cd messagewall && gt orphans

# Ready work not yet assigned
gt ready

# Merge queue status
gt mq list messagewall

# All mail queues
gt mail queue list
```

## Post-Merge Cleanup

After the refinery merges a polecat branch, the remote branch remains. Clean it up:

```bash
# List merged polecat branches
git branch -r | grep polecat

# Delete a merged branch
git push origin --delete polecat/<name>-<id>
```

## Key Learnings

1. **Nudge liberally** - If a polecat seems stuck, nudge it. Low cost, high benefit.

2. **Check session capture first** - Shows exactly what the polecat is doing or waiting for.

3. **Witness inbox accumulates** - Old POLECAT_DONE messages can pile up if not processed.

4. **Commits ≠ Pushes ≠ Merges** - A polecat may commit locally but not push, or push to a branch but not merge. Check each stage.

5. **Last Activity timestamp** - In `gt polecat status`, this shows wall-clock time since terminal activity, not necessarily Claude activity. A session can be "thinking" with no terminal output.

6. **Refinery rebases** - The refinery rebases polecat branches onto main before merging, so commit SHAs will differ between the branch and main.
