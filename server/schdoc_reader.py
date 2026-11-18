"""Read the records of an Altium schematic document (.SchDoc) without Altium.

A SchDoc is an OLE compound file. Its "FileHeader" stream holds one record per
object, each a 4-byte header (length in the low 24 bits, a type byte on top)
followed by either "|KEY=VALUE|..." text or a binary record. This reads the
text records into dicts, in file order; OWNERINDEX links a child (pin,
designator, parameter, body graphic) to the record of its component.

Only the standard library is used, so the check can run anywhere and needs no
running Altium.
"""
import struct
from pathlib import Path

if __package__:
    from .compound_file import CompoundBinaryFile
else:
    from compound_file import CompoundBinaryFile


def parse_records(stream: bytes) -> list:
    """Split a FileHeader stream into records. Binary records become None, so
    list indices still match the OWNERINDEX numbering."""
    records, off = [], 0
    while off + 4 <= len(stream):
        header = struct.unpack_from("<I", stream, off)[0]
        length, kind = header & 0xFFFFFF, header >> 24
        body = stream[off + 4:off + 4 + length]
        off += 4 + length
        if kind != 0:
            records.append(None)
            continue
        text = body.rstrip(b"\x00").decode("cp1252", "replace")
        rec = {}
        for field in text.split("|"):
            if "=" in field:
                k, v = field.split("=", 1)
                rec[k.upper()] = v
        # UTF-8 copies of text fields are stored as %UTF8%KEY
        for k in [k for k in rec if k.startswith("%UTF8%")]:
            try:
                rec[k[6:]] = rec[k].encode("cp1252", "replace").decode("utf-8")
            except UnicodeDecodeError:
                pass
            del rec[k]
        records.append(rec)
    return records


def read_schdoc(path) -> list:
    """All records of a .SchDoc, the sheet header first (index -1 in OWNERINDEX
    terms is the header, so record i here is OWNERINDEX i - 1)."""
    return read_schdoc_streams(path)[0]


def read_schdoc_streams(path) -> tuple:
    """The records of the "FileHeader" stream, and of the "Additional" stream
    that holds the harness objects: connectors (215), their entries (216) and
    types (217), and signal harnesses (218). Additional is empty when the
    file has no such stream."""
    cf = CompoundBinaryFile(Path(path))
    try:
        additional = parse_records(cf.read_stream("Additional"))
    except KeyError:
        additional = []
    return parse_records(cf.read_stream("FileHeader")), additional


def coord(rec: dict, key: str) -> float:
    """A coordinate in mils. Stored as 10-mil units plus a _FRAC part in
    1/100000 of a unit, so metric sheets keep their exact positions."""
    whole = int(rec.get(key, 0) or 0)
    frac = int(rec.get(key + "_FRAC", 0) or 0)
    return (whole + frac / 100000.0) * 10.0
