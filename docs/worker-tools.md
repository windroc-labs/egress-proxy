# Worker tools behind the proxy

How the tools in an ensemble worker image behave on the `workers` caller network, where
the proxy is the only way out (WDRC-107 PRD FR-14; the tool table in the WDRC-90 PRD's
risks). A tool that ignores the proxy variables fails closed, as intended.

## How to fill this table

On the test Mac mini, through mini-op, never on a developer's Mac: with the proxy
healthy and the worker image built by ensemble's broker (`docker image ls ensemble-worker`),
run

```
~/.egress/verify-egress --tools ensemble-worker:<key>
```

and replace the rows below with the rows it prints. Each row is one tool or one probe.

- **Expected**: `fails` or `works` from the PRD's table; `unknown` where it was
  unverified.
- **Result**: `works` (the proxy allowed the tool's request and the tool succeeded, or,
  for `gh` and Claude Code, which run with a dummy credential, the proxy allowed the
  request), `fails: no proxy used` (the proxy saw no allowed request from the tool),
  `fails: exit <n>` or `fails: timed out` (the proxy allowed the request but the tool
  failed), `not in image`, or `could not run: <reason>`. Results come from exit codes
  and the proxy's log only, never from a tool's output.
- **Image**: `--tools` prints the image's full ID, as `docker image inspect --format
  '{{.Id}}'` reports it (`sha256:…`). The 2026-10-25 rows below came from a run of
  475817aa, before that change, and carry the worker version it printed (0.2.0) and the
  short ID from `docker image ls`; the next fill replaces them, and this note, with what
  `--tools` prints.
- The command's last lines name the rows that differ from the expected result and the
  rows that could not run.

## Results

Tested on the test Mac mini through mini-op on 2026-10-25: no row differed from the
expected result, and one row could not run (QUIC / HTTP/3: the image's curl has no
HTTP/3).

| Tool | Expected | Result | Image | Date |
| --- | --- | --- | --- | --- |
| ssh | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| git over ssh | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| scp | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| rsync over ssh | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| git:// | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| ping | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| traceroute | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| dig | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| nslookup | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| host | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| self-resolving program | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| nc | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| telnet | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| psql | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| redis-cli | fails | not in image | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| raw TCP (python3) | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| raw UDP (python3) | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| QUIC / HTTP/3 | fails | could not run: no HTTP/3 in curl | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| Node fetch | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| Node fetch, NODE_USE_ENV_PROXY=1 | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| Node http | fails | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| Bun fetch | unknown | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| MCP server (Node child process) | unknown | fails: no proxy used | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| curl | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| wget | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| pip | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| uv | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| npm | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| apt-get | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| gh | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
| Claude Code | works | works | 0.2.0, ID b776445a4c5d | 2026-10-25 |
