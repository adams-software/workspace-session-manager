#!/usr/bin/env python3
import os
import sys

ESC = "\x1b["
OSC = "\x1b]"
ST = "\x1b\\"


def w(s: str = ""):
    sys.stdout.write(s)


def line(s: str = ""):
    sys.stdout.write(s + "\n")


def sgr(*codes: int) -> str:
    return ESC + ";".join(str(c) for c in codes) + "m"


def reset() -> str:
    return sgr(0)


def section(title: str):
    line()
    line("== " + title + " ==")


def env_dump():
    section("env")
    keys = [
        "TERM",
        "COLORTERM",
        "TERM_PROGRAM",
        "WT_SESSION",
        "WT_PROFILE_ID",
        "ConEmuANSI",
        "MSR_SESSION",
        "WSM_ROOT",
        "VTE_VERSION",
    ]
    for key in keys:
        line(f"{key}={os.environ.get(key, '')}")


def sixteen_color_grid():
    section("16-color palette foreground")
    for i in range(16):
        code = 30 + i if i < 8 else 90 + (i - 8)
        w(f"{sgr(code)}[{i:02d} fg code {code}] {reset()}  ")
        if i % 4 == 3:
            line()

    section("16-color palette background")
    for i in range(16):
        code = 40 + i if i < 8 else 100 + (i - 8)
        w(f"{sgr(97 if i < 8 else 30, code)}[{i:02d} bg code {code}] {reset()}  ")
        if i % 2 == 1:
            line()


def indexed_probe():
    section("indexed foreground via 38;5")
    sample = list(range(16)) + [16, 17, 18, 19, 20, 21, 52, 88, 124, 160, 196, 232, 244, 255]
    for idx, color in enumerate(sample):
        w(f"{sgr(38, 5, color)}[{color:03d}] {reset()} ")
        if idx % 8 == 7:
            line()
    if len(sample) % 8 != 0:
        line()

    section("indexed background via 48;5")
    for idx, color in enumerate(sample):
        fg = 15 if color < 8 or color in (16, 17, 18, 19, 20, 21, 52, 88, 124, 160, 196, 232) else 0
        w(f"{sgr(38, 5, fg, 48, 5, color)}[{color:03d}] {reset()} ")
        if idx % 8 == 7:
            line()
    if len(sample) % 8 != 0:
        line()


def truecolor_probe():
    section("truecolor foreground")
    samples = [
        (255, 0, 0),
        (0, 255, 0),
        (0, 0, 255),
        (255, 255, 0),
        (255, 0, 255),
        (0, 255, 255),
        (255, 255, 255),
        (128, 128, 128),
    ]
    for r, g, b in samples:
        w(f"{sgr(38, 2, r, g, b)}[{r:03d},{g:03d},{b:03d}] {reset()} ")
    line()

    section("truecolor gradient")
    for i in range(0, 256, 8):
        w(sgr(48, 2, i, 255 - i, 128) + " " + reset())
    line()


def style_probe():
    section("style interactions")
    line(f"{sgr(1, 31)}bold red{reset()} | {sgr(31)}plain red{reset()} | {sgr(1, 91)}bold bright red{reset()} | {sgr(91)}bright red{reset()}")
    line(f"{sgr(7, 32)}reverse green{reset()} | {sgr(4, 34)}underline blue{reset()} | {sgr(3, 35)}italic magenta{reset()}")

    section("bold intensity matrix")
    rows = [
        ("classic blue", sgr(34), sgr(1, 34)),
        ("bright blue", sgr(94), sgr(1, 94)),
        ("indexed 004", sgr(38, 5, 4), sgr(1, 38, 5, 4)),
        ("indexed 012", sgr(38, 5, 12), sgr(1, 38, 5, 12)),
        ("rgb 005fad", sgr(38, 2, 0, 95, 173), sgr(1, 38, 2, 0, 95, 173)),
    ]
    for label, plain, bold in rows:
        line(f"{label:12} | {plain}plain sample ABCxyz 0123{reset()} | {bold}bold sample ABCxyz 0123{reset()}")

    section("bold reset transitions")
    line(f"{sgr(1, 38, 5, 12)}bold indexed12{reset()} -> reset")
    line(f"{sgr(1, 38, 5, 12)}bold indexed12{sgr(22)} no-bold same color{reset()} -> 22m")
    line(f"{sgr(1, 34)}bold classic blue{sgr(22)} no-bold classic blue{reset()} -> 22m")
    line(f"{sgr(1, 38, 2, 0, 95, 173)}bold rgb blue{sgr(22)} no-bold rgb blue{reset()} -> 22m")

    section("ls-like directory names")
    names = ["src/", "scripts/", "workspace-session-manager/", "term_engine/", "scroll/"]
    for name in names:
        line(
            f"{sgr(38,5,12)}{name}{reset()}  "
            f"{sgr(1,38,5,12)}{name}{reset()}  "
            f"{sgr(34)}{name}{reset()}  "
            f"{sgr(1,34)}{name}{reset()}"
        )


def main():
    line("color-probe start")
    env_dump()
    sixteen_color_grid()
    indexed_probe()
    truecolor_probe()
    style_probe()
    line()
    line("color-probe end")


if __name__ == "__main__":
    main()
