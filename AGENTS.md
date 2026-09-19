# Project Rules

- Use `mcp__altium` for Altium document and library operations.
- Read and follow task-relevant repo skills: `skills/import-ultralibrarian-footprint/SKILL.md`, `skills/create-board-description/SKILL.md`, and `skills/create-board-test-description/SKILL.md`.
- For bulk Altium results, keep raw data out of the conversation; report counts, relevant records, and exceptions. Scope searches and exclude generated assets.
- Put all generated deliverables, renders, exports, reports, screenshots, and temporary working files under the repository-root `generated/` directory. This directory is Git-ignored; do not commit generated artifacts.
- For PcbLib edits, verify the active footprint list and exact primitives after a timeout before retrying. Follow the PcbLib cleanup and save-state recovery notes in `README.md` when relevant.
- Do not save Altium documents unless explicitly asked; leave edits dirty for inspection. If the save-blocked warning appears, decline "save copy" unless a duplicate was explicitly requested, and follow the `README.md` recovery notes. Report any ambiguous save state.
