"""Read the pin rows from Altium's compiled schematic export."""


def is_auto_net(net: str, designator: str, pin: str) -> bool:
    """Whether this is the name Altium supplies to an unconnected pin."""
    return net.lower() == f"net{designator}_{pin}".lower()


def compiled_pins(rows) -> dict[tuple[str, str], tuple[str, str, str]]:
    """Index valid rows by case-insensitive pin identity, keeping original spellings."""
    pins = {}
    for row in rows:
        fields = row.split("|", 2)
        if len(fields) != 3:
            continue
        designator, pin, net = fields
        key = (designator.lower(), pin.lower())
        previous = pins.get(key)
        # The same power pin can occur once for each unit of a multipart
        # component. Keep its assigned net in preference to an unconnected unit.
        if previous and previous[2] and not is_auto_net(previous[2], *key):
            continue
        pins[key] = (designator, pin, net)
    return pins
