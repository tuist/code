# Issues

An issue belongs to the same repository as its source code. It is not stored in
a shared service or in a database on a node's local disk.

## Storage and durability

Code stores issue state in the repository's private
`refs/code/issues` Git reference. Every create, change, comment, or delete
operation creates a Git commit in that reference and sends its objects through
the normal write-ahead log path. Object storage is therefore the source of
truth for issue history as well as source history; a node can rebuild either
after its local repository directory is lost.

Each commit contains two forms of data:

- a small current-state projection, for efficient reads;
- an immutable issue or comment event, including the verified caller identity
  and the time of the operation.

The commit's Git author is the Code service. The event actor is the
authenticated principal, so a client cannot forge authorship with a Git author
header.

Issue and comment deletion writes a tombstone. The item no longer appears in
current views, while the immutable history remains available to authorized
readers. A deleted issue accepts no further comments or changes; they are
reported as not found.

The reference is hidden from Git advertisement and fetch, cannot be updated by
Git push, and is rejected by ordinary agent source-code tools. It is reserved
for Code's own issue implementation.

## Concurrency

An issue mutation is conditional on the current private-reference commit. If
another mutation wins first, Code rereads the projection, rebuilds the
change, and retries. The repository's existing writer serializes competing
object-storage compare-and-swap operations, so this requires no separate
leader or issue database.

Retries are bounded. When every attempt loses, or when the repository writer
rejects the write as overloaded or unavailable, or the write-ahead log's own
compare-and-swap retries are exhausted, nothing was recorded and the call
fails as a temporary error (`503` with `Retry-After` over HTTP). Code does not
retry those rejections itself; the caller may repeat the same request.

## Interfaces and authorization

The [Model Context Protocol](https://modelcontextprotocol.io/) exposes issue
and comment create, read, update, and delete operations, plus issue listing
and immutable history. Calls that only read require repository `read`
permission; mutations require `write` permission.

The same operations are available over the
[Hypertext Transfer Protocol](https://developer.mozilla.org/en-US/docs/Web/HTTP):

| Operation | Endpoint |
|---|---|
| List and create issues | `GET`, `POST /api/issues?repository=<id>` |
| Read, change, or delete an issue | `GET`, `PATCH`, `DELETE /api/issues/{issue}?repository=<id>` |
| List and add comments | `GET`, `POST /api/issues/{issue}/comments?repository=<id>` |
| Read, change, or delete a comment | `GET`, `PATCH`, `DELETE /api/issues/{issue}/comments/{comment}?repository=<id>` |
| Read immutable history | `GET /api/issues/{issue}/history?repository=<id>` |

The [OpenAPI](https://spec.openapis.org/oas/latest.html) description is
available at `GET /api/openapi.json`. Hypertext Transfer Protocol requests use
the same bearer-token authentication and per-repository authorization as Git
and the Model Context Protocol. A caller without read access receives `404` for
a repository, preserving the existing non-enumeration behavior.

## Pagination

Listing issues (`GET /api/issues` or `list_issues`) returns every current issue
in number order unless a `limit` (1 to 500) or `cursor` is given. With either,
the response holds at most `limit` issues (100 when only `cursor` is given)
numbered above `cursor`, and `next_cursor` is the number to pass next, or
`null` on the last page. Only as many issue projections are read as the page
needs, plus one to learn whether another page exists. Deleted issues are
skipped and never end a page early. Listing the issue numbers is one Git tree
read of the private reference.

## Errors

A failure has a kind, and each transport reports the kind rather than
interpreting the wording of its message:

| Kind | Meaning | HTTP |
|---|---|---|
| invalid | The request is malformed, for example an empty title | `422` |
| not found | The repository, issue, or comment does not exist; a deleted issue or comment counts as missing, and cannot be commented on | `404` |
| conflict | The request conflicts with the current durable state | `409` |
| unavailable | A temporary failure: storage, an overloaded writer, or exhausted retries | `503`, with `Retry-After` |

The Model Context Protocol tools report the same kind in the error result's
`structuredContent`; see [mcp.md](mcp.md#errors).
