# Altium MCP Server

TLDR: Use Claude to control or ask questions about your Altium project.
This is a Model Context Protocol (MCP) server that provides an interface to interact with Altium Designer through Python. The server allows for querying and manipulation of PCB designs programmatically.

Note: Having Claude place components on the PCB currently fails hard.

## Example commands
- Run all output jobs
- Create a symbol for the part in the attached datasheet and use the currently open symbol as a reference example.
- Create a schematic symbol from the attached MPM3650 switching regulator datasheet and make sure to strictly follow the symbol placement rules. (Note: Need to open a schematic library. Uses `AppData\Roaming\Claude\Claude Extensions\local.dxt.altium-mcp\server\symbol_placement_rules.txt` description as pin placement rules. Please modify for your own preferences.)
- Find me the LM358 symbol in my opamp library and open it
- Create a multi-part symbol for a quad op-amp from the attached LM324 datasheet (creates parts A, B, C, D with shared V+/V- power pins)
- Create a PCB footprint for the SMD part in the attached datasheet and add it to my open PcbLib
- In the active PCB footprint library, set all pad shapes to rounded rectangle except footprint 53398-0271
- In the active PCB footprint library, move all primitives from Mechanical 13 to Mechanical 1 and Mechanical 15 to Mechanical 3, except footprint 53398-0271
- In the active PCB footprint library, create Draftsman-style projections of embedded 3D STEP bodies on Mechanical 2 with 0.1 mm tracks, except footprint 53398-0271
- Duplicate my selected layout. (Will prompt user to now select destination components. Supports Component, Track, Arc, Via, Polygon, & Region)
- Show all my inner layers. Show the top and bottom layer. Turn off solder paste.
- Get me all parts on my design made by Molex
- Give me the description and part number of U4
- Place the selected parts on my pcb with best practices for a switching regulator. Note: It tries, but does terrible placement. Hopefully I can find a way to improve this.
- Give me a list of all IC designators in my design
- Get me all length matching rules

## Installing the MCP Server
The easiest way to install is to use Claude Code, point it to this repo and ask it to install it for you. Or alternatively, see below.

[Watch on YouTube](https://youtu.be/HKQMK-hluLs)

1. Make sure Claude has Python 3.10+ installed: `drop down > File > Settings > Extensions > Advanced > Python`. If not, install Python and add it to PATH.
2. Download the `altium-mcp.dxt` desktop extension file from [releases](https://github.com/coffeenmusic/altium-mcp/releases)
3. In Claude Desktop on Windows: `drop down > File > Settings > Extensions > Advanced > Install Extension...` Select the .dxt file

You shouldn't need to restart Claude and you should now see altium-mcp in the tool menu near the search bar.

![altium-mcp in the tools menu](assets/extension.jpg)

## Creating a new .dxt (For Developers)

### Bootstrap Venv (Recommended)

This approach ships a small bootstrap script (`start_server.py`) that creates a virtual environment and pip-installs dependencies on the user's machine at first launch. The .dxt is tiny (~60 KB) and works across any Python 3.10+ version.

The older approach of bundling pre-compiled packages in `server/lib/` is no longer recommended — it breaks when the user's Python version doesn't match the version used to build the bundled `.pyd` files (e.g. pydantic_core compiled for 3.11 fails on 3.13).

**How it works:**

1. `start_server.py` (at the repo root) checks for `server/.venv/Scripts/python.exe`
2. If the venv doesn't exist, it creates one and pip-installs the pinned dependencies
3. It then launches `server/main.py` using the venv's Python
4. First launch takes ~20-30 seconds; subsequent launches are instant

**Build steps:**

1. Make sure `start_server.py` exists at the repo root (see below for contents)
2. Make sure `server/main.py` does NOT have the old `site.addsitedir` hack at the top
3. Update `manifest.json`: set `entry_point` to `start_server.py`, remove any `env`/`PYTHONPATH` fields, and use `manifest_version: "0.3"`
4. Package the DXT — either use `dxt pack` or manually zip and rename:
```powershell
Compress-Archive -Path manifest.json, start_server.py, pyproject.toml, server -DestinationPath altium-mcp.zip
Rename-Item altium-mcp.zip altium-mcp.dxt
```

**Do NOT include `server/lib/` or `server/.venv/` in the .dxt.** The whole point is that these are created on the user's machine.

**`start_server.py`:**
```python
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
VENV_DIR = SCRIPT_DIR / "server" / ".venv"
REQUIREMENTS = [
    "mcp[cli]==1.5.0",
    "pillow>=11.1.0",
    "pywin32>=310",
]

def ensure_venv():
    python_exe = VENV_DIR / "Scripts" / "python.exe"
    if python_exe.exists():
        return str(python_exe)

    subprocess.check_call([sys.executable, "-m", "venv", str(VENV_DIR)])
    pip_exe = str(VENV_DIR / "Scripts" / "pip.exe")
    subprocess.check_call([pip_exe, "install", "--quiet"] + REQUIREMENTS)
    return str(python_exe)

if __name__ == "__main__":
    venv_python = ensure_venv()
    server_path = str(SCRIPT_DIR / "server" / "main.py")
    sys.exit(subprocess.call([venv_python, server_path]))
```

**`manifest.json` server section:**
```json
"server": {
    "type": "python",
    "entry_point": "start_server.py",
    "mcp_config": {
      "command": "python",
      "args": ["${__dirname}/start_server.py"]
    }
  }
```

### Pitfalls

These are hard-won lessons from debugging DXT builds. Violating any of these will produce errors that are difficult to diagnose.

1. **Do NOT use `os.execv()` in `start_server.py`.** The DXT installs to a path containing spaces (`Claude Extensions`). On Windows, `os.execv` splits the path at the space and fails. Use `sys.exit(subprocess.call([...]))` instead.

2. **Pin `mcp` to `==1.5.0`.** Using `>=1.5.0` pulls in the latest version, which has breaking API changes (`FastMCP.__init__()` dropped the `description` kwarg). The server code was written against 1.5.0.

3. **Do NOT use `manifest_version: "0.4"` with `"type": "uv"`.** Claude Desktop does not support it yet. You will get `Invalid manifest: server: Required`. Use `"type": "python"` with `manifest_version: "0.3"`.

4. **After removing the `site.addsitedir` hack from `main.py`, fix the `pathlib.Path` reference.** The hack included `import pathlib` at the top of the file. The logging setup later uses `pathlib.Path(...)` which will throw `NameError` once that import is gone. Change it to `Path(...)` — the `from pathlib import Path` import already exists in the file, just make sure it comes before the logging setup.

5. **Do NOT bundle `server/lib/` in the DXT.** That was the old approach and defeats the purpose of the venv bootstrap.

### Legacy: Bundled server/lib (Not Recommended)

This approach bundles all dependencies in `server/lib/` and sets `PYTHONPATH` to point to it. It produces a much larger .dxt (~17 MB) and **only works if the user's Python version matches the version used to compile the bundled packages**.

1. Populate packages: `python -m pip install --no-cache-dir --target server/lib -r requirements.txt`
2. Set the manifest `entry_point` to `server/main.py` and add `"env": {"PYTHONPATH": "${__dirname}/server/lib"}` to `mcp_config`
3. Package: `npm install -g @anthropic-ai/dxt && dxt pack`

### DXT Resources
- [Desktop Extensions](https://www.anthropic.com/engineering/desktop-extensions)
- [Desktop Extensions Github](https://github.com/anthropics/dxt)
- [Getting Started with DXT](https://support.anthropic.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
- [Python DXT Example Code](https://github.com/anthropics/dxt/tree/main/examples/file-manager-python)
- [DXT Manifest](https://github.com/anthropics/dxt/blob/main/MANIFEST.md)


## Configuration

When launching claude for the first time, the server will automatically try to locate your Altium Designer installation. It will search for all directories that start with `C:\Program Files\Altium\AD*` and use the one with the largest revision number. If it cannot find any, you will be prompted to select the Altium executable (X2.EXE) manually when you first run the server. Altium's DelphiScript scripting is used to create an API between the mcp server and Altium. 

## Available Tools

The server provides several tools to interact with Altium Designer:

### Output Jobs
- `get_output_job_containers`: Using currently open .OutJob file, reads all available output containers
- `run_output_jobs`: Pass a list of output job container names from the currently open .OutJob to run any number of them. `.OutJob` must be the currently focused document.

### Component Information
- `get_all_designators`: Get a list of all component designators in the current board
- `get_all_component_property_names`: Get a list of all available component property names
- `get_component_property_values`: Get the values of a specific property for all components
- `get_component_data`: Get detailed data for specific components by designator
- `get_component_pins`: Get pin information for specified components

### Schematic/Symbol
- `get_schematic_data`: Get schematic data for specified components
- `create_schematic_symbol` ([YouTube](https://youtu.be/MMP7ZfmbCMI)): Passes pin list with pin type & coordinates to Altium script. Supports multi-part symbols (e.g. quad op-amps) via a `part_count` parameter and an `owner_part_id` field on each pin (use 0 for shared power/GND pins). Also supports active-low pin name overbars by placing a backslash after each overbarred character (e.g. `R\E\S\E\T\` renders as `RESET` with overbar).
- `get_symbol_placement_rules`: Create symbol's helper tool that reads `~\AppData\Roaming\Claude\Claude Extensions\local.dxt.altium-mcp\server\symbol_placement_rules.txt` to get pin placement rules for symbol creation.
- `get_library_symbol_reference`: Create symbol's helper tool to use an open library symbol as an example to create the symbol
- `search_library_symbol`: Search for a symbol by name in a schematic library (.SchLib) and navigate to it. Supports partial name matching. Will open the library file in Altium if a path is provided, or show a file picker if not.

![Symbol Creator](assets/symbol_creator.gif)

### Layout Operations
- `get_all_nets`: Returns a list of unique nets from the pcb
- `create_net_class` ([YouTube](https://youtu.be/89booqRbnzQ)): Create a net class from a list of nets
- `get_pcb_layers`: Get detailed layer information including electrical, mechanical, layer pairs, etc.
- `get_pcb_layer_stackup`: Gets stackup info like dielectric, layer thickness, etc.
- `set_pcb_layer_visibility` ([YouTube](https://youtu.be/XaWs5A6-h30)): Turn on or off any group of layers. For example turn on inner layers. Turn off silk.
- `get_pcb_rules`: Gets the rule descriptions for all pcb rules in layout.
- `get_selected_components_coordinates`: Get position and rotation information for currently selected components
- `move_components`: Move specified components by X and Y offsets
- `layout_duplicator` ([YouTube](https://youtu.be/HD-A_8iVV70)): Starts layout duplication assuming you have already selected the source components on the PCB.
- `layout_duplicator_apply`: Action #2 of `layout_duplicator`. Agent will use part info automatically to predict the match between source and destination components, then will send those matches to the place script.

The cool thing about layout duplication this way as opposed to with Altium's built in layout replication, is that the exact components don't have to match because the LLM can look through the descriptions and understand which components match and which don't have a match. That's something that can't really be hard coded.
![Placement Duplicator](assets/placement_duplicator.gif)

### PCB Footprint Library
- `create_pcb_footprint`: Create a new PCB footprint in the currently active .PcbLib document. Supports SMD pads (Rect, Round, and Oval/rounded-rectangle shapes) defined in mm relative to the component origin. Auto-generates a courtyard on Mech 15 and silkscreen with a pin 1 indicator (gap in the top-left corner), or accepts explicit courtyard dimensions. Rounded-rectangle pads use Altium's `eRoundedRectangular` pad shape enum. Contributed by [coffeedust](https://github.com/coffeedust) ([PR #7](https://github.com/coffeenmusic/altium-mcp/pull/7)).
- `set_pcb_library_pad_shapes`: Set all copper pad shapes in the currently active .PcbLib document to Rounded Rectangle, excluding any footprint names passed in `exclude_footprint_names` (for example `["53398-0271"]`). Uses Altium's `eRoundedRectangular` pad shape enum.
- `move_pcb_library_mechanical_layers`: Move primitives between mechanical layers in the currently active .PcbLib document, excluding any footprint names passed in `exclude_footprint_names` (for example `["53398-0271"]`). Layer moves are passed as `source|destination` strings in `layer_moves`, for example `["13|1", "15|3"]`.

#### Footprint descriptions

Footprint descriptions must describe the part using useful datasheet or product-page facts, not the generation method. Include the manufacturer or series, connector/package role, position or pin count, pitch, orientation/entry style, mating or stacking height, and important ratings when they are relevant to footprint selection. Do not include provenance text such as `generated from ...`, `copied from ...`, or a reference-footprint name.

#### Adding 3D STEP bodies to PcbLib footprints

Use the vendor STEP file unchanged. Do not rotate, mirror, translate, or add PcbLib-origin offsets to the STEP geometry itself. Altium stores a generic STEP body's placement separately from the model file, using the 3D Body location, model rotation, and standoff/height fields.

The common placement state is:

- body location: X/Y in the footprint/PcbLib coordinate system.
- model orientation: Rotation X, Rotation Y, and Rotation Z in the Generic 3D Model properties.
- vertical placement: Generic STEP model Z offset plus Overall Height. Keep the component-body standoff metadata at `0 mm` for this flow.

Calculate vertical STEP placement from transformed model geometry, not from the absolute lowest STEP vertex alone. After applying the intended Altium model rotations, group transformed vertex Z values into 0.001 mm planes. Ignore sparse outlier planes and use the first negative plane whose count is significant for that model, for example at least half of the most populated Z plane and at least 8% of all transformed vertices. Use `model_z_mm = -contact_plane_z_mm` and keep the component body standoff field at `0 mm` unless there is a specific Altium UI requirement. This places the dense pad/contact plane on the board pad surface while avoiding isolated plastic or reference-geometry outliers. In generated diagnostics, `computed_model_z_mm` is the value to pass as the `3D_BODY_SET_PLACEMENT` model-Z argument; `computed_body_standoff_height_mm` should remain `0`.

For documents with a non-zero PcbLib board origin, keep the correction in the body/model placement state. If code or a metadata tool writes raw PcbLib coordinates, calculate:

```text
raw_x = Board.XOrigin + local_footprint_x
raw_y = Board.YOrigin + local_footprint_y
```

`Board.XOrigin` and `Board.YOrigin` can be non-zero in a PcbLib, so a footprint-local body center at `(0, 0)` may be stored at raw coordinates offset by the library origin. Read those origin values from `3D_BODY_DUMP` and apply them only to the Altium body snap point. Do not edit STEP `CARTESIAN_POINT` records to compensate for a PcbLib origin.

The safe manual Altium flow is:

1. Focus the target footprint in the `.PcbLib`.
2. Place/import the original vendor STEP as a Generic 3D Body.
3. Set X/Y, Rotation X/Y/Z, Model Z/Standoff Height, and Overall Height in Altium's 3D Body Properties panel.
4. If scripted import left the body at raw local coordinates instead of origin-adjusted PcbLib coordinates, run `3D_BODY_FIX_ORIGIN_OFFSET|<footprint>` or `3D_BODY_FIX_ORIGIN_OFFSET|*`. This moves the Altium 3D body object by `Board.XOrigin`/`Board.YOrigin`; it does not edit STEP geometry or model rotation.
5. Run `3D_BODY_DUMP` and verify the origin-corrected `left_mm`, `right_mm`, `bottom_mm`, and `top_mm` are centered around the footprint.
6. After any scripted PcbLib modification, run `PCB_POSTPROCESS` before saving.

The script may safely create a basic STEP body container and set supported `IPCB_ComponentBody` height fields:

```pascal
PcbLib.CurrentComponent := Footprint;
Board := PcbLib.Board;

StepBody := PCBServer.PCBObjectFactory(eComponentBodyObject, eNoDimension, eCreate_Default);
StepBody.Layer := ILayer.MechanicalLayer(1);
Model := StepBody.ModelFactory_FromFilename(StepPath, False);
StepBody.Model := Model;
StepBody.SetState_FromModel;
StepBody.Layer := ILayer.MechanicalLayer(1);
StepBody.StandoffHeight := MMsToCoord(StandoffMm);
StepBody.OverallHeight := MMsToCoord(OverallHeightMm);

PCBServer.SendMessageToRobots(StepBody.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
Board.AddPCBObject(StepBody);
PCBServer.SendMessageToRobots(StepBody.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
```

Do not use DelphiScript to transform the STEP model data. Apply placement through the 3D Body object/model state and leave the STEP file byte-for-byte unchanged. In Altium Designer 26.6, the following have caused compile errors or `ScriptingSystem.dll` access violations:

- assigning non-existent properties such as `Body.ModelRotationX` or `Model.ROTX`.
- assigning `IPCB_ComponentBody.X`, `IPCB_ComponentBody.Y`, `RotationX`, `RotationY`, or `RotationZ` from the PcbLib script path, either before or after `Board.AddPCBObject`.
- using .NET/property-panel wrapper members from DelphiScript, such as `GetState_ModelDescriptorString`.
- calling `IPCB_Model.SetState(...)` without pushing the model back onto the body and rebuilding the body from the model.
- deleting existing 3D bodies and re-importing replacements in the same scripted operation.

`3D_BODY_IMPORT|...` is therefore intentionally non-mutating in this MCP script. It returns the requested placement values for review, but it does not delete or re-add bodies.

The generic scripted placement sequence for an existing body is:

```pascal
Model := Body.GetModel;
Model.SetState(RotX, RotY, RotZ, MMsToCoord(ModelZMM));
Body.SetModel(Model);
Body.SetState_FromModel;
Body.SetState_SnapPointX(Board.XOrigin + MMsToCoord(LocalXMM));
Body.SetState_SnapPointY(Board.YOrigin + MMsToCoord(LocalYMM));
Body.StandoffHeight := MMsToCoord(StandoffMM);
Body.OverallHeight := MMsToCoord(OverallHeightMM);
```

`SetState_FromModel` can reset the body reference point, so always set `SetState_SnapPointX/Y` after it. Add `Board.XOrigin`/`Board.YOrigin` when writing raw snap points so the 3D body stays in the footprint coordinate frame.

Do not recenter a 3D body by its bounding rectangle after setting the snap point. The Generic STEP model reference point and the visible bounding-box center are not guaranteed to be the same, so snap-point plus bounding-box movement can drift X/Y placement.

Avoid part-number-specific refresh or generator helpers in the common MCP script. Use explicit footprint names, explicit STEP file paths, and explicit Altium placement values, then verify placement with `3D_BODY_DUMP` before saving.

Supported generic helper commands:

- `3D_BODY_DUMP`: reports body bounding boxes, raw coordinates, board origin, standoff height, and overall height.
- `3D_BODY_SET_HEIGHTS|<footprint>|<standoff_mm>|<overall_height_mm>`: updates existing 3D body height fields without touching STEP geometry or model rotation. Use `*` as the footprint name to update all footprints.
- `3D_BODY_SET_PLACEMENT|<footprint>|<local_x_mm>|<local_y_mm>|<rot_x_deg>|<rot_y_deg>|<rot_z_deg>|<model_z_mm>|<standoff_mm>|<overall_height_mm>`: updates an existing Generic 3D Body's Altium placement state. It uses `IPCB_Model.SetState`, `IPCB_ComponentBody.SetModel`, `SetState_FromModel`, then `SetState_SnapPointX/Y` with `Board.XOrigin + local_x` and `Board.YOrigin + local_y`. It does not transform or rewrite the STEP file.
- `3D_BODY_FIX_ORIGIN_OFFSET|<footprint>`: moves existing 3D bodies whose raw bounding rectangle is still near local origin by the active PcbLib `Board.XOrigin`/`Board.YOrigin`. Use `*` as the footprint name to repair all unshifted bodies while skipping already-shifted bodies.
- `FOOTPRINT_PRIMITIVE_DUMP|<footprint>`: dumps pads, tracks, arcs, regions, and body primitives for a single footprint.
- `PCB_LIB_DESCRIPTION_DUMP|<footprint>`: dumps footprint descriptions. Use `*` as the footprint name to inspect all footprints in the active PcbLib.
- `PCB_LIB_SET_DESCRIPTION|<footprint>|<description>`: updates a footprint description with datasheet/product-page facts. Pass one command per footprint; do not use it to write generation provenance.
- `PCB_LIB_CLEAN_PADS_OVERLAY|<target_name_contains>|<pad_name_prefix>|<overlay_layer>`: selects matching footprints, deletes pads whose names start with the prefix, and deletes tracks/arcs on the named overlay layer through Altium's editor delete process. Use it before a `PCB_LIB_BATCH_CREATE|...|FALSE` refresh when replacing generated mounting pads and overlay graphics.
- `PCB_LIB_BATCH_CREATE|<data_file>|<skip_existing>`: creates or populates PcbLib footprints from a pipe-delimited data file with `FOOTPRINT`, `PAD`, `TRACK`, `ARC`, `TEXT`, and `END` records. Use this for generic batch footprint work only; keep part-family tables in a task-local file, not in the common script or README. The helper writes raw primitive coordinates through the active PcbLib board using `Board.XOrigin + local_x` and `Board.YOrigin + local_y`, so it works with non-zero PcbLib origins.
- `PCB_POSTPROCESS`: call after any PcbLib modification to close any leftover PCB server transaction and redraw the editor.

When verifying a 3D placement update, run `3D_BODY_SET_PLACEMENT` and `PCB_POSTPROCESS` as separate MCP calls so the placement result is visible in the tool response before the refresh result.

When sending descriptions through `layer_moves`, prefer semicolon-separated clauses instead of commas. The MCP command transport treats commas as list delimiters in some paths.

Example placement repair after a body imported with the right STEP file but default Generic model orientation:

```text
move_pcb_library_mechanical_layers(
  exclude_footprint_names=[],
  layer_moves=["3D_BODY_SET_PLACEMENT|<footprint>|<local_x_mm>|<local_y_mm>|<rot_x_deg>|<rot_y_deg>|<rot_z_deg>|<model_z_mm>|<standoff_mm>|<overall_height_mm>"]
)
```

Keep family-specific placement tables outside this README. The common workflow is to capture placement from a known-good footprint or mechanical drawing, apply it with `3D_BODY_SET_PLACEMENT`, and verify the resulting raw and origin-corrected body bounds with `3D_BODY_DUMP`.

#### 3D STEP silhouette projections

The PcbLib mechanical-layer tool also has internal commands used to create Draftsman-style 2D silhouettes from embedded 3D STEP bodies. The intended flow is:

1. Focus the target `.PcbLib` in Altium.
2. Run `3D_BODY_DUMP` through `move_pcb_library_mechanical_layers` to dump each non-excluded footprint's 3D body bounding rectangle and active library path into `C:\Users\Public\altium_mcp\response.json`.
3. Extract the embedded STEP model streams from that active PcbLib:
   ```powershell
   python tools\extract_pcblib_embedded_steps.py
   ```
   With no arguments, the extractor reads the `library_path` from the last `3D_BODY_DUMP` response and writes the original embedded model names to `C:\Users\Public\altium_mcp\embedded_3d_models`. You can also pass paths explicitly:
   ```powershell
   python tools\extract_pcblib_embedded_steps.py "D:\path\Library.PcbLib" "C:\Users\Public\altium_mcp\embedded_3d_models"
   ```
4. Generate STEP silhouette segments:
   ```powershell
   python tools\generate_step_silhouette.py
   ```
   The generator reads the last `3D_BODY_DUMP` response, finds the extracted `.step`/`.stp` file by the PcbLib `MODEL.NAME` metadata first, and writes `C:\Users\Public\altium_mcp\3d_body_silhouette.txt`. The output file may contain both `LINE` and `ARC` records; the optimizer deduplicates identical edges, merges collinear overlapping line segments, rejects primitives covered by longer merged primitives, and converts circular polyline runs to real arcs when the fitted arc stays inside the source geometry bounds. It also uses the intended 0.1 mm projection stroke as a visibility threshold: centerlines shorter than the stroke, arcs shorter than the stroke, and arcs with a radius smaller than the stroke are dropped, then remaining small primitives are sampled and removed when their centerline is already inside another line or arc stroke.
5. Remove old generated tracks with `3D_BODY_EDITOR_CLEAN|<mechanical_layer>|<line_width_mm>`.
6. Append the generated segments with `3D_BODY_SILHOUETTE_APPEND|<mechanical_layer>|<line_width_mm>`.
7. Add `.Designator` and `.Comment` special strings with `3D_BODY_TEXT|<mechanical_layer>`, for example `3D_BODY_TEXT|2`. Text style and placement are defined in code as TrueType/Arial, 1.5 mm height. `.Comment` is centered below the projection with a 0.2 mm visual Y-axis gap. `.Designator` uses the `.De` anchor for alignment and overlap checks; the generator searches around the projection center for the nearest clear anchor position before falling back above the projection.
8. Verify with `3D_BODY_TRACK_COUNT|<mechanical_layer>|<line_width_mm>`.

The extractor reads Altium's OLE compound-file `Models` storage directly and decompresses the embedded zlib STEP streams. Do not use a manually downloaded model when the PcbLib has `MODEL.EMBED=TRUE`; extract the embedded stream and keep its original `MODEL.NAME` filename.

Do not infer projection rotation from footprint names. The generator reads the PcbLib's embedded model state records (`MODEL.NAME`, `MODEL.3D.ROTX`, `MODEL.3D.ROTY`, `MODEL.3D.ROTZ`, `MODEL.2D.ROTATION`, and `IDENTIFIER`) and derives the correction from that metadata. It prefers the exact extracted `MODEL.NAME` file, and it can also match a model identifier prefix to footprint variants when the naming scheme is shared. It applies that 3D placement before filtering the STEP topology to top-facing visible face boundaries, so hidden/back-side edges are not emitted. This keeps top-entry, side-entry, and future connector variants tied to their actual embedded 3D body placement instead of a hard-coded suffix.

The Altium importer accepts the new optimized `LINE`/`ARC` records and still accepts the legacy five-field line format. The cleanup, count, select, and text-placement helpers treat tracks and arcs as projection primitives, so rerunning `3D_BODY_EDITOR_CLEAN|layer|width` removes both primitive types.

For tuning the projection optimizer, select example generated tracks/arcs in the active footprint and run `3D_BODY_SELECTED_DUMP|<mechanical_layer>|<line_width_mm>`. The diagnostic returns selected primitive kind, local coordinates, line length or arc radius/sweep/length, and stroke width, which makes it easier to adjust the stroke-aware pruning thresholds without guessing.

Use `3D_BODY_PROJECTION|<mechanical_layer>|<line_width_mm>` only as a fallback. It draws the 3D body's bounding rectangle, not the real STEP silhouette.

Do not save the PcbLib automatically after these operations. Leave the document dirty and let the user inspect the mechanical layer and save manually.

If a PcbLib-modifying script hit an access violation or Altium later refuses to save with `A command is currently active and save cannot be completed at this time`, run the PcbLib save-state recovery command once:

```text
move_pcb_library_mechanical_layers(
  exclude_footprint_names=[],
  layer_moves=["PCB_POSTPROCESS"]
)
```

`PCB_POSTPROCESS` intentionally calls `PCBServer.PostProcess`, then sends `PCB:Cancel`, clears selection, and redraws the PCB editor. This is a recovery for an unmatched `PCBServer.PreProcess` left behind by a failed PcbLib script command. After any large scripted PcbLib modification, especially one that deleted/re-added footprint primitives or 3D bodies, call this recovery before trying to save if Altium still appears to be inside an active command.

If normal `Ctrl+S` still shows the warning after recovery, save through Altium's workspace process:

```text
move_pcb_library_mechanical_layers(
  exclude_footprint_names=[],
  layer_moves=["SAVE_DOCUMENT"]
)
```

In Altium Designer 26.6 this direct `WorkspaceManager:SaveObject` path succeeded after the PcbLib title still showed `*` and the normal save UI remained blocked. If the warning dialog appears, choose `No`; do not save a copy unless a separate duplicate library file is intended.

#### Deleting primitives from PcbLib safely

For PcbLib cleanup, prefer Altium's editor deletion path over direct object removal. Directly calling `Footprint.RemovePCBObject(Primitive)` on many primitives, especially after collecting them from a library footprint iterator, can destabilize Altium's scripting host and has caused `ScriptingSystem.dll` access violations.

Use this pattern instead:

1. Clear selection with `Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView)`.
2. Set `PcbLib.CurrentComponent := Footprint` for the footprint being cleaned.
3. Refresh the view with `Board.ViewManager_FullUpdate` when `Board` is available.
4. Iterate the footprint's primitives and set `Primitive.Selected := True` only on objects that should be deleted.
5. Delete through the editor with `Client.SendMessage('PCB:DeleteObjects', 'Object=SELECTED', 255, Client.CurrentView)`.
6. Clear selection again and redraw with `Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView)`.

Use `Object=SELECTED` when more than one primitive may be selected. `Object=FOCUSED` can delete only one selected 3D body and leave stale duplicate bodies attached to the footprint.

The `3D_BODY_EDITOR_CLEAN|layer|width` command follows this select-and-delete approach for generated projection tracks. Avoid using direct-delete cleanup for generated PcbLib projections or 3D component bodies unless there is a very specific reason and it has been tested in the target Altium version.

### Both
- `get_screenshot`: Take a screenshot of the Altium PCB window or Schematic Window that is the current view. It should auto focus either of these if it is open but a different document type is focused. Note: Claude is not very good at analyzing images like circuits or layout screenshots. ChatGPT is very good at it, but they haven't released MCP yet, so this functionality will be more useful in the future.

### Server Status
- `get_server_status`: Check the status of the MCP server, including paths to Altium and script files

## How It Works

The server communicates with Altium Designer using a scripting bridge:

1. It writes command requests to `workspace\request.json`
2. It launches Altium with instructions to run the `Altium_API.PrjScr` script
3. The script processes the request and writes results to `workspace\response.json`
4. The server reads and returns the response

The script runner procedure should include the `.pas` unit name:

```text
ProcName=Altium_API.pas>Run
```

## References
- Get scripts' project path from Jeff Collins and William Kitchen's stripped down version
- BlenderMCP: I got inspired by hearing about MCP being used in Blender and used it as a reference. https://github.com/ahujasid/blender-mcp
- Used CopyDesignatorsToMechLayerPair script by Petar Perisin and Randy Clemmons for reference on how to .Replicate objects (used in layout duplicator)
- Petar Perisin's Select Bad Connections Script: For understanding how to walk pcb primitives (track, arc, via, etc) connected to a pad
- Matija Markovic and Petar Perisin Distribute Script: For understanding how to properly let the GUI know when I've updated tracks' nets
- Petar Perisin's Room from Poly: Used as reference to detect poly to pad overlap since I couldn't get more tradition methods to work.
- Petar Perisin's Layer Panel Script: Used as reference for getting layers and changing layer visibility
- Jeff Collins has an XIA_Release_Manager.pas script that taught me the art of the Output Job. See his post on the Altium Forums: https://forum.live.altium.com/#/posts/189423

## Contributors
- [coffeedust](https://github.com/coffeedust) — `create_pcb_footprint` tool for PcbLib automation ([PR #7](https://github.com/coffeenmusic/altium-mcp/pull/7))
- [fwolter](https://github.com/fwolter) — Fix JSON parsing error when the decimal separator is a comma ([PR #3](https://github.com/coffeenmusic/altium-mcp/pull/3))

## Disclaimer
This is a third-party integration and not made by Altium. Made by [coffeenmusic](https://x.com/coffeenmusic)

# TODO:
- Change selection filter:
  - `scripts-libraries\Scripts - PCB\FilterObjects\`
  - `scripts-libraries\Scripts - SCH\SelectionFilter\`
- Show/Hide Panels: `DXP/ReportPCBViews.pas`
- Create rules: `PCB/CreateRules.pas`
- Run DRC: IPCB_Board.RunBatchDesignRuleCheck( 
- Move cursor to position: IPCB_Board.XCursor, IPCB_Board.YCursor 
- Add get schematic & pcb library path for footprint. 
- Add get symbol from library
- log response time of each tool
- Add go to schematic sheet
- Go to sheet with component designator
- Board.ChooseLocation(x, y, 'Test');
- Zoom to selected objects:
- Change Schematic Selection Filter: SelectionFilter.pas
- Place schematic objects (place component from library): PlaceSchObjects.pas
- How can I read through components from libraries in Components panel?

TODO Tests:
Need to add the following test units
- `get_pcb_layers` 
- `set_pcb_layer_visibility`
- `layout_duplicator`
- `get_pcb_screenshot`
