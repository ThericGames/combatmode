"""Build the help badge: CombatMode/Assets/ui/help-badge.tga.

    python scripts/art/make-help-badge.py

The same gold round button as the character-specific badge (make-char-badge.py), with a dark "?" for
the options' short explanation tooltips. 64x64, RGBA, RLE-compressed. Needs Pillow + numpy.
"""
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_char_badge", os.path.join(HERE, "make-char-badge.py"))
badge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(badge)

OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "CombatMode", "Assets", "ui", "help-badge.tga")

if __name__ == "__main__":
    badge.main("?", OUT)
