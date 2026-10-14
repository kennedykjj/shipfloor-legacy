"""What every gate shares: where it writes and how it ends."""
import sys


class GateExit(Exception):
    """`exit N` inside a check: the whole gate ends with that code (nothing after the check runs)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _enc(text):
    return text.encode("utf-8", "surrogateescape")


class Context:
    """stdout is data and goes out at once; stderr is kept until the gate ends, then translated and written once."""

    def __init__(self):
        self._err = []

    def out(self, text):
        """A line of data on stdout."""
        self.out_bytes(_enc(text + "\n"))

    def out_bytes(self, data):
        sys.stdout.flush()
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    def err(self, text):
        """A line on stderr (written in English; the catalog translates it when the gate ends)."""
        self._err.append(_enc(text + "\n"))

    def err_bytes(self, data):
        if data:
            self._err.append(data)

    def stderr_bytes(self):
        return b"".join(self._err)

    def exit(self, code):
        raise GateExit(code)
