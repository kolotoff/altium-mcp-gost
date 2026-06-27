# Project Rules

## Altium MCP

- Use the `mcp__altium` tools for Altium document and library operations in this repo.
- For Ultra Librarian footprint imports, read and follow `skills/import-ultralibrarian-footprint/SKILL.md`.
- For PcbLib edits, do not assume an MCP timeout means the edit failed. Read back the active PcbLib footprint list and inspect the exact footprint primitives before retrying or recreating.
- If Altium refuses normal save with `A command is currently active and save cannot be completed at this time. Do you want to save copy of current document?`, choose `No`; do not save a copy unless a duplicate library file is explicitly intended.
- First try `Esc` in Altium. If that does not release the save-blocked state, run:

```text
move_pcb_library_mechanical_layers(
  exclude_footprint_names=[],
  layer_moves=["PCB_POSTPROCESS"]
)
```

- After `PCB_POSTPROCESS`, retry normal save. Use `layer_moves=["SAVE_DOCUMENT_CONFIRMED"]` only if the recovery command succeeds but normal save still shows the warning.
- Do not save Altium documents automatically unless the user explicitly asks to save. Leave edited documents dirty for inspection when possible; if Altium appears to have saved automatically or the title state is ambiguous, report that state explicitly.

See `README.md` under the PcbLib save-state recovery notes for the detailed rationale.
