"""Process helpers: git, gh, native paths, uname."""
import os
import re
import subprocess
import sys


def _is_windows():
    return sys.platform.startswith("win") or sys.platform == "cygwin"


def _run(argv, cwd=None):
    return subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def git(*args, cwd=None):
    """Run git; returns a CompletedProcess with bytes in stdout/stderr."""
    return _run(["git", *args], cwd=cwd)


def script_argv(cmd, *args):
    """The argv that runs `cmd` (a name on the PATH or a path, maybe a script with a shebang) with args untouched:
    directly, or through bash on Windows, where a script cannot be started on its own."""
    if _is_windows():
        return ["bash", "-c", 'exec "$0" "$@"', cmd, *args]
    return [cmd, *args]


def gh(*args):
    """Run gh (or $FACTORY_GH) with the argv untouched. On Windows through bash, as the scripts do."""
    return _run(gh_argv(*args))


def gh_argv(*args):
    """The argv proc.gh runs, for a caller that picks its own streams."""
    if _is_windows():
        return ["bash", "-c", 'exec "${FACTORY_GH:-gh}" "$@"', "gh", *args]
    return [os.environ.get("FACTORY_GH") or "gh", *args]


def native_path(path, mode="m"):
    """cygpath -m (C:/...) or -w (C:\\...) under Git Bash; unchanged where there is no cygpath."""
    if not path:
        return path
    flag = "-w" if str(mode).lstrip("-") == "w" else "-m"
    try:
        r = _run(["cygpath", flag, path])
    except OSError:
        return path
    if r.returncode != 0:
        return path
    return r.stdout.decode("utf-8", "replace").rstrip("\r\n")


def uname_s():
    """`uname -s`, or the platform's name when there is no uname."""
    try:
        r = _run(["uname", "-s"])
        if r.returncode == 0:
            return r.stdout.decode("utf-8", "replace").strip()
    except OSError:
        pass
    return {"win32": "Windows", "darwin": "Darwin"}.get(sys.platform, "Linux")


def alive(held):
    """kill -0 <held> (a pid, as text or int): the pid exists and may be signalled by this user."""
    if not re.fullmatch(r"[0-9]+", str(held or "")):
        return False
    pid = int(held)
    if os.name == "nt":
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k.GetExitCodeProcess(h, ctypes.byref(code))
        k.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except (OSError, OverflowError):
        return False
    return True
