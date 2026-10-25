# Worker tools behind the gateway

How the tools in an ensemble worker image behave on the `workers` caller network, where
the gateway is the only way out (WDRC-107 PRD FR-14; the tool table in the WDRC-90 PRD's
risks). A tool that ignores the proxy variables fails closed, as intended.

## How to fill this table

On the test Mac mini, through mini-op, never on a developer's Mac: with the gateway
healthy and the worker image built by ensemble's broker (`docker image ls ensemble-worker`),
run

```
./verify-egress --tools ensemble-worker:<key>
```

and replace the rows below with the rows it prints. Each row is one tool or one probe.

- **Expected**: `fails` or `works` from the PRD's table; `unknown` where it was
  unverified.
- **Result**: `works` (the gateway allowed the tool's request and the tool succeeded, or,
  for `gh` and Claude Code, which run with a dummy credential, the gateway allowed the
  request), `fails: no proxy used` (the gateway saw no allowed request from the tool),
  `fails: exit <n>` or `fails: timed out` (the gateway allowed the request but the tool
  failed), `not in image`, or `could not run: <reason>`. Results come from exit codes
  and the gateway's log only, never from a tool's output.
- **Image ID**: the image's ID as `docker image inspect --format '{{.Id}}'` reports it
  (`sha256:…`), so a row names exactly the image it was tested in.
- The command's last lines name the rows that differ from the expected result and the
  rows that could not run.

## Results

| Tool | Expected | Result | Image ID | Date |
| --- | --- | --- | --- | --- |
| ssh | fails | not yet tested | not yet tested | not yet tested |
| git over ssh | fails | not yet tested | not yet tested | not yet tested |
| scp | fails | not yet tested | not yet tested | not yet tested |
| rsync over ssh | fails | not yet tested | not yet tested | not yet tested |
| git:// | fails | not yet tested | not yet tested | not yet tested |
| ping | fails | not yet tested | not yet tested | not yet tested |
| traceroute | fails | not yet tested | not yet tested | not yet tested |
| dig | fails | not yet tested | not yet tested | not yet tested |
| nslookup | fails | not yet tested | not yet tested | not yet tested |
| host | fails | not yet tested | not yet tested | not yet tested |
| self-resolving program | fails | not yet tested | not yet tested | not yet tested |
| nc | fails | not yet tested | not yet tested | not yet tested |
| telnet | fails | not yet tested | not yet tested | not yet tested |
| psql | fails | not yet tested | not yet tested | not yet tested |
| redis-cli | fails | not yet tested | not yet tested | not yet tested |
| raw TCP (python3) | fails | not yet tested | not yet tested | not yet tested |
| raw UDP (python3) | fails | not yet tested | not yet tested | not yet tested |
| QUIC / HTTP/3 | fails | not yet tested | not yet tested | not yet tested |
| Node fetch | fails | not yet tested | not yet tested | not yet tested |
| Node fetch, NODE_USE_ENV_PROXY=1 | works | not yet tested | not yet tested | not yet tested |
| Node http | fails | not yet tested | not yet tested | not yet tested |
| Bun fetch | unknown | not yet tested | not yet tested | not yet tested |
| MCP server (Node child process) | unknown | not yet tested | not yet tested | not yet tested |
| curl | works | not yet tested | not yet tested | not yet tested |
| wget | works | not yet tested | not yet tested | not yet tested |
| pip | works | not yet tested | not yet tested | not yet tested |
| uv | works | not yet tested | not yet tested | not yet tested |
| npm | works | not yet tested | not yet tested | not yet tested |
| apt-get | works | not yet tested | not yet tested | not yet tested |
| gh | works | not yet tested | not yet tested | not yet tested |
| Claude Code | works | not yet tested | not yet tested | not yet tested |
