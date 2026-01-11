# ADR-004: DynamoDB Schema

## Status
Accepted

## Context
The application stores:
- A visitor/message count
- Recent messages posted by users

We need a schema that supports these access patterns while remaining simple for a demo.

## Decision
Use a **single-table design** with the following structure:

| PK | SK | Attributes |
|----|-----|------------|
| `METADATA` | `METADATA` | `messageCount` (Number) |
| `MESSAGE` | `<timestamp>#<uuid>` | `text` (String), `createdAt` (String) |

## Rationale
- Single table keeps Crossplane manifests simple
- Partition key `PK` distinguishes record types
- Sort key `SK` enables ordering messages by time
- No need for GSIs in this simple demo
- Message count is separate from visitor count (posting a message = 1 count)

## Access Patterns
1. **Increment count**: `UpdateItem` on `PK=METADATA, SK=METADATA`
2. **Add message**: `PutItem` with `PK=MESSAGE, SK=<timestamp>#<uuid>`
3. **Get recent messages**: `Query` on `PK=MESSAGE`, `ScanIndexForward=false`, `Limit=5`
4. **Get count**: `GetItem` on `PK=METADATA, SK=METADATA`

## Consequences
- snapshot-writer reads count + last 5 messages, writes to `state.json`
- No TTL configured initially (messages persist indefinitely)
- Schema is optimized for demo clarity, not production scale
