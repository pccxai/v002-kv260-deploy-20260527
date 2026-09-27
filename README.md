# Historical KV260 deployment and debug snapshot

This dated repository preserves the 2026-05-27-era PCCX v002 deployment
workspace, later debug notes, firmware artifacts and traces. It is **not** the
current public contribution entry point or a claim that today's main branches
reproduce every historical result.

Use [PCCX Start here](https://github.com/pccxai/pccx/blob/main/START_HERE.md),
[the reusable v002 core](https://github.com/pccxai/pccx-v002) and
[the active KV260 integration repository](https://github.com/pccxai/pccx-FPGA-NPU-LLM-kv260)
for new work. PCCX is initiated and operated by Altifigence; see
[Transparency](https://pccx.ai/en/legal/transparency/).

## Why this is retained

`debug/stage1_gemm_silicon.py`, historical build/timing artifacts and raw board
diagnostics have not been established as fully migrated into an active release.
The open [KV260 runtime issue #154](https://github.com/pccxai/pccx-FPGA-NPU-LLM-kv260/issues/154)
describes work in a deploy workspace. Deleting this repository now would risk
losing the provenance needed to compare and reproduce that work.

Before retirement:

- Inventory unique source patches, firmware, tool versions, reports and raw logs.
- Map each retained artifact to its source commit and checksum in the active repository.
- Review third-party/model/firmware redistribution rights and sensitive operational details.
- Validate the replacement instructions from a clean checkout and update consumers.
- Prefer archiving after migration; permanent deletion is a separate decision.

## Historical instructions and rights

`START-HERE.md` and the handoff notes record historical environments. Their host
addresses, machine state, commands and performance statements are not current
operator instructions or verified current hardware state.

No repository-wide license grant is established by this README. Inspect each
file's notices and obtain the relevant rights holder's permission where needed.
The Apache license of another PCCX repository does not automatically apply to
this mixed deployment snapshot. This update does not relicense any artifact.
