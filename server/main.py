from mcp.server.fastmcp import FastMCP, Context
import json
import os
import time
import asyncio
import logging
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, Any, Optional
import sys
import win32gui
import win32ui
import win32con
import win32api
import win32file
from PIL import Image
import io
import base64
import glob
import re
import math
import xml.etree.ElementTree as ET

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,  # Change to DEBUG for more detailed logs
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),  # Output to console
        logging.FileHandler(str(Path(__file__).with_name('altium_mcp.log')))  # Also log to file
    ]
)
logger = logging.getLogger("AltiumMCPServer")

def json_dumps(data, **kwargs):
    """Serialize MCP tool payloads without escaping readable Unicode text."""
    kwargs.setdefault("ensure_ascii", False)
    return json.dumps(data, **kwargs)

# Set MCP_DIR to the directory of the current Python file
MCP_DIR = Path(__file__).parent
CONFIG_FILE = MCP_DIR / "config.json"
DEFAULT_SCRIPT_PATH = MCP_DIR / "AltiumScript" / "Altium_API.PrjScr"

# Use a fixed exchange directory for request/response JSON files.
# Both the Python MCP server and the Altium DelphiScript need to independently
# resolve to the same directory. C:\Users\Public is writable by all users and
# exists on every Windows machine. This avoids fragile script-project-path
# resolution that breaks when Altium caches stale script projects.
EXCHANGE_DIR = Path("C:/Users/Public/altium_mcp")
EXCHANGE_DIR.mkdir(exist_ok=True)
REQUEST_FILE = EXCHANGE_DIR / "request.json"
RESPONSE_FILE = EXCHANGE_DIR / "response.json"
EASYEDA_PIPE = r"\\.\pipe\EasyEDA-Loader.CommandBridge"

# Initialize FastMCP server
mcp = FastMCP("AltiumMCP", description="Altium integration through the Model Context Protocol")


def _absolute_output_path(value: str, extension: str) -> Path:
    target = Path(value).expanduser()
    if not target.is_absolute():
        raise ValueError("Output paths must be absolute")
    target = target.resolve()
    if target.suffix.lower() != extension.lower():
        raise ValueError(f"Output path must end in {extension}")
    return target


def _prepare_output_path(target: Path, overwrite: bool) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if not overwrite:
            raise FileExistsError(f"Output file already exists: {target}")
        target.unlink()


def _normalize_html_color(value: str, name: str) -> str:
    color = (value or "").strip()
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
        raise ValueError(f"{name} must be a #RRGGBB color")
    return color.upper()


def _altium_color(value: str, name: str) -> int:
    color = _normalize_html_color(value, name)
    red, green, blue = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    return red + (green << 8) + (blue << 16)


def _run_easyeda_bridge_sync(payload: Dict[str, Any]) -> Dict[str, Any]:
    data = (json_dumps(payload) + "\n").encode("utf-8")
    try:
        handle = win32file.CreateFile(
            EASYEDA_PIPE,
            win32con.GENERIC_READ | win32con.GENERIC_WRITE,
            0,
            None,
            win32con.OPEN_EXISTING,
            0,
            None,
        )
    except Exception as exc:
        raise RuntimeError(
            "EasyEDA-Loader command bridge is unavailable. Build/install the current "
            "EasyEDA-Loader extension and keep Altium running."
        ) from exc
    try:
        win32file.WriteFile(handle, data)
        response = bytearray()
        while b"\n" not in response:
            _, chunk = win32file.ReadFile(handle, 65536)
            if not chunk:
                break
            response.extend(chunk)
        result = json.loads(bytes(response).split(b"\n", 1)[0].decode("utf-8"))
    finally:
        win32file.CloseHandle(handle)
    if not result.get("success", False):
        raise RuntimeError(result.get("message") or result.get("error") or "EasyEDA bridge command failed")
    return result


async def _run_easyeda_bridge(payload: Dict[str, Any]) -> Dict[str, Any]:
    return await asyncio.to_thread(_run_easyeda_bridge_sync, payload)


def _svg_dimensions_mm(svg_path: Path) -> tuple[float, float]:
    root = ET.parse(svg_path).getroot()
    dimensions = []
    for name in ("width", "height"):
        value = root.attrib.get(name, "").strip().lower()
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)mm", value)
        if not match:
            raise ValueError(f"SVG {name} must use millimetres: {svg_path}")
        dimensions.append(float(match.group(1)))
    return dimensions[0], dimensions[1]


def _find_edge() -> Path:
    candidates = [
        Path(os.environ.get("PROGRAMFILES(X86)", "")) / "Microsoft/Edge/Application/msedge.exe",
        Path(os.environ.get("PROGRAMFILES", "")) / "Microsoft/Edge/Application/msedge.exe",
        Path(os.environ.get("PROGRAMFILES", "")) / "Google/Chrome/Application/chrome.exe",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError("Microsoft Edge or Google Chrome is required to rasterize assembly SVG files")


def _recolor_svg(svg_path: Path, line_color: str, outline_color: str) -> None:
    text = svg_path.read_text(encoding="utf-8-sig")
    line_token = "__EASYEDA_ASSEMBLY_LINE_COLOR__"
    outline_token = "__EASYEDA_BOARD_OUTLINE_COLOR__"
    text = text.replace("#111111", line_token)
    text = text.replace("#555555", outline_token).replace("#000000", outline_token)
    text = text.replace(line_token, line_color).replace(outline_token, outline_color)
    svg_path.write_text(text, encoding="utf-8")


def _rasterize_svg_sync(svg_path: Path, png_path: Path, dpi: int) -> Dict[str, Any]:
    if dpi < 72 or dpi > 2400:
        raise ValueError("dpi must be between 72 and 2400")
    width_mm, height_mm = _svg_dimensions_mm(svg_path)
    width = max(1, math.ceil(width_mm * dpi / 25.4))
    height = max(1, math.ceil(height_mm * dpi / 25.4))
    if width > 32768 or height > 32768:
        raise ValueError(f"Requested raster is too large: {width}x{height}")
    tree = ET.parse(svg_path)
    root = tree.getroot()
    root.set("width", f"{width}px")
    root.set("height", f"{height}px")
    with tempfile.TemporaryDirectory(prefix="altium-svg-raster-") as temporary_directory:
        raster_svg = Path(temporary_directory) / svg_path.name
        tree.write(raster_svg, encoding="utf-8", xml_declaration=True)
        command = [
            str(_find_edge()),
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--default-background-color=00000000",
            "--force-device-scale-factor=1",
            f"--window-size={width},{height}",
            f"--screenshot={png_path}",
            raster_svg.as_uri(),
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if completed.returncode != 0 or not png_path.is_file():
        raise RuntimeError("SVG rasterization failed: " + (completed.stderr or completed.stdout).strip())
    with Image.open(png_path) as image:
        rgba = image.convert("RGBA")
        rgba.save(png_path, "PNG", dpi=(dpi, dpi))
        width, height = rgba.size
        alpha_extrema = rgba.getchannel("A").getextrema()
    return {
        "output_path": str(png_path),
        "width": width,
        "height": height,
        "dpi": dpi,
        "alpha_channel": True,
        "has_transparent_pixels": alpha_extrema[0] < 255,
        "file_size": png_path.stat().st_size,
    }


async def _rasterize_svg(svg_path: Path, png_path: Path, dpi: int) -> Dict[str, Any]:
    return await asyncio.to_thread(_rasterize_svg_sync, svg_path, png_path, dpi)


def _stamp_png_dpi_sync(png_path: Path, dpi: int) -> Dict[str, Any]:
    """Persist physical-resolution metadata without changing rendered pixels."""
    with Image.open(png_path) as image:
        rendered = image.copy()
        width, height = rendered.size
        alpha_channel = "A" in rendered.getbands()
        has_transparent_pixels = False
        if alpha_channel:
            has_transparent_pixels = rendered.getchannel("A").getextrema()[0] < 255
    rendered.save(png_path, "PNG", dpi=(dpi, dpi))
    return {
        "width": width,
        "height": height,
        "alpha_channel": alpha_channel,
        "has_transparent_pixels": has_transparent_pixels,
    }

class AltiumConfig:
    def __init__(self):
        self.altium_exe_path = ""
        self.script_path = str(DEFAULT_SCRIPT_PATH)
        self.load_config()
    
    def load_config(self):
        """Load configuration from file or create default if it doesn't exist"""
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    self.altium_exe_path = config.get("altium_exe_path", "")
                    self.script_path = config.get("script_path", str(DEFAULT_SCRIPT_PATH))
                logger.info(f"Loaded configuration from {CONFIG_FILE}")
            except Exception as e:
                logger.error(f"Error loading configuration: {e}")
                self._create_default_config()
        else:
            logger.info("No configuration file found, creating default")
            self._create_default_config()
    
    def _create_default_config(self):
        """Create a default configuration without opening any desktop UI."""
        self.altium_exe_path = self._discover_altium_executable() or ""
        self.save_config()

    @staticmethod
    def _discover_altium_executable() -> Optional[str]:
        """Find the active Altium installation using its installer registry data."""
        candidates = [os.environ.get("ALTIUM_EXE_PATH", "")]

        # Altium's current installer records each build here.  In particular,
        # ProgramsInstallPath supports installations outside C:\\Program Files.
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Altium\Builds") as builds:
                index = 0
                while True:
                    try:
                        build_name = winreg.EnumKey(builds, index)
                        index += 1
                    except OSError:
                        break
                    try:
                        with winreg.OpenKey(builds, build_name) as build:
                            installed = str(winreg.QueryValueEx(build, "Installed")[0]).lower()
                            install_dir = winreg.QueryValueEx(build, "ProgramsInstallPath")[0]
                        if installed == "true":
                            candidates.append(str(Path(install_dir) / "X2.EXE"))
                    except (FileNotFoundError, OSError):
                        continue
        except (ImportError, FileNotFoundError, OSError):
            pass

        # Legacy installer locations remain a useful fallback.
        for base_path in (Path(r"C:\Program Files\Altium"), Path(r"C:\Program Files (x86)\Altium")):
            candidates.append(str(base_path / "X2.EXE"))
            if base_path.is_dir():
                candidates.extend(str(directory / "X2.EXE") for directory in sorted(base_path.glob("AD*"), reverse=True))

        for candidate in candidates:
            if candidate and Path(candidate).is_file():
                return candidate
        return None
    
    def save_config(self):
        """Save configuration to file"""
        config = {
            "altium_exe_path": self.altium_exe_path,
            "script_path": self.script_path
        }
        
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(config, f, indent=2)
            logger.info(f"Saved configuration to {CONFIG_FILE}")
        except Exception as e:
            logger.error(f"Error saving configuration: {e}")
    
    def verify_paths(self):
        """Verify configuration without displaying native file-selection dialogs."""
        changed = False
        if not self.altium_exe_path or not Path(self.altium_exe_path).is_file():
            discovered_path = self._discover_altium_executable()
            if discovered_path:
                self.altium_exe_path = discovered_path
                changed = True
                logger.info("Automatically found Altium at: %s", discovered_path)
            else:
                logger.warning("Altium executable not found; script execution is disabled.")

        script_exists = Path(self.script_path).is_file()
        if not script_exists:
            logger.warning("Altium script project not found at: %s", self.script_path)

        if changed:
            self.save_config()
        return bool(self.altium_exe_path and Path(self.altium_exe_path).is_file() and script_exists)

class AltiumBridge:
    def __init__(self):
        # Ensure the MCP directory exists
        MCP_DIR.mkdir(exist_ok=True)
        
        # Load configuration
        self.config = AltiumConfig()
        self.config.verify_paths()
    
    async def execute_command(self, command: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a command in Altium via the bridge script"""
        try:
            # Clean up any existing response file
            if RESPONSE_FILE.exists():
                RESPONSE_FILE.unlink()
            
            # Write the request file with command and parameters
            with open(REQUEST_FILE, "w", encoding="utf-8-sig") as f:
                f.write(json_dumps({
                    "command": command,
                    **params  # Include parameters directly in the main JSON object
                }, indent=2))
            
            logger.info(f"Wrote request file for command: {command}")
            
            # Run the Altium script
            success = await self.run_altium_script()
            if not success:
                return {"success": False, "error": "Failed to run Altium script"}
            
            # Wait for the response file
            logger.info(f"Waiting for response file to appear...")
            timeout = 120  # seconds
            start_time = time.time()
            while not RESPONSE_FILE.exists() and time.time() - start_time < timeout:
                await asyncio.sleep(0.5)
            
            if not RESPONSE_FILE.exists():
                logger.error("Timeout waiting for response from Altium")
                return {"success": False, "error": "No response received from Altium (timeout)"}
            
            # Read the response file and print it for debugging
            logger.info("Response file found, reading response")
            response_text = ""
            with open(RESPONSE_FILE, "r") as f:
                response_text = f.read()
            
            # Log the raw response for debugging
            logger.info(f"Raw response (first 200 chars): {response_text[:200]}")
            
            # Parse the JSON response with detailed error handling
            try:
                response = json.loads(response_text)
                logger.info(f"Successfully parsed JSON response")
                return response
            except json.JSONDecodeError as e:
                logger.error(f"Error parsing JSON response: {e}")
                logger.error(f"Error at position {e.pos}, line {e.lineno}, column {e.colno}")
                logger.error(f"Character at error position: '{response_text[e.pos:e.pos+10]}...'")
                
                # Try to manually fix common JSON issues
                logger.info("Attempting to fix JSON response...")
                fixed_text = response_text
                
                # Fix 1: If there's a quoted JSON array, try to fix it
                if '"[' in fixed_text and ']"' in fixed_text:
                    fixed_text = fixed_text.replace('"[', '[').replace(']"', ']')
                    logger.info("Fixed double-quoted JSON array")
                
                # Fix 2: Handle escaped quotes in JSON strings
                fixed_text = fixed_text.replace('\\"', '"')
                
                # Try to parse the fixed JSON
                try:
                    fixed_response = json.loads(fixed_text)
                    logger.info("Successfully parsed fixed JSON response")
                    return fixed_response
                except json.JSONDecodeError as e2:
                    logger.error(f"Still failed to parse JSON after fixes: {e2}")
                
                # If all else fails, return a structured error
                return {
                    "success": False, 
                    "error": f"Invalid JSON response: {e}",
                    "raw_response": response_text[:500]  # Include part of the raw response for diagnosis
                }
        
        except Exception as e:
            logger.error(f"Error executing command: {e}")
            return {"success": False, "error": str(e)}
    
    @staticmethod
    def _resolve_msix_path(virtual_path: str) -> str:
        """Resolve an MSIX-virtualized path to the real filesystem path.

        When Claude Desktop is installed via MSIX (the standard .exe installer
        on modern Windows), file paths are virtualized under AppData\\Roaming\\
        but the real files live at AppData\\Local\\Packages\\Claude_*\\
        LocalCache\\Roaming\\. Child processes of the MSIX app (like Python)
        can see the virtualized paths, but external apps (like Altium) cannot.
        This resolves the path so external processes can find the files.
        """
        appdata = os.environ.get('APPDATA', '')
        if not appdata or not virtual_path.startswith(appdata):
            return virtual_path

        localappdata = os.environ.get('LOCALAPPDATA', '')
        packages_dir = os.path.join(localappdata, 'Packages')
        if not os.path.isdir(packages_dir):
            return virtual_path

        try:
            for item in os.listdir(packages_dir):
                if item.startswith('Claude_'):
                    relative = os.path.relpath(virtual_path, appdata)
                    real_path = os.path.join(packages_dir, item, 'LocalCache', 'Roaming', relative)
                    if os.path.exists(real_path):
                        logger.info(f"Resolved MSIX path: {virtual_path} -> {real_path}")
                        return real_path
        except Exception as e:
            logger.warning(f"Error resolving MSIX path: {e}")

        return virtual_path

    async def run_altium_script(self) -> bool:
        """Run the Altium bridge script"""
        if not os.path.exists(self.config.altium_exe_path):
            logger.error(f"Altium executable not found at: {self.config.altium_exe_path}")
            print(f"Error: Altium executable not found. Please check the configuration.")
            return False

        if not os.path.exists(self.config.script_path):
            logger.error(f"Script file not found at: {self.config.script_path}")
            print(f"Error: Script file not found. Please check the configuration.")
            return False

        try:
            # Resolve MSIX-virtualized path so Altium (an external process
            # outside the MSIX sandbox) can find the script files
            script_path = self._resolve_msix_path(self.config.script_path)

            # Command format: "X2.EXE" -RScriptingSystem:RunScript(ProjectName="path\file.PrjScr"|ProcName="ModuleName.pas>Run")
            command = f'"{self.config.altium_exe_path}" -RScriptingSystem:RunScript(ProjectName="{script_path}"^|ProcName="Altium_API.pas>Run")'
            
            logger.info(f"Running command: {command}")
            
            # Start the process
            process = subprocess.Popen(command, shell=True)
            
            # Don't wait for completion - Altium will run the script and generate the response
            logger.info(f"Launched Altium with script, process ID: {process.pid}")
            return True
        
        except Exception as e:
            logger.error(f"Error launching Altium: {e}")
            return False

# Create a global bridge instance
altium_bridge = AltiumBridge()

@mcp.tool()
async def get_all_component_property_names(ctx: Context) -> str:
    """
    Get all available component property names (JSON keys) from all components
    
    Returns:
        str: JSON array with all unique property names
    """
    logger.info("Getting all component property names")
    
    # Execute the command in Altium to get component data
    response = await altium_bridge.execute_command(
        "get_all_component_data", 
        {}
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting component data: {error_msg}")
        return json_dumps({"error": f"Failed to get component data: {error_msg}"})
    
    # Get the component data
    components_data = response.get("result", [])
    
    if not components_data:
        logger.info("No component data found")
        return json_dumps({"error": "No component data found"})
    
    try:
        # Parse the data if it's a string
        if isinstance(components_data, str):
            components_list = json.loads(components_data)
        else:
            components_list = components_data
            
        # Extract all unique property names from all components
        property_names = set()
        for component in components_list:
            property_names.update(component.keys())
        
        # Convert set to sorted list for consistent output
        property_list = sorted(list(property_names))
        
        logger.info(f"Found {len(property_list)} unique property names")
        return json_dumps(property_list, indent=2)
    except Exception as e:
        logger.error(f"Error processing component data: {e}")
        return json_dumps({"error": f"Failed to process component data: {str(e)}"})

@mcp.tool()
async def get_component_property_values(ctx: Context, property_name: str) -> str:
    """
    Get values of a specific property for all components
    
    Args:
        property_name (str): The name of the property to get values for
    
    Returns:
        str: JSON array with objects containing designator and property value
    """
    logger.info(f"Getting values for property: {property_name}")
    
    # Execute the command in Altium to get component data
    response = await altium_bridge.execute_command(
        "get_all_component_data", 
        {}
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting component data: {error_msg}")
        return json_dumps({"error": f"Failed to get component data: {error_msg}"})
    
    # Get the component data
    components_data = response.get("result", [])
    
    if not components_data:
        logger.info("No component data found")
        return json_dumps({"error": "No component data found"})
    
    try:
        # Parse the data if it's a string
        if isinstance(components_data, str):
            components_list = json.loads(components_data)
        else:
            components_list = components_data
            
        # Extract the property values along with designators
        property_values = []
        for component in components_list:
            designator = component.get("designator")
            if designator and property_name in component:
                property_values.append({
                    "designator": designator,
                    "value": component.get(property_name)
                })
        
        logger.info(f"Found {len(property_values)} components with property '{property_name}'")
        return json_dumps(property_values, indent=2)
    except Exception as e:
        logger.error(f"Error processing component data: {e}")
        return json_dumps({"error": f"Failed to process component data: {str(e)}"})
    
@mcp.tool()
async def get_symbol_placement_rules(ctx: Context) -> str:
    """
    Get schematic symbol placement rules from a local configuration file
    
    Returns:
        str: JSON object with rules for placing pins on schematic symbols
    """
    logger.info("Getting symbol placement rules")
    
    # Define the rules file path in the MCP directory
    rules_file_path = MCP_DIR / "symbol_placement_rules.txt"
    
    # Check if the rules file exists
    if not rules_file_path.exists():
        logger.info("Symbol placement rules file not found, suggesting creation")
        
        # Default rules content
        default_rules = (
            "Only place pins on the left and right side of the symbol. "
            "Place power rail pins at the upper right, ground pins in the bottom left, "
            "no connect pins in the bottom right, inputs on the left, outputs on the right, "
            "and try to group other pins together by similar functionality (for example, SPI, I2C, RGMII, etc.). "
            "Always separate groups by 100mil gaps unless there is extra spacing, then space out groups equal distance from each other. "
        )
        
        # Create a helpful message for the user
        message = {
            "success": False,
            "error": f"Rules file not found at: {rules_file_path}",
            "message": f"Let the user know that they can optionally update the file {rules_file_path} with custom symbol placement rules. "
                      f"Suggested content: {default_rules}"
        }
        
        return json_dumps(message, indent=2)
    
    # Read the rules file if it exists
    try:
        with open(rules_file_path, "r") as f:
            rules_content = f.read()
        
        logger.info("Successfully read symbol placement rules file")
        
        # Return the rules with a message about how to modify them
        result = {
            "success": True,
            "message": f"Modify {rules_file_path} with custom symbol placement instructions",
            "rules": rules_content
        }
        
        return json_dumps(result, indent=2)
        
    except Exception as e:
        logger.error(f"Error reading symbol placement rules file: {e}")
        return json_dumps({
            "success": False,
            "error": f"Failed to read rules file: {str(e)}"
        }, indent=2)

@mcp.tool()
async def get_library_symbol_reference(ctx: Context) -> str:
    """
    Get the currently open symbol from a schematic library to use as reference for creating a new symbol.
    This tool should be used before creating a new symbol to understand the structure of existing symbols.
    
    Returns:
        str: JSON object with the reference symbol data including pins, their types, positions, and orientations
    """
    logger.info("Getting library symbol reference data")
    
    # Execute the command in Altium to get symbol reference data
    response = await altium_bridge.execute_command(
        "get_library_symbol_reference", 
        {}
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting symbol reference: {error_msg}")
        return json_dumps({"error": f"Failed to get symbol reference: {error_msg}"}, ensure_ascii=False)
    
    # Get the symbol reference data
    symbol_data = response.get("result", {})
    
    if not symbol_data:
        logger.info("No symbol reference data found")
        return json_dumps({"error": "No symbol reference data found or no symbol is currently selected in the library"}, ensure_ascii=False)
    
    logger.info(f"Retrieved symbol reference data")
    return json_dumps(symbol_data, indent=2, ensure_ascii=False)

@mcp.tool()
async def get_library_symbol_primitive_font_dump(ctx: Context) -> str:
    """
    Return a read-only primitive and font dump for the currently open schematic library symbol.

    The active SchLib document must be focused in Altium. This inspects the active
    in-memory library component through Altium's schematic API; it does not read
    .SchLib files directly from disk.

    Returns:
        str: JSON object with component metadata, pins, text primitives, drawing primitives,
             and FontManager-resolved font records for text-bearing primitives.
    """
    logger.info("Getting library symbol primitive/font dump")

    response = await altium_bridge.execute_command(
        "get_library_symbol_primitive_font_dump",
        {}
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting symbol primitive/font dump: {error_msg}")
        return json_dumps({"error": f"Failed to get symbol primitive/font dump: {error_msg}"}, ensure_ascii=False)

    symbol_data = response.get("result", {})

    if not symbol_data:
        logger.info("No symbol primitive/font dump returned")
        return json_dumps({"error": "No symbol primitive/font dump returned or no symbol is currently selected in the library"}, ensure_ascii=False)

    logger.info("Retrieved symbol primitive/font dump")
    return json_dumps(symbol_data, indent=2, ensure_ascii=False)

@mcp.tool()
async def search_library_symbol(ctx: Context, symbol_name: str, library_path: str = "") -> str:
    """
    Search for a symbol by name in a schematic library (.SchLib) and navigate to it.
    Supports partial name matching (case-insensitive). Returns all matches and navigates
    to the best match (exact match preferred, otherwise first partial match).

    This tool will automatically open the library file in Altium if a path is provided,
    so no SchLib needs to be open beforehand.

    Args:
        symbol_name (str): Name or partial name of the symbol to search for
        library_path (str): Full file path to the .SchLib file (e.g. "N:\\Libs\\Integrated_Circuits.SchLib").
                           The tool will open this file in Altium if it is not already open.
                           If empty, uses the currently open library.
                           If no library is open and no path is provided, ask the user for the file path.

    Returns:
        str: JSON object with search results including matches, navigated symbol, and full symbol list
    """
    logger.info(f"Searching for symbol: {symbol_name} in library: {library_path or '(current)'}")

    # Execute the command in Altium
    params = {"symbol_name": symbol_name}
    if library_path:
        params["library_path"] = library_path

    response = await altium_bridge.execute_command(
        "search_library_symbol",
        params
    )

    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error searching for symbol: {error_msg}")
        return json_dumps({"error": f"Failed to search for symbol: {error_msg}"})

    # Get the result data
    result = response.get("result", {})

    if not result:
        logger.info("No search results returned")
        return json_dumps({"error": "No results returned from symbol search"})

    logger.info(f"Symbol search complete. Found: {result.get('found', False)}")
    return json_dumps(result, indent=2)

@mcp.tool()
async def create_schematic_symbol(ctx: Context, symbol_name: str, description: str, pins: list, part_count: int = 1) -> str:
    r"""
    Before executing, run get_symbol_placement_rules first.
    Create a new schematic symbol in the current library with the specified pins
    This tool does not save the schematic library document; leave it dirty for
    user inspection unless the user explicitly asks to save.
    Instructions: pins should be grouped together via function and only placed on
                  the left and right side in 100 mil increments

    Pin name inversion/overbar: To show an overbar on a pin name (for active-low signals),
                  place a backslash after EACH character that should be overbarred.
                  Examples: R\E\S\E\T\ renders as RESET with overbar.
                           C\S\/A0 renders as CS with overbar followed by /A0 without overbar.
                  Do NOT use ~{...} or other notation — only the backslash-per-character format works in Altium.

    Args:
        symbol_name (str): Name of the symbol to create
        description (str): Description of the schematic symbol
        pins (list): List of pin data in format ["pin_number|pin_name|pin_type|pin_orientation|x|y|owner_part_id", ...]
                    Pin types: eElectricHiZ, eElectricInput, eElectricIO, eElectricOpenCollector,
                               eElectricOpenEmitter, eElectricOutput, eElectricPassive, eElectricPower
                    Pin orientations: eRotate0 (right), eRotate90 (down), eRotate180 (left), eRotate270 (up)
                    X,Y coordinates in mils. The Altium script snaps generated
                    symbol primitives to the configured 2.5 mm schematic grid.
                    When a reference library component is open, generated pins and
                               primitives copy reference styling, including pin length,
                               font settings, line width, and colours.
                    owner_part_id (optional): Part number the pin belongs to (1-based).
                               Use 0 for pins shared across all parts (e.g. power/GND).
                               Defaults to 1 if omitted. Only needed for multi-part symbols.
                    Metadata entries may be included, e.g. GroupDelimiter=LEFT|-12.5,
                               GroupDelimiter=RIGHT|-17.5, GroupDelimiter=BOTH|-42.5,
                               GroupDelimiter=FULL|-20.0, or GroupDelimiter=CENTER|-20.0.
                               GroupDelimiter Y values are in mm and snap to the 2.5 mm grid.
                               CenterLabel=<functional text> adds centered graphical label text,
                               split into two centered lines at a word break when needed.
                               CenterLabelPosition=TOPCENTER places it near the body top; CENTER
                               places it in the middle section between vertical dividers.
                               VerticalSeparators=True forces left/center/right divider lines.
                               Use Designator=XP? or similar to override the copied reference designator.
                               Component properties and model links may also be populated with
                               Comment=<symbol_name>, Manufacturer=<name>,
                               Parameter=PartNumber|=Comment, Parameter=ValueType|Микросхема,
                               Parameter=<custom_name>|<custom_value_or_blank>,
                               Footprint=<footprint_name>, FootprintLibrary=<library_name_or_path>,
                               and PinDescription=<pin>|<datasheet description>.
        part_count (int): Number of parts in the symbol (default 1).
                         Use >1 for multi-part symbols like quad op-amps or hex buffers.

    Returns:
        str: JSON object with the result of the component creation
    """
    logger.info(f"Creating schematic symbol: {symbol_name} with {len(pins)} pins, {part_count} part(s)")

    # Execute the command in Altium to create a symbol with pins
    response = await altium_bridge.execute_command(
        "create_schematic_symbol",
        {
            "symbol_name": symbol_name,
            "description": description,
            "part_count": part_count,
            "pins": pins
        }
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error creating symbol: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to create symbol: {error_msg}"})
    
    # Get the result data
    result = response.get("result", {})
    
    logger.info(f"Symbol {symbol_name} created successfully with {len(pins)} pins")
    return json_dumps(result, indent=2)

@mcp.tool()
async def get_schematic_data(ctx: Context, cmp_designators: list) -> str:
    """
    Get schematic data for components in Altium
    
    Args:
        cmp_designators (list): List of designators of the components (e.g., ["R1", "C5", "U3"])
    
    Returns:
        str: JSON object with schematic component data for requested designators
    """
    logger.info(f"Getting schematic data for components: {cmp_designators}")
    
    # Execute the command in Altium to get schematic data
    response = await altium_bridge.execute_command(
        "get_schematic_data",
        {}  # No parameters needed for this command in the Altium script
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting schematic data: {error_msg}")
        return json_dumps({"error": f"Failed to get schematic data: {error_msg}"})
    
    # Get the schematic data
    schematic_data = response.get("result", [])
    
    if not schematic_data:
        logger.info("No schematic data found")
        return json_dumps({"error": "No schematic data found"})
    
    try:
        # Parse the data if it's a string
        if isinstance(schematic_data, str):
            schematic_list = json.loads(schematic_data)
        else:
            schematic_list = schematic_data
        
        # Filter components by designator
        components = []
        missing_designators = []
        
        for designator in cmp_designators:
            found = False
            for component in schematic_list:
                if component.get("designator") == designator:
                    components.append(component)
                    found = True
                    break
            
            if not found:
                missing_designators.append(designator)
        
        result = {
            "components": components,
        }
        
        if missing_designators:
            result["missing_designators"] = missing_designators
            logger.info(f"Some designators not found in schematic data: {missing_designators}")
        
        logger.info(f"Found schematic data for {len(components)} components")
        return json_dumps(result, indent=2)
    except Exception as e:
        logger.error(f"Error processing schematic data: {e}")
        return json_dumps({"error": f"Failed to process schematic data: {str(e)}"})
    
@mcp.tool()
async def get_pcb_layers(ctx: Context) -> str:
    """
    Get detailed information about all layers in the current Altium PCB
    
    Returns:
        str: JSON object with detailed layer information including copper layers, 
             mechanical layers, and special layers with their properties
    """
    logger.info("Getting detailed PCB layer information")
    
    # Execute the command in Altium to get all layers data
    response = await altium_bridge.execute_command(
        "get_pcb_layers",
        {}  # No parameters needed
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting PCB layers: {error_msg}")
        return json_dumps({"error": f"Failed to get PCB layers: {error_msg}"})
    
    # Get the layers data
    layers_data = response.get("result", [])
    
    if not layers_data:
        logger.info("No PCB layers found")
        return json_dumps({"message": "No PCB layers found in the current document"})
    
    logger.info(f"Retrieved PCB layers data")
    return json_dumps(layers_data, indent=2)

@mcp.tool()
async def set_pcb_layer_visibility(ctx: Context, layer_names: list, visible: bool) -> str:
    """
    Set visibility for specified PCB layers
    
    Args:
        layer_names (list): List of layer names to modify (e.g., ["Top Layer", "Bottom Layer", "Mechanical 1"])
        visible (bool): Whether to show (True) or hide (False) the specified layers
        
    Returns:
        str: JSON object with the result of the operation
    """
    logger.info(f"Setting layers visibility: {layer_names} to {visible}")
    
    # Execute the command in Altium to set layer visibility
    response = await altium_bridge.execute_command(
        "set_pcb_layer_visibility",
        {
            "layer_names": layer_names,
            "visible": visible
        }
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error setting layer visibility: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to set layer visibility: {error_msg}"})
    
    # Get the result data
    result = response.get("result", {})
    
    logger.info(f"Layer visibility set successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def set_pcb_layer_names_by_id(ctx: Context, layer_names_by_id: list) -> str:
    """
    Rename PCB copper or mechanical layers by numeric layer ID.
    Use get_pcb_layers first to read current layer_id values.

    Args:
        layer_names_by_id (list): Rename specs in "layer_id|new name" format,
                                  e.g. ["1|Top Layer", "4|Int2 DDR", "32|Bottom Layer"].

    Returns:
        str: JSON object with updated_count and not_found_layer_ids.
    """
    logger.info(f"Renaming PCB layers by id: {layer_names_by_id}")

    response = await altium_bridge.execute_command(
        "set_pcb_layer_names_by_id",
        {"layer_names_by_id": layer_names_by_id}
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error renaming PCB layers: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to rename PCB layers: {error_msg}"})

    result = response.get("result", {})

    logger.info("PCB layer names updated successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def clear_pcb_route_tool_path_layer(ctx: Context) -> str:
    """
    Clear the PCB route-tool-path layer override.

    This is separate from normal layer-stack names. When set, Altium can display
    the selected copper layer as "Route Tool Path" even if the layer stack name
    should be "Top Layer", "Bottom Layer", etc.

    Returns:
        str: JSON object with the result of the operation.
    """
    logger.info("Clearing PCB route tool path layer override")

    response = await altium_bridge.execute_command(
        "clear_pcb_route_tool_path_layer",
        {}
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error clearing route tool path layer: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to clear route tool path layer: {error_msg}"})

    result = response.get("result", {})

    logger.info("PCB route tool path layer override cleared successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def get_component_data(ctx: Context, cmp_designators: list) -> str:
    """
    Get all data for components in Altium
    
    Args:
        cmp_designators (list): List of designators of the components (e.g., ["R1", "C5", "U3"])
    
    Returns:
        str: JSON object with all component data for requested designators
    """
    logger.info(f"Getting data for components: {cmp_designators}")
    
    # Execute the command in Altium to get all component data
    response = await altium_bridge.execute_command(
        "get_all_component_data",
        {}  # No parameters needed for this command in the Altium script
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting component data: {error_msg}")
        return json_dumps({"error": f"Failed to get component data: {error_msg}"})
    
    # Get the component data
    component_data = response.get("result", [])
    
    if not component_data:
        logger.info("No component data found")
        return json_dumps({"error": "No component data found"})
    
    try:
        # Parse the data if it's a string
        if isinstance(component_data, str):
            component_list = json.loads(component_data)
        else:
            component_list = component_data
        
        # Filter components by designator
        components = []
        missing_designators = []
        
        for designator in cmp_designators:
            found = False
            for component in component_list:
                if component.get("designator") == designator:
                    components.append(component)
                    found = True
                    break
            
            if not found:
                missing_designators.append(designator)
        
        result = {
            "components": components,
        }
        
        if missing_designators:
            result["missing_designators"] = missing_designators
            logger.info(f"Some designators not found: {missing_designators}")
        
        logger.info(f"Found data for {len(components)} components")
        return json_dumps(result, indent=2)
    except Exception as e:
        logger.error(f"Error processing component data: {e}")
        return json_dumps({"error": f"Failed to process component data: {str(e)}"})

@mcp.tool()
async def get_selected_components_coordinates(ctx: Context) -> str:
    """
    Get coordinates and positioning information for selected components in Altium layout
    
    Returns:
        str: JSON array with positioning data (designator, x, y, rotation, width, height)
    """
    logger.info("Getting coordinates for selected components")
    
    # Execute the command in Altium to get selected components coordinates
    response = await altium_bridge.execute_command(
        "get_selected_components_coordinates",
        {}  # No parameters needed
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting selected components coordinates: {error_msg}")
        return json_dumps({"error": f"Failed to get selected components coordinates: {error_msg}"})
    
    # Get the components coordinates data
    components_coords = response.get("result", [])
    
    if not components_coords:
        logger.info("No selected components found")
        return json_dumps({"message": "No components are currently selected in the layout"})
    
    logger.info(f"Retrieved positioning data for selected components")
    return json_dumps(components_coords, indent=2)

@mcp.tool()
async def get_all_designators(ctx: Context) -> str:
    """
    Get all component designators from the current Altium board
    
    Returns:
        str: JSON array of all component designators on the current board
    """
    logger.info("Getting all component designators")
    
    # Execute the command in Altium to get all component data
    response = await altium_bridge.execute_command(
        "get_all_component_data",
        {}  # No parameters needed
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting component data: {error_msg}")
        return json_dumps({"error": f"Failed to get component data: {error_msg}"})
    
    # Get the component data
    component_data = response.get("result", [])
    
    if not component_data:
        logger.info("No component data found")
        return json_dumps({"error": "No component data found"})
    
    try:
        # Parse the data if it's a string
        if isinstance(component_data, str):
            component_list = json.loads(component_data)
        else:
            component_list = component_data
        
        # Extract designators
        designators = [comp.get("designator") for comp in component_list if "designator" in comp]
        
        logger.info(f"Found {len(designators)} designators")
        return json_dumps(designators)
    except Exception as e:
        logger.error(f"Error processing component data: {e}")
        return json_dumps({"error": f"Failed to process component data: {str(e)}"})

@mcp.tool()
async def get_component_pins(ctx: Context, cmp_designators: list) -> str:
    """
    Get pin data for components in Altium
    
    Args:
        cmp_designators (list): List of designators of the components (e.g., ["R1", "C5", "U3"])
    
    Returns:
        str: JSON object with pin data for requested designators
    """
    logger.info(f"Getting pin data for components: {cmp_designators}")
    
    # Execute the command in Altium to get pin data
    response = await altium_bridge.execute_command(
        "get_component_pins",
        {"designators": cmp_designators}  # Pass the list of designators
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting pin data: {error_msg}")
        return json_dumps({"error": f"Failed to get pin data: {error_msg}"})
    
    # Get the components pins data
    pins_data = response.get("result", [])
    
    if not pins_data:
        logger.info(f"No pin data found for designators: {cmp_designators}")
        return json_dumps({"message": "No pin data found for the specified components"})
    
    logger.info(f"Retrieved pin data for components")
    return json_dumps(pins_data, indent=2)

@mcp.tool()
async def get_all_nets(ctx: Context) -> str:
    """
    Return every unique net name in the active PCB document.

    Returns
    -------
    str :
        A JSON array of net names, e.g. ["GND", "VCC33", "USB_D+", ...]
    """
    logger.info("Getting all nets")

    response = await altium_bridge.execute_command("get_all_nets", {})

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting nets: {error_msg}")
        return json_dumps({"error": f"Failed to get nets: {error_msg}"})

    # Result is already a JSON‑serialisable Python list
    return json_dumps(response.get("result", []), indent=2)

@mcp.tool()
async def create_net_class(ctx: Context, class_name: str, net_names: list) -> str:
    """
    Create a new net class and add specified nets to it
    
    Args:
        class_name (str): Name of the net class to create or modify
        net_names (list): List of net names to add to the class
    
    Returns:
        str: JSON object with the result of the operation
    """
    logger.info(f"Creating net class '{class_name}' with {len(net_names)} nets")
    
    # Execute the command in Altium to create the net class
    response = await altium_bridge.execute_command(
        "create_net_class",
        {
            "class_name": class_name,
            "net_names": net_names
        }
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error creating net class: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to create net class: {error_msg}"})
    
    # Get the result data
    result = response.get("result", {})
    
    logger.info(f"Net class '{class_name}' created/modified successfully")
    return json_dumps(result, indent=2)
    
@mcp.tool()
async def set_component_position(ctx: Context, cmp_designator: str, x: float, y: float, rotation: float = -1) -> str:
    """
    Set a component's absolute position in the PCB layout
    
    Args:
        cmp_designator (str): Designator of the component to position (e.g., "R1", "C5", "U3")
        x (float): Absolute X position in mils
        y (float): Absolute Y position in mils
        rotation (float): Rotation angle in degrees (0-360), use -1 to keep current rotation
    
    Returns:
        str: JSON object with the result of the position operation
    """
    logger.info(f"Setting component {cmp_designator} position to X:{x}, Y:{y}, Rotation:{rotation}")
    
    response = await altium_bridge.execute_command(
        "set_component_position",
        {
            "designator": cmp_designator,
            "x": x,
            "y": y,
            "rotation": rotation
        }
    )
    
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error setting component position: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to set component position: {error_msg}"})
    
    result = response.get("result", {})
    logger.info(f"Component position set successfully")
    return json_dumps({"success": True, "result": result}, indent=2)

@mcp.tool()
async def move_components(ctx: Context, cmp_designators: list, x_offset: float, y_offset: float, rotation: float = 0) -> str:
    """
    Move components by RELATIVE offset from their current position (not absolute positioning)
    
    IMPORTANT: This moves components BY the offset amount, not TO a position.
    For absolute positioning, use set_component_position instead.
    
    Args:
        cmp_designators (list): List of designators of the components to move (e.g., ["R1", "C5", "U3"])
        x_offset (float): X offset distance in mils (positive = right, negative = left)
        y_offset (float): Y offset distance in mils (positive = up, negative = down)
        rotation (float): New absolute rotation angle in degrees (0-360), if 0 the rotation is not changed
    
    Returns:
        str: JSON object with the result of the move operation
    """
    logger.info(f"Moving components: {cmp_designators} by X:{x_offset}, Y:{y_offset}, Rotation:{rotation}")
    
    # Execute the command in Altium to move components
    response = await altium_bridge.execute_command(
        "move_components",
        {
            "designators": cmp_designators,
            "x_offset": x_offset,
            "y_offset": y_offset,
            "rotation": rotation
        }
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error moving components: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to move components: {error_msg}"})
    
    # Get the result data
    result = response.get("result", {})
    
    logger.info(f"Components moved successfully")
    return json_dumps({"success": True, "result": result}, indent=2)

@mcp.tool()
async def get_screenshot(ctx: Context, view_type: str = "pcb") -> str:
    """
    Take a screenshot of the Altium window
    
    Args:
        view_type (str): Type of view to capture - 'pcb' or 'sch'
    
    Returns:
        str: JSON object with screenshot data (base64 encoded) and metadata
    """
    logger.info(f"Taking screenshot of Altium {view_type} window")
    
    try:
        # First, execute the Altium command to ensure the right document type is focused
        response = await altium_bridge.execute_command(
            "take_view_screenshot", 
            {"view_type": view_type.lower()}
        )
        
        # Check for success
        if not response.get("success", False):
            error_msg = response.get("error", "Unknown error")
            logger.error(f"Error focusing {view_type} document: {error_msg}")
            return json_dumps({"success": False, "error": f"Failed to focus the correct document type: {error_msg}"})
        
        # Run the screenshot capture in a separate thread
        import threading
        import queue
        import datetime
        from PIL import Image
        
        result_queue = queue.Queue()
        
        def capture_screenshot_thread():
            try:
                # Find Altium windows
                altium_windows = []
                altium_fallback_windows = []
                
                def collect_altium_windows(hwnd, _):
                    if win32gui.IsWindowVisible(hwnd):
                        title = win32gui.GetWindowText(hwnd)
                        
                        # First, look for windows with Altium and .PrjPcb in the title
                        if "Altium" in title and ".PrjPcb" in title:
                            altium_windows.append({
                                "handle": hwnd,
                                "title": title,
                                "class_name": win32gui.GetClassName(hwnd),
                                "rect": win32gui.GetWindowRect(hwnd)
                            })
                        # Collect any window with Altium in the title as fallback
                        elif "Altium" in title:
                            altium_fallback_windows.append({
                                "handle": hwnd,
                                "title": title,
                                "class_name": win32gui.GetClassName(hwnd),
                                "rect": win32gui.GetWindowRect(hwnd)
                            })
                    return True
                
                win32gui.EnumWindows(collect_altium_windows, 0)
                
                # If no specific Altium .PrjPcb windows found, use the fallback
                if not altium_windows and altium_fallback_windows:
                    altium_windows = altium_fallback_windows
                
                if not altium_windows:
                    result_queue.put({
                        "success": False, 
                        "error": f"No Altium windows found for {view_type} view"
                    })
                    return
                
                # Use the first matching window
                window = altium_windows[0]
                hwnd = window["handle"]
                
                # Get window dimensions
                left, top, right, bottom = window["rect"]
                width = right - left
                height = bottom - top
                
                if width <= 0 or height <= 0:
                    result_queue.put({"success": False, "error": f"Invalid window dimensions: {width}x{height}"})
                    return
                
                # Try to activate the window
                try:
                    win32gui.SetForegroundWindow(hwnd)
                    time.sleep(0.5)
                except Exception as e:
                    logger.warning(f"Could not bring window to foreground: {e}")
                
                # Take screenshot using GDI functions instead of ImageGrab
                try:
                    # Get device context
                    hwndDC = win32gui.GetWindowDC(hwnd)
                    mfcDC = win32ui.CreateDCFromHandle(hwndDC)
                    saveDC = mfcDC.CreateCompatibleDC()
                    
                    # Create a bitmap object
                    saveBitMap = win32ui.CreateBitmap()
                    saveBitMap.CreateCompatibleBitmap(mfcDC, width, height)
                    saveDC.SelectObject(saveBitMap)
                    
                    # Copy the screen into the bitmap
                    saveDC.BitBlt((0, 0), (width, height), mfcDC, (0, 0), win32con.SRCCOPY)
                    
                    # Convert the bitmap to an Image
                    bmpinfo = saveBitMap.GetInfo()
                    bmpstr = saveBitMap.GetBitmapBits(True)
                    img = Image.frombuffer(
                        'RGB',
                        (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                        bmpstr, 'raw', 'BGRX', 0, 1)
                    
                    # Save a local copy of the screenshot for debugging (non-fatal if it fails)
                    try:
                        debug_filename = str(MCP_DIR / f"screenshot_{view_type}.png")
                        img.save(debug_filename)
                        logger.info(f"Saved debug screenshot to {debug_filename}")
                    except Exception as save_error:
                        logger.warning(f"Could not save debug screenshot to {debug_filename}: {save_error}")
                        debug_filename = None  # Clear it since save failed
                    
                    # Clean up GDI resources
                    win32gui.DeleteObject(saveBitMap.GetHandle())
                    saveDC.DeleteDC()
                    mfcDC.DeleteDC()
                    win32gui.ReleaseDC(hwnd, hwndDC)
                    
                    # Convert to base64
                    buffer = io.BytesIO()
                    img.save(buffer, format='PNG')
                    buffer.seek(0)
                    img_base64 = base64.b64encode(buffer.read()).decode('utf-8')
                    
                    # Put result in queue
                    result_queue.put({
                        "success": True,
                        "width": width,
                        "height": height,
                        "window_title": window["title"],
                        "window_class": window["class_name"],
                        "view_type": view_type,
                        "image_format": "PNG",
                        "encoding": "base64",
                        "debug_file": debug_filename,
                        "image_data": img_base64
                    })
                    
                except Exception as e:
                    import traceback
                    trace = traceback.format_exc()
                    logger.error(f"GDI screenshot error: {e}\n{trace}")
                    result_queue.put({
                        "success": False, 
                        "error": f"GDI screenshot failed: {str(e)}",
                        "traceback": trace
                    })
                
            except Exception as e:
                import traceback
                result_queue.put({
                    "success": False, 
                    "error": f"Screenshot thread error: {str(e)}",
                    "traceback": traceback.format_exc()
                })
        
        # Start the thread
        thread = threading.Thread(target=capture_screenshot_thread)
        thread.daemon = True
        thread.start()
        
        # Wait for the thread to complete
        thread.join(timeout=10)  # 10 second timeout
        
        if thread.is_alive():
            logger.error("Screenshot thread timed out")
            return json_dumps({"success": False, "error": "Screenshot operation timed out"})
        
        # Get the result from the queue
        if result_queue.empty():
            logger.error("Screenshot thread did not return a result")
            return json_dumps({"success": False, "error": "Screenshot thread did not return a result"})
        
        result = result_queue.get()
        
        if not result.get("success", False):
            error_msg = result.get("error", "Unknown error")
            logger.error(f"Screenshot error: {error_msg}")
            return json_dumps({"success": False, "error": error_msg})
        
        logger.info(f"Screenshot taken successfully, size: {result['width']}x{result['height']}")
        return json_dumps(result)
    
    except Exception as e:
        logger.error(f"Error in screenshot function: {str(e)}")
        return json_dumps({"success": False, "error": f"Failed to take screenshot: {str(e)}"})

def _pcb_3d_color_params(
    workspace_color: Optional[str],
    board_color: Optional[str],
    solder_mask_color: Optional[str],
    silk_color: Optional[str],
    copper_color: Optional[str],
) -> Dict[str, Any]:
    colors = {
        "workspace_color": workspace_color,
        "board_color": board_color,
        "solder_mask_color": solder_mask_color,
        "silk_color": silk_color,
        "copper_color": copper_color,
    }
    supplied = {name: value for name, value in colors.items() if value}
    result: Dict[str, Any] = {"use_system_colors": not bool(supplied)}
    for name, value in supplied.items():
        result[name] = _altium_color(value, name)
    return result


async def _export_one_pcb_3d_image(
    target: Path,
    side: str,
    dpi: int,
    color_params: Dict[str, Any],
) -> Dict[str, Any]:
    response = await _run_easyeda_bridge({
        "command": "export-board-3d",
        "output_path": str(target),
        "side": side,
        "dpi": dpi,
        **color_params,
    })
    if not target.is_file():
        raise RuntimeError("Altium returned without creating the requested image")
    image_info = await asyncio.to_thread(_stamp_png_dpi_sync, target, dpi)
    result = response
    if not isinstance(result, dict):
        result = {"result": result}
    result.update({
        "output_path": str(target),
        "side": side,
        "dpi": dpi,
        "file_size": target.stat().st_size,
        **image_info,
    })
    return result


@mcp.tool()
async def export_pcb_3d_image(
    ctx: Context,
    output_path: str,
    side: str = "top",
    dpi: int = 600,
    workspace_color: Optional[str] = None,
    board_color: Optional[str] = None,
    solder_mask_color: Optional[str] = None,
    silk_color: Optional[str] = None,
    copper_color: Optional[str] = None,
) -> str:
    """Export one orthographic PCB 3D PNG directly, without an OutJob.

    ``side`` is ``top`` or ``bottom`` and DPI defaults to 600. Omit all color
    parameters to use the current Altium 3D view colors, or supply any #RRGGBB
    overrides. The PCB document is not modified or saved.
    """
    target = Path(output_path).expanduser().resolve()
    if target.suffix.lower() != ".png":
        return json_dumps({"success": False, "error": "output_path must be a PNG file"})
    side = side.strip().lower()
    if side not in {"top", "bottom"}:
        return json_dumps({"success": False, "error": "side must be top or bottom"})
    if dpi not in {75, 150, 300, 600}:
        return json_dumps({"success": False, "error": "dpi must be 75, 150, 300, or 600"})
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    try:
        colors = _pcb_3d_color_params(
            workspace_color, board_color, solder_mask_color, silk_color, copper_color)
        result = await _export_one_pcb_3d_image(target, side, dpi, colors)
        return json_dumps({"success": True, **result}, indent=2)
    except Exception as exc:
        return json_dumps({"success": False, "error": str(exc), "output_path": str(target)})


@mcp.tool()
async def export_pcb_3d_images(
    ctx: Context,
    output_directory: str,
    dpi: int = 600,
    workspace_color: Optional[str] = None,
    board_color: Optional[str] = None,
    solder_mask_color: Optional[str] = None,
    silk_color: Optional[str] = None,
    copper_color: Optional[str] = None,
    overwrite: bool = False,
) -> str:
    """Export orthographic top and bottom PCB 3D PNG files without an OutJob.

    The files are named ``pcb-3d-top.png`` and ``pcb-3d-bottom.png``. DPI
    defaults to 600. Optional #RRGGBB values configure the 3D view coloring;
    when none are supplied, Altium's current system view colors are used.
    """
    try:
        directory = Path(output_directory).expanduser()
        if not directory.is_absolute():
            raise ValueError("output_directory must be absolute")
        directory = directory.resolve()
        if dpi not in {75, 150, 300, 600}:
            raise ValueError("dpi must be 75, 150, 300, or 600")
        targets = {
            "top": directory / "pcb-3d-top.png",
            "bottom": directory / "pcb-3d-bottom.png",
        }
        for target in targets.values():
            _prepare_output_path(target, overwrite)
        colors = _pcb_3d_color_params(
            workspace_color, board_color, solder_mask_color, silk_color, copper_color)
        images = []
        for side, target in targets.items():
            images.append(await _export_one_pcb_3d_image(target, side, dpi, colors))
        return json_dumps({
            "success": True,
            "dpi": dpi,
            "images": images,
            "document_modified": False,
            "document_saved": False,
        }, indent=2)
    except Exception as exc:
        return json_dumps({"success": False, "error": str(exc)})


@mcp.tool()
async def export_pcb_assembly_images(
    ctx: Context,
    output_directory: str,
    dpi: int = 600,
    top_color: str = "#111111",
    bottom_color: str = "#111111",
    outline_color: str = "#000000",
    mirror_bottom: bool = True,
    keep_svg: bool = False,
    overwrite: bool = False,
) -> str:
    """Export top and bottom Mechanical-2 assembly PNGs with board contour.

    PNG files have an alpha channel and a transparent background. Geometry is
    produced by EasyEDA-Loader's existing Mechanical-2 SVG converter, so arcs,
    regions, tracks, assembly text, and pad geometry match its normal SVG
    output. Retained SVGs put pads in a separate ``Pads`` group and store the
    Altium pad number in each path's non-visible ``data-pad-number`` attribute.
    DPI defaults to 600. ``mirror_bottom`` selects the conventional bottom-side
    view. Pad geometry is visible in the raster PNG; SVG metadata is SVG-only.

    When the task needs pad numbers or schematic-pin correspondence, set
    ``keep_svg=True`` and read paths inside ``<g id="Pads">``. Use
    ``data-pad-number`` as the Altium pad/pin designator instead of trying to
    recognize a number from the PNG. Use ``data-component`` for the logical
    designator and ``data-instance`` to distinguish repeated designators on a
    panelized PCB.

    SVG physical dimensions and path coordinates are in millimetres. The board
    contour defaults to black and is exactly 0.1 mm wide. ``outline_color`` can
    override its color without changing its width.
    """
    svg_paths = []
    try:
        directory = Path(output_directory).expanduser()
        if not directory.is_absolute():
            raise ValueError("output_directory must be absolute")
        directory = directory.resolve()
        if dpi < 72 or dpi > 2400:
            raise ValueError("dpi must be between 72 and 2400")
        colors = {
            "top": _normalize_html_color(top_color, "top_color"),
            "bottom": _normalize_html_color(bottom_color, "bottom_color"),
        }
        outline = _normalize_html_color(outline_color, "outline_color")
        images = []
        for side in ("top", "bottom"):
            svg_path = directory / f"pcb-assembly-{side}.svg"
            png_path = directory / f"pcb-assembly-{side}.png"
            _prepare_output_path(svg_path, overwrite)
            _prepare_output_path(png_path, overwrite)
            svg_paths.append(svg_path)
            bridge_result = await _run_easyeda_bridge({
                "command": "export-board-assembly",
                "side": side,
                "output_path": str(svg_path),
                "mirror_bottom": mirror_bottom,
            })
            _recolor_svg(svg_path, colors[side], outline)
            png_result = await _rasterize_svg(svg_path, png_path, dpi)
            images.append({
                "side": side,
                "svg_path": str(svg_path) if keep_svg else None,
                "component_count": bridge_result.get("component_count"),
                "primitive_count": bridge_result.get("primitive_count"),
                "pad_count": bridge_result.get("pad_count"),
                "pads_included": bridge_result.get("pads_included", True),
                **png_result,
            })
            if not keep_svg:
                svg_path.unlink(missing_ok=True)
        return json_dumps({
            "success": True,
            "images": images,
            "document_modified": False,
            "document_saved": False,
        }, indent=2)
    except Exception as exc:
        return json_dumps({"success": False, "error": str(exc)})


@mcp.tool()
async def export_component_assembly(
    ctx: Context,
    component: str,
    svg_path: str,
    png_path: Optional[str] = None,
    dpi: int = 600,
    line_color: str = "#111111",
    overwrite: bool = False,
) -> str:
    """Export one component's Mechanical-2 assembly artwork and pads.

    ``component`` is the PCB designator (for example ``U12``). In a PcbLib,
    leave it empty to export the current footprint. ``svg_path`` is required;
    ``png_path`` defaults to the same path with a .png suffix. Both output paths
    must be absolute. Pads are in a separate SVG ``Pads`` group; each pad path
    has non-visible component, footprint, pad-number, and pad-index metadata.
    The PNG background is transparent, includes the pad geometry, and defaults
    to 600 DPI.

    When pad or schematic-pin numbers are needed, inspect the SVG paths inside
    ``<g id="Pads">`` and use ``data-pad-number``. Do not infer the number from
    path order, geometry, or PNG pixels. ``data-component`` identifies the
    logical component and ``data-instance`` disambiguates repeated components
    on panelized boards.

    SVG physical dimensions, view-box coordinates, pad geometry, and assembly
    geometry are expressed in millimetres.
    """
    try:
        svg_target = _absolute_output_path(svg_path, ".svg")
        png_target = _absolute_output_path(png_path, ".png") if png_path else svg_target.with_suffix(".png")
        if dpi < 72 or dpi > 2400:
            raise ValueError("dpi must be between 72 and 2400")
        _prepare_output_path(svg_target, overwrite)
        _prepare_output_path(png_target, overwrite)
        color = _normalize_html_color(line_color, "line_color")
        bridge_result = await _run_easyeda_bridge({
            "command": "export-component-assembly",
            "component": component,
            "output_path": str(svg_target),
        })
        _recolor_svg(svg_target, color, color)
        png_result = await _rasterize_svg(svg_target, png_target, dpi)
        return json_dumps({
            "success": True,
            "component": component,
            "svg_path": str(svg_target),
            "png": png_result,
            "primitive_count": bridge_result.get("primitive_count"),
            "pad_count": bridge_result.get("pad_count"),
            "pads_included": bridge_result.get("pads_included", True),
            "document_modified": False,
            "document_saved": False,
        }, indent=2)
    except Exception as exc:
        return json_dumps({"success": False, "error": str(exc)})
    
@mcp.tool()
async def layout_duplicator(ctx: Context) -> str:
    """
    First step of layout duplication. Selects source components and returns data to match with destination components.
    
    Returns:
        str: JSON object with source and destination component data for matching
    """
    logger.info("Starting layout duplication - selection phase")
    
    # Execute the command in Altium to get component data
    response = await altium_bridge.execute_command(
        "layout_duplicator", 
        {}
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error in layout duplication selection: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to start layout duplication: {error_msg}"})
    
    # Get the component data
    components_data = response.get("result", {})
    
    if not components_data:
        logger.info("No component data found")
        return json_dumps({"success": False, "error": "No component data returned from Altium"})
    
    # Parse the result to check if no source components were selected
    try:
        if isinstance(components_data, str):
            result_json = json.loads(components_data)
            if not result_json.get("success", True):
                logger.info(f"Source component selection issue: {result_json.get('message', 'Unknown issue')}")
                return json_dumps(result_json)
    except Exception as e:
        logger.error(f"Error parsing layout duplicator result: {e}")
    
    logger.info(f"Retrieved layout duplicator component data")
    return json_dumps(components_data, indent=2)

@mcp.tool()
async def layout_duplicator_apply(ctx: Context, source_designators: list, destination_designators: list) -> str:
    """
    Second step of layout duplication. Applies the layout of source components to destination components.
    
    Args:
        source_designators (list): List of source component designators (e.g., ["R1", "C5", "U3"])
        destination_designators (list): List of destination component designators (e.g., ["R10", "C15", "U7"])
    
    Returns:
        str: JSON object with the result of the layout duplication
    """
    logger.info(f"Applying layout duplication from {source_designators} to {destination_designators}")
    
    # Execute the command in Altium to apply layout duplication
    response = await altium_bridge.execute_command(
        "layout_duplicator_apply",
        {
            "source_designators": source_designators,
            "destination_designators": destination_designators
        }
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error applying layout duplication: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to apply layout duplication: {error_msg}"})
    
    # Get the result data
    result = response.get("result", {})
    
    logger.info(f"Layout duplication applied successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def layout_duplicator_apply_groups(
    ctx: Context,
    source_designators: list,
    destination_designator_groups: list,
) -> str:
    """
    Apply one selected layout/routing source group to multiple destination groups in one Altium call.

    Use this after layout_duplicator when copied tracks, vias, polygons, or regions are selected.
    Separate layout_duplicator_apply calls can move the same duplicated routing primitives between
    destinations; this helper repeats the source group and flattens all destination groups so the
    Pascal apply command replicates routing for each group.

    Args:
        source_designators (list): Source component designators in one group.
        destination_designator_groups (list): List of destination groups, each matching source length.

    Returns:
        str: JSON object with the result of the layout duplication
    """
    if not source_designators:
        return json_dumps({"success": False, "error": "source_designators must not be empty"})

    if not destination_designator_groups:
        return json_dumps({"success": False, "error": "destination_designator_groups must not be empty"})

    source_group_size = len(source_designators)
    validation_errors = []
    for group_index, destination_group in enumerate(destination_designator_groups):
        if not isinstance(destination_group, list):
            validation_errors.append(f"group {group_index} is not a list")
            continue

        if len(destination_group) != source_group_size:
            validation_errors.append(
                f"group {group_index} has {len(destination_group)} designators; expected {source_group_size}"
            )

    if validation_errors:
        return json_dumps({"success": False, "error": "; ".join(validation_errors)})

    expanded_source_designators = []
    flattened_destination_designators = []
    for destination_group in destination_designator_groups:
        expanded_source_designators.extend(source_designators)
        flattened_destination_designators.extend(destination_group)

    logger.info(
        "Applying grouped layout duplication from %s to %d destination groups",
        source_designators,
        len(destination_designator_groups),
    )

    response = await altium_bridge.execute_command(
        "layout_duplicator_apply",
        {
            "source_designators": expanded_source_designators,
            "destination_designators": flattened_destination_designators,
        }
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error applying grouped layout duplication: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to apply grouped layout duplication: {error_msg}"})

    result = response.get("result", {})

    logger.info("Grouped layout duplication applied successfully")
    return json_dumps(result, indent=2)
    
@mcp.tool()
async def get_pcb_rules(ctx: Context) -> str:
    """
    Get all design rules from the current Altium PCB
    
    Returns:
        str: JSON array of PCB design rules with their properties
    """
    logger.info("Getting PCB design rules")
    
    # Execute the command in Altium to get rule data
    response = await altium_bridge.execute_command(
        "get_pcb_rules",
        {}  # No parameters needed
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting PCB rules: {error_msg}")
        return json_dumps({"error": f"Failed to get PCB rules: {error_msg}"})
    
    # Get the rules data
    rules_data = response.get("result", [])
    
    if not rules_data:
        logger.info("No PCB rules found")
        return json_dumps({"message": "No PCB rules found in the current document"})
    
    logger.info(f"Retrieved PCB rules data")
    return json_dumps(rules_data, indent=2)

@mcp.tool()
async def get_pcb_layer_stackup(ctx: Context) -> str:
    """
    Get the detailed layer stackup information from the current Altium PCB including
    copper thickness, dielectric materials, constants, and heights
    
    Returns:
        str: JSON object with detailed layer stackup information
    """
    logger.info("Getting PCB layer stackup information")
    
    # Execute the command in Altium to get layer stackup data
    response = await altium_bridge.execute_command(
        "get_pcb_layer_stackup",
        {}  # No parameters needed
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting PCB layer stackup: {error_msg}")
        return json_dumps({"error": f"Failed to get PCB layer stackup: {error_msg}"})
    
    # Get the stackup data
    stackup_data = response.get("result", {})
    
    if not stackup_data:
        logger.info("No PCB layer stackup found")
        return json_dumps({"message": "No PCB layer stackup found in the current document"})
    
    logger.info(f"Retrieved PCB layer stackup data")
    return json_dumps(stackup_data, indent=2)

@mcp.tool()
async def get_output_job_containers(ctx: Context) -> str:
    """
    Get all available output job containers from a specified OutJob file
    
    Args:
        outjob_path (str): Path to the OutJob file (optional, will use first open OutJob if not provided)
    
    Returns:
        str: JSON array with all output job containers and their properties
    """
    logger.info("Getting output job containers from the first open OutJob")
    
    # Execute the command in Altium to get output job containers
    response = await altium_bridge.execute_command(
        "get_output_job_containers", 
        {}  # No parameters needed - will use first open OutJob
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting output job containers: {error_msg}")
        return json_dumps({"error": f"Failed to get output job containers: {error_msg}"})
    
    # Get the containers data
    containers_data = response.get("result", [])
    
    if not containers_data:
        logger.info("No output job containers found")
        return json_dumps({"message": "No output job containers found"})
    
    logger.info(f"Retrieved output job containers data")
    return containers_data  # Already in JSON format

@mcp.tool()
async def run_output_jobs(ctx: Context, container_names: list) -> str:
    """
    Run specified output job containers
    
    Args:
        container_names (list): List of container names to run
    
    Returns:
        str: JSON object with results of running the output jobs
    """
    logger.info(f"Running output jobs")
    logger.info(f"Containers to run: {container_names}")
    
    # Execute the command in Altium to run output jobs
    response = await altium_bridge.execute_command(
        "run_output_jobs", 
        {"container_names": container_names}
    )
    
    # Check for success
    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error running output jobs: {error_msg}")
        return json_dumps({"error": f"Failed to run output jobs: {error_msg}"})
    
    # Get the result data
    result_data = response.get("result", {})
    
    logger.info(f"Output jobs execution completed")
    
    # If result_data is a string, it's already in JSON format
    if isinstance(result_data, str):
        return result_data
    
    # Otherwise, convert to JSON
    return json_dumps(result_data, indent=2)

@mcp.tool()
async def save_current_document(ctx: Context, user_requested: bool = False) -> str:
    """
    Save the currently focused Altium document.
    Set user_requested=true only when the current user message explicitly asks
    to save. Calls without that confirmation are refused so create/update
    workflows cannot accidentally save inspection changes.

    Args:
        user_requested (bool): Must be true for the save to run.

    Returns:
        str: JSON object with result
    """
    if not user_requested:
        logger.warning("Refusing to save current document without explicit user_requested=true")
        return json_dumps({
            "success": False,
            "error": "Refusing to save without explicit user_requested=true"
        })

    logger.info("Saving current Altium document")

    response = await altium_bridge.execute_command("save_current_document", {})

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error saving current document: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to save current document: {error_msg}"})

    result = response.get("result", {})
    logger.info("Current Altium document saved successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def get_pcblib_footprints(ctx: Context) -> str:
    """
    Return every footprint name in the currently active PCB footprint library.

    The PcbLib must be the focused document in Altium.

    Returns:
        str: JSON object with footprint_count and footprints
    """
    logger.info("Getting footprint names from active PCB library")

    response = await altium_bridge.execute_command("get_pcblib_footprints", {})

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting PCB library footprints: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to get PCB library footprints: {error_msg}"})

    result = response.get("result", {})
    logger.info("PCB library footprint list retrieved successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def get_pcblib_footprint_primitives(ctx: Context, footprint_name: str) -> str:
    """
    Return pads, tracks, arcs, text, and 3D body primitives for one PcbLib footprint.

    The PcbLib must be the focused document in Altium.

    Args:
        footprint_name (str): Footprint name to inspect

    Returns:
        str: JSON object with primitive arrays
    """
    logger.info(f"Getting PCB library footprint primitives for {footprint_name}")

    response = await altium_bridge.execute_command(
        "get_pcblib_footprint_primitives",
        {"footprint_name": footprint_name},
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error getting PCB library footprint primitives: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to get PCB library footprint primitives: {error_msg}"})

    result = response.get("result", {})
    logger.info("PCB library footprint primitives retrieved successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def create_pcb_footprint(ctx: Context, footprint_name: str, description: str, pads: list, courtyard_x_mm: float = 0, courtyard_y_mm: float = 0) -> str:
    """
    Create a new PCB footprint in the currently active PcbLib document.
    The PcbLib (e.g. Discrete.PcbLib) must be the focused document in Altium.
    This tool does not save the PCB library document; leave it dirty for user
    inspection unless the user explicitly asks to save.

    Pad format: each element is "pad_number|x_mm|y_mm|width_mm|height_mm|shape"
                shape options: Rect (default), Round, Oval
                Coordinates are in mm relative to component origin (0,0).
                Pin 1 is indicated by a gap in the top-left silkscreen corner.

    Courtyard & silkscreen are auto-generated from pad extents + 0.25 mm margin
    unless courtyard_x_mm / courtyard_y_mm are provided explicitly (half-dimensions).

    Args:
        footprint_name (str): Footprint name as it will appear in the library
        description (str): Description string
        pads (list): List of pad definitions, e.g. ["1|-0.9|0.55|1.0|0.8|Rect", ...]
        courtyard_x_mm (float): Half-width of courtyard in mm (0 = auto)
        courtyard_y_mm (float): Half-height of courtyard in mm (0 = auto)

    Returns:
        str: JSON object with result
    """
    logger.info(f"Creating PCB footprint: {footprint_name} with {len(pads)} pads")

    response = await altium_bridge.execute_command(
        "create_pcb_footprint",
        {
            "footprint_name": footprint_name,
            "description": description,
            "pads": pads,
            "courtyard_x_mm": courtyard_x_mm,
            "courtyard_y_mm": courtyard_y_mm,
        }
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error creating footprint: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to create footprint: {error_msg}"})

    result = response.get("result", {})
    logger.info(f"Footprint {footprint_name} created successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def set_pcb_library_pad_shapes(ctx: Context, exclude_footprint_names: list) -> str:
    """
    Set all copper pad shapes in the currently active PCB library to Rounded Rectangle,
    except footprints whose names are listed in exclude_footprint_names.

    The PcbLib must be the focused document in Altium.

    Args:
        exclude_footprint_names (list): Footprint names to skip, e.g. ["53398-0271"]

    Returns:
        str: JSON object with result
    """
    logger.info(f"Setting PCB library pad shapes to Rounded Rectangle, excluding {exclude_footprint_names}")

    response = await altium_bridge.execute_command(
        "set_pcb_library_pad_shapes",
        {"exclude_footprint_names": exclude_footprint_names}
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error setting PCB library pad shapes: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to set PCB library pad shapes: {error_msg}"})

    result = response.get("result", {})
    logger.info("PCB library pad shapes updated successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def move_pcb_library_mechanical_layers(ctx: Context, exclude_footprint_names: list, layer_moves: list) -> str:
    """
    Move primitives between mechanical layers across the currently active PCB library,
    except footprints whose names are listed in exclude_footprint_names.

    The PcbLib must be the focused document in Altium.

    Args:
        exclude_footprint_names (list): Footprint names to skip, e.g. ["53398-0271"]
        layer_moves (list): Mechanical layer moves as "source|destination", e.g. ["13|1", "15|3"]

    Returns:
        str: JSON object with result
    """
    logger.info(
        f"Moving PCB library mechanical layers {layer_moves}, excluding {exclude_footprint_names}"
    )

    response = await altium_bridge.execute_command(
        "move_pcb_library_mechanical_layers",
        {
            "exclude_footprint_names": exclude_footprint_names,
            "layer_moves": layer_moves,
        }
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error(f"Error moving PCB library mechanical layers: {error_msg}")
        return json_dumps({"success": False, "error": f"Failed to move PCB library mechanical layers: {error_msg}"})

    result = response.get("result", {})
    logger.info("PCB library mechanical layers updated successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def copy_pcb_polygon_geometry(ctx: Context, source_polygon: str, target_polygon: str) -> str:
    """
    Copy the geometry of one named PCB polygon to another named PCB polygon.

    The destination polygon keeps its original name, net, and layer. The board is
    modified in Altium and left dirty for inspection; this tool does not save.

    Args:
        source_polygon (str): Source polygon name, or its net name as fallback.
        target_polygon (str): Target polygon name, or its net name as fallback.

    Returns:
        str: JSON object with source/target polygon readback details.
    """
    logger.info("Copying PCB polygon geometry from %s to %s", source_polygon, target_polygon)

    response = await altium_bridge.execute_command(
        "copy_pcb_polygon_geometry",
        {
            "source_polygon": source_polygon,
            "target_polygon": target_polygon,
        },
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error("Error copying PCB polygon geometry: %s", error_msg)
        return json_dumps({"success": False, "error": f"Failed to copy PCB polygon geometry: {error_msg}"})

    result = response.get("result", {})
    logger.info("PCB polygon geometry copied successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def copy_selected_fill_to_signal_layers(ctx: Context) -> str:
    """
    Copy the currently selected PCB fill or region to every other signal layer.

    Exactly one fill or region must be selected. The copied primitives keep the
    source geometry and net, are placed on each other signal layer, and the PCB
    document is left dirty for inspection; this tool does not save.

    Returns:
        str: JSON object with copied layer readback details.
    """
    logger.info("Copying selected fill/region to signal layers")

    response = await altium_bridge.execute_command(
        "copy_selected_fill_to_signal_layers",
        {},
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error("Error copying selected fill/region to signal layers: %s", error_msg)
        return json_dumps({"success": False, "error": f"Failed to copy selected fill/region to signal layers: {error_msg}"})

    result = response.get("result", {})
    logger.info("Selected fill/region copied to signal layers successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def add_tented_vias_around_keepout_contour(
    ctx: Context,
    via_diameter_mm: float = 0.4,
    via_hole_mm: float = 0.2,
    edge_clearance_mm: float = 0.3,
    pitch_mm: float = 2.0,
    net_name: str = "",
) -> str:
    """
    Add fully tented vias around the active PCB keepout contour.

    Vias are placed inside the PCB by offsetting their centers from the Keep-Out
    Layer contour by edge_clearance_mm plus the via radius. The PCB document is
    modified and left dirty for inspection; this tool does not save.

    Args:
        via_diameter_mm (float): Via outer diameter in mm.
        via_hole_mm (float): Via drill hole diameter in mm.
        edge_clearance_mm (float): Clearance from via outer diameter to keepout in mm.
        pitch_mm (float): Via center-to-center pitch along the contour in mm.
        net_name (str): Optional PCB net name to assign to created vias.

    Returns:
        str: JSON object with placement counts and applied settings.
    """
    logger.info(
        "Adding tented contour vias diameter=%s hole=%s edge_clearance=%s pitch=%s",
        via_diameter_mm,
        via_hole_mm,
        edge_clearance_mm,
        pitch_mm,
    )

    response = await altium_bridge.execute_command(
        "add_tented_vias_around_keepout_contour",
        {
            "via_diameter_mm": via_diameter_mm,
            "via_hole_mm": via_hole_mm,
            "edge_clearance_mm": edge_clearance_mm,
            "pitch_mm": pitch_mm,
            "net_name": net_name,
        },
    )

    if not response.get("success", False):
        error_msg = response.get("error", "Unknown error")
        logger.error("Error adding tented contour vias: %s", error_msg)
        return json_dumps({"success": False, "error": f"Failed to add tented contour vias: {error_msg}"})

    result = response.get("result", {})
    logger.info("Tented contour vias added successfully")
    return json_dumps(result, indent=2)

@mcp.tool()
async def get_server_status(ctx: Context) -> str:
    """Get the current status of the Altium MCP server"""
    status = {
        "server": "Running",
        "altium_exe": altium_bridge.config.altium_exe_path,
        "script_path": altium_bridge.config.script_path,
        "altium_found": os.path.exists(altium_bridge.config.altium_exe_path),
        "script_found": os.path.exists(altium_bridge.config.script_path),
    }
    
    return json_dumps(status, indent=2)

if __name__ == "__main__":
    logger.info("Starting Altium MCP Server...")
    logger.info(f"Using MCP directory: {MCP_DIR}")
    
    # Initialize the directory
    MCP_DIR.mkdir(exist_ok=True)
    
    # Create the AltiumScript directory if it doesn't exist
    script_dir = MCP_DIR / "AltiumScript"
    script_dir.mkdir(exist_ok=True)
    
    # Print status
    print(f"Altium executable: {altium_bridge.config.altium_exe_path}")
    print(f"Script path: {altium_bridge.config.script_path}")
    
    # Run the server
    mcp.run(transport='stdio')
