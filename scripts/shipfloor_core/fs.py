"""File helpers: a mkdir lock, atomic writes, file age."""
import os
import time


def lock_dir(path, info=""):
    """Take a lock by mkdir (atomic). True if taken (info is written inside), False if it is held."""
    try:
        os.mkdir(path)
    except FileExistsError:
        return False
    try:
        with open(os.path.join(path, "info"), "w", encoding="utf-8", newline="\n") as f:
            f.write(info)
    except OSError:
        pass
    return True


def write_atomic(path, data):
    """Write to a temp file beside `path`, then rename over it; a reader never sees half a file."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    mode = "wb" if isinstance(data, (bytes, bytearray)) else "w"
    kw = {} if mode == "wb" else {"encoding": "utf-8", "newline": "\n"}
    try:
        with open(tmp, mode, **kw) as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def file_age(path):
    """Seconds since the file or folder was last modified (no GNU stat)."""
    return max(0, int(time.time() - os.stat(path).st_mtime))
