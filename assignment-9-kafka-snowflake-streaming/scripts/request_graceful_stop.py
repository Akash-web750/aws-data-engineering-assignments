"""
Asks one background process to shut down cleanly, the way Ctrl+C would. Windows only.

Used by scripts/stop_pipeline.ps1:

    python scripts/request_graceful_stop.py <process id> [ctrl-c | ctrl-break]

WHY THIS EXISTS
    The pipeline's services run as hidden background processes. Windows has
    no "please stop" signal that one process can simply send to another:
    Stop-Process (TerminateProcess) ends the target at once, in the middle of
    whatever it is doing. The consumer and the CDC bridge both have an orderly
    shutdown (finish the batch, commit the position, close the connections),
    and so do Kafka and Kafka Connect, but only Ctrl+C triggers it.

HOW IT WORKS
    Ctrl+C is delivered by Windows to every process attached to a console.
    Each background service has its own (hidden) console. This helper
        1. lets go of its own console,
        2. attaches itself to the console of the target process,
        3. generates a Ctrl+C (or Ctrl+Break) event on that console,
        4. detaches again.
    The event therefore reaches the target process (and its children, such as
    the java.exe started by a Kafka .bat file) and no other process.

WHICH EVENT
    ctrl-c      (default) for the Java services. Kafka and Kafka Connect shut
                down cleanly on Ctrl+C; on Ctrl+Break a Java program only
                prints a thread dump and keeps running.
    ctrl-break  for the Python services. Both the consumer and the CDC bridge
                handle Ctrl+Break exactly like Ctrl+C. It is the more reliable
                of the two: a process started from a shell that ignores
                Ctrl+C inherits that setting and never sees a Ctrl+C event
                (observed when the scripts were started from Git Bash),
                whereas Windows does not allow Ctrl+Break to be switched off.

WHAT IT DOES NOT DO
    It never terminates anything. It only delivers the request; whether and
    when the target exits is up to the target. The caller waits for the exit
    and decides what to do if it does not come.

Exit codes:
    0  the Ctrl+C event was delivered
    1  wrong usage
    2  not running on Windows
    3  the target has no console to attach to (or does not exist, or access
       is denied, for example a process started by an administrator)
    4  the event could not be generated
"""

from __future__ import annotations

import sys

# Windows constants: the two console control events, by the name used on the
# command line.
CTRL_C_EVENT = 0
CTRL_BREAK_EVENT = 1
EVENTS: dict[str, int] = {"ctrl-c": CTRL_C_EVENT, "ctrl-break": CTRL_BREAK_EVENT}

EXIT_DELIVERED = 0
EXIT_USAGE = 1
EXIT_NOT_WINDOWS = 2
EXIT_CANNOT_ATTACH = 3
EXIT_CANNOT_SIGNAL = 4


def parse_arguments(arguments: list[str]) -> tuple[int, int]:
    """Return ``(process id, event)`` from the command line.

    Args:
        arguments: The process id, optionally followed by ``ctrl-c`` (the
            default) or ``ctrl-break``.

    Raises:
        ValueError: if the arguments are missing, too many, or not valid.
    """
    if not 1 <= len(arguments) <= 2:
        raise ValueError("expected the process id, optionally followed by ctrl-c or ctrl-break")
    try:
        process_id = int(arguments[0])
    except ValueError as exc:
        raise ValueError(f"the process id must be a whole number, got {arguments[0]!r}") from exc
    if process_id <= 0:
        raise ValueError(f"the process id must be positive, got {process_id}")
    event_name = arguments[1] if len(arguments) == 2 else "ctrl-c"
    if event_name not in EVENTS:
        raise ValueError(f"the event must be ctrl-c or ctrl-break, got {event_name!r}")
    return process_id, EVENTS[event_name]


def send_console_event(process_id: int, event: int = CTRL_C_EVENT) -> int:
    """Deliver a Ctrl+C or Ctrl+Break event to the console of ``process_id``.

    Args:
        process_id: The process whose console receives the event.
        event: ``CTRL_C_EVENT`` or ``CTRL_BREAK_EVENT``.

    Returns:
        One of the exit codes described in the module docstring.
    """
    if sys.platform != "win32":
        return EXIT_NOT_WINDOWS

    import ctypes
    import time
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    # A process can be attached to only one console at a time, so first let
    # go of our own. (When started without a console this call simply fails,
    # which is fine.)
    kernel32.FreeConsole()

    # Join the console of the target. This fails if the process does not
    # exist, has no console, or belongs to a more privileged user.
    if not kernel32.AttachConsole(process_id):
        return EXIT_CANNOT_ATTACH

    try:
        # The event goes to EVERY process attached to this console, and that
        # now includes this helper. Without a handler of its own, Windows
        # would end the helper on its own event. Register a handler that
        # answers "handled" for every console event, so nothing happens here.
        # (The handler object must stay referenced while it is registered.)
        handler_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.DWORD)
        swallow_event = handler_type(lambda control_type: True)
        if not kernel32.SetConsoleCtrlHandler(swallow_event, True):
            return EXIT_CANNOT_SIGNAL

        # Process group 0 means "all processes sharing the caller's console".
        if not kernel32.GenerateConsoleCtrlEvent(event, 0):
            return EXIT_CANNOT_SIGNAL

        # Windows delivers the event on a separate thread. Stay attached, with
        # the handler in place, until this helper has received its own copy.
        time.sleep(0.5)
    finally:
        # Leave the target's console again, whatever happened.
        kernel32.FreeConsole()
    return EXIT_DELIVERED


def main() -> int:
    """Entry point: read the process id, deliver the event, return the exit code."""
    try:
        process_id, event = parse_arguments(sys.argv[1:])
    except ValueError as error:
        # May not be visible when started hidden; the exit code carries the result.
        print(
            f"usage: python scripts/request_graceful_stop.py <process id> [ctrl-c | ctrl-break]  ({error})",
            file=sys.stderr,
        )
        return EXIT_USAGE
    return send_console_event(process_id, event)


if __name__ == "__main__":
    sys.exit(main())
