#!/usr/bin/env python3
import sys

ESC = "\x1b["


def w(s: str = ""):
    sys.stdout.write(s)


def line(s: str = ""):
    sys.stdout.write(s + "\n")


def sgr(*codes: int) -> str:
    return ESC + ";".join(str(c) for c in codes) + "m"


def reset() -> str:
    return sgr(0)


def show(label: str, seq: str, text: str = "DIR sample ABCxyz 0123 /"):
    line(f"{label:28} | {seq}{text}{reset()}")


def hexify(seq: str) -> str:
    return " ".join(f"{b:02x}" for b in seq.encode("utf-8"))


def main():
    line("bold-blue-probe start")
    line()
    line("== visual ==")

    variants = [
        ("plain classic blue", sgr(34)),
        ("combined 1;34", sgr(1, 34)),
        ("split 1 then 34", sgr(1) + sgr(34)),
        ("split 34 then 1", sgr(34) + sgr(1)),
        ("combined 0;1;34", sgr(0, 1, 34)),
        ("combined 1;34;49", sgr(1, 34, 49)),
        ("combined 1;38;5;4", sgr(1, 38, 5, 4)),
        ("combined 1;38;5;12", sgr(1, 38, 5, 12)),
        ("combined 1;94", sgr(1, 94)),
        ("combined 94", sgr(94)),
    ]

    for label, seq in variants:
        show(label, seq)

    line()
    line("== reset / transition behavior ==")
    line(f"22 after 1;34              | {sgr(1,34)}bold blue{sgr(22)} no-bold same fg{reset()}")
    line(f"39 after 1;34              | {sgr(1,34)}bold blue{sgr(39)} default fg only{reset()}")
    line(f"0 then 34 after 1;34       | {sgr(1,34)}bold blue{sgr(0)}{sgr(34)} plain blue again{reset()}")
    line(f"22 then 34 after 1;34      | {sgr(1,34)}bold blue{sgr(22)}{sgr(34)} plain blue again{reset()}")
    line(f"34 then 22 after 1;34      | {sgr(1,34)}bold blue{sgr(34)}{sgr(22)} plain blue again{reset()}")
    line(f"1 then 34 then text chunks | {sgr(1)}{sgr(34)}DIR {sgr(1)}NAME {sgr(22)}tail{reset()}")

    line()
    line("== bytes ==")
    for label, seq in variants:
        line(f"{label:28} | {hexify(seq)}")

    line()
    line("bold-blue-probe end")


if __name__ == "__main__":
    main()
