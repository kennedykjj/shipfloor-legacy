"""Stack slots in process (shipfloor_core/stack.py): settings and their fallbacks, slot states and reclaims, releasing,
freeing a slot's ports (lsof, or the Windows tools), queue tickets and the lease queue, the slot's environment,
up/down with health probes, the heartbeat loop and what INT/TERM give back. The clock is fake (no real waits); lsof,
kill, curl, sleep and the Windows tools are doubles on PATH, so no real process of this machine is touched.
(In deploy_stack.py because new test modules of this pass are named deploy*.py; the shim, signals, the detached
heartbeat and one real queue run are in stack-cli.test.sh.)"""
import contextlib
import io
import os
import re
import subprocess
import sys
import time
import types
from unittest import mock

import support
from deploy_support import config_in_process
from shipfloor_core import stack


def _script(path, body):
    with open(path, "w") as f:
        f.write("#!/usr/bin/env bash\n" + body)
    os.chmod(path, 0o755)


class StackCase(support.Case):
    """A Shipfloor home, a machine config, a project config with a stack section, a fake clock and stubs first on
    PATH: lsof prints <tmp>/lsof.out and logs its arguments to lsof.log, kill logs to kill.log."""

    def setUp(self):
        super().setUp()
        self.home = os.environ["SHIPFLOOR_HOME"]
        os.makedirs(self.home, exist_ok=True)
        self.L = os.path.join(self.home, "locks")
        self.Q = os.path.join(self.L, "stack-queue")
        self.calls = self.path("calls.log")
        self.stubs = self.path("stubs")
        _script(self.stubs + "/lsof", 'echo "$*" >> "%s/lsof.log"; cat "%s/lsof.out" 2>/dev/null\nexit 0\n'
                % (self.tmp, self.tmp))
        _script(self.stubs + "/kill", 'echo "$*" >> "%s/kill.log"\n' % self.tmp)
        os.environ["PATH"] = self.stubs + os.pathsep + os.environ["PATH"]
        self.now = 0
        self.slept = []
        fake = types.SimpleNamespace(time=time.time, monotonic=time.monotonic, sleep=self._sleep)
        for p in (mock.patch.object(stack, "time", fake), mock.patch.object(stack, "_seconds", lambda: self.now)):
            p.start()
            self.addCleanup(p.stop)
        cm = config_in_process()
        cm.__enter__()
        self.addCleanup(cm.__exit__, None, None, None)
        self.procs = []
        self.addCleanup(self._reap)
        self.machine()
        self.project("up: 'true'", "down: 'true'", "ports: [web, api]", 'url: "http://localhost:{web}"')

    def _sleep(self, secs):
        self.slept.append(secs)
        self.now += secs

    def _reap(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()

    def machine(self, stacks=2, wait=2, base=24000, text=None):
        with open(os.path.join(self.home, "config.yml"), "w") as f:
            f.write(text if text is not None else "stacks: %s\nports: {base: %d, span: 10}\nstack_wait: %s\n"
                    "stack_stale: 90\nstack_hold_max: 2700\n" % (stacks, base, wait))

    def project(self, *lines, name="factory.yml"):
        """the fixture with this stack section (none: the fixture's own, a project without an up command)"""
        with open(os.path.join(support.FIXTURE, "factory.yml")) as f:
            cfg = f.read()
        if lines:
            cfg = "".join(l for l in cfg.splitlines(True) if not l.startswith("stack:"))
            cfg += "stack:\n" + "".join("  %s\n" % l for l in lines)
        p = self.write(name, cfg)
        os.environ["FACTORY_CONFIG"] = p
        return p

    def s(self):
        return stack.read_settings()

    def log(self, name):
        try:
            with open(os.path.join(self.tmp, name)) as f:
                return f.read()
        except OSError:
            return None

    def sleeper(self):
        p = subprocess.Popen(["sleep", "300"])
        self.procs.append(p)
        return p

    def plant(self, k, owner="owner", run="-", epoch=None, beat=True, cwd=None):
        """a lease of slot k: info (none when owner is None), beat, a down command logging its slot and cwd, env,
        cwd; with beat=True a live heartbeat process in beat.pid (returned)"""
        d = stack.slot_dir(k)
        os.makedirs(d, exist_ok=True)
        if owner is not None:
            with open(d + "/info", "w") as f:
                f.write("%s %s %s\n" % (owner, run, int(time.time()) if epoch is None else epoch))
        open(d + "/beat", "a").close()
        with open(d + "/down", "w") as f:
            f.write('echo "down slot=$SHIPFLOOR_SLOT cwd=$(pwd)" >> "%s"' % self.calls)
        with open(d + "/env", "w") as f:
            f.write("SHIPFLOOR_SLOT=%s\n" % k)
        with open(d + "/cwd", "w") as f:
            f.write((cwd or self.tmp) + "\n")
        if beat:
            p = self.sleeper()
            with open(d + "/beat.pid", "w") as f:
                f.write("%d\n" % p.pid)
            return p

    def age_beat(self, k, secs=300):
        b = stack.slot_dir(k) + "/beat"
        os.utime(b, (time.time() - secs, time.time() - secs))

    def ticket(self, seq, owner, pid=None, run="-", solo="-"):
        os.makedirs(self.Q, exist_ok=True)
        with open(os.path.join(self.Q, "%019d-%s" % (seq, owner)), "w") as f:
            f.write("%s %s %s\n" % (os.getpid() if pid is None else pid, run, solo))

    def queue(self):
        return sorted(n for n in os.listdir(self.Q) if not n.startswith("."))

    @contextlib.contextmanager
    def stderr(self):
        """the block's stderr (also what stack writes as bytes), in out[0]"""
        buf = io.BytesIO()
        saved = sys.stderr
        sys.stderr = io.TextIOWrapper(buf, encoding="utf-8", write_through=True)
        out = [""]
        try:
            yield out
        finally:
            sys.stderr.flush()
            sys.stderr.detach()
            sys.stderr = saved
            out[0] = buf.getvalue().decode("utf-8", "replace")

    def gone(self, p):
        try:
            p.wait(timeout=5)
            return True
        except subprocess.TimeoutExpired:
            return False


class Settings(StackCase):
    def test_valid(self):
        "a valid project config gives its stack settings beside the machine's"
        self.machine(2, 3, 25000)
        self.project("up: 'true'", "down: 'true'", "ports: [web, api]", 'url: "http://localhost:{web}"', "timeout: 7")
        self.assertEqual(self.s().values(), ["2", "25000", "10", "3", "90", "2700", "shop", "true", "true", "web\napi",
                                             "http://localhost:{web}", "", "", "7", "-"])
        self.assertTrue(os.path.isdir(self.Q))
        self.assertTrue(os.path.isdir(os.path.join(self.home, "logs")))

    def test_broken_project(self):
        "a broken or missing project config: no stack of its own, name 'project', timeout 300, solo; machine kept"
        self.machine(2, 3, 25000)
        b1 = self.write("broken1.yml", "layers: not-a-list\nstack: {ports: [Web], up: 1}\n")
        b2 = self.write("broken2.yml", "::: not [yaml\n")
        for cfg, why in ((b1, "is invalid"), (b2, "is invalid"), (os.path.join(self.tmp, "missing.yml"), "not found")):
            os.environ["FACTORY_CONFIG"] = cfg
            with self.stderr() as err:
                got = self.s().values()
            self.assertEqual(got, ["2", "25000", "10", "3", "90", "2700", "project", "", "", "", "", "", "", "300",
                                   "project"], cfg)
            self.assertIn(why, err[0])

    def test_broken_machine(self):
        "a broken machine config: 3 slots, ports from 20000 by 20, wait 1800, stale 90, hold 2700; FACTORY_STACK_WAIT wins"
        self.machine(text="stacks: many\n")
        with self.stderr() as err:
            self.assertEqual(self.s().values()[:6], ["3", "20000", "20", "1800", "90", "2700"])
            os.environ["FACTORY_STACK_WAIT"] = "11"
            self.assertEqual(self.s().WAIT, "11")
        self.assertIn("stacks must be an integer >= 1", err[0])

    def test_solo(self):
        "a project with no up command is solo: SOLO is its name"
        self.project()
        self.assertEqual(self.s().SOLO, "shop")

    def test_shim_settings(self):
        "the shell's settings (SHIPFLOOR_STACK_SETTINGS, 15 values) win over the configs; fewer values are ignored"
        vals = ["1", "30000", "5", "9", "90", "2700", "x", "u", "d", "web", "http://h:{web}", "", "", "4", "-"]
        os.environ[stack.SETTINGS_ENV] = "".join(v + "\x1f" for v in vals)
        self.assertEqual(stack.settings().values(), vals)
        os.environ[stack.SETTINGS_ENV] = "1\x1f2\x1f"
        self.assertEqual(stack.settings().NAME, "shop")


class Slots(StackCase):
    def setUp(self):
        super().setUp()
        self.machine(1, 2, 24000)

    def test_slot_state(self):
        "slot_state: free, busy, stuck hold-max, heartbeat, no-info, run-ended; a live run keeps a slot without a beat"
        s = self.s()
        self.assertEqual(stack.slot_state(s, 0), "free")
        self.plant(0, beat=False)
        self.assertEqual(stack.slot_state(s, 0), "busy")
        self.plant(0, epoch=int(time.time()) - 5000, beat=False)
        self.assertEqual(stack.slot_state(s, 0), "stuck hold-max")
        self.plant(0, beat=False)
        self.age_beat(0)
        self.assertEqual(stack.slot_state(s, 0), "stuck heartbeat")
        self.plant(0, run=self.tmp, beat=False)
        self.age_beat(0)
        self.assertEqual(stack.slot_state(s, 0), "busy")
        self.plant(0, run=self.tmp, epoch=int(time.time()) - 5000, beat=False)
        self.assertEqual(stack.slot_state(s, 0), "stuck hold-max")
        self.plant(0, run=self.tmp + "/no-such-run", beat=False)
        self.assertEqual(stack.slot_state(s, 0), "stuck run-ended")
        os.remove(stack.slot_dir(0) + "/info")
        self.assertEqual(stack.slot_state(s, 0), "stuck no-info")
        with open(stack.slot_dir(0) + "/info", "w") as f:
            f.write("no newline")
        self.assertEqual(stack.slot_state(s, 0), "stuck no-info")

    def test_reclaim(self):
        "stack_lease reclaims a stuck slot (any reason): logged, its own down run in its cwd, ports freed, files gone"
        cases = (("hold-max", "olduser", "-", int(time.time()) - 5000, False),
                 ("no-info", None, "-", None, False),
                 ("run-ended", "gone", self.tmp + "/no-such-run", None, False),
                 ("heartbeat", "quiet", "-", None, True))
        for reason, owner, run, epoch, old_beat in cases:
            for f in ("calls.log", "lsof.log"):
                if os.path.exists(os.path.join(self.tmp, f)):
                    os.remove(os.path.join(self.tmp, f))
            log = os.path.join(self.home, "logs", "stacks.log")
            if os.path.exists(log):
                os.remove(log)
            beat = self.plant(0, owner, run, epoch)
            if old_beat:
                self.age_beat(0)
            s = self.s()
            self.assertEqual(stack.slot_state(s, 0), "stuck " + reason)
            self.assertEqual(stack.lease(s, "newcomer"), 0, reason)
            self.assertEqual(open(stack.slot_dir(0) + "/info").read().split()[0], "newcomer")
            self.assertRegex(open(log).read(), r"^[0-9T:+Z.,-]+ reclaimed slot 0 from %s %s\n$"
                             % (re.escape(owner or "?"), reason))
            self.assertEqual(self.log("calls.log"), "down slot=0 cwd=%s\n" % self.tmp, reason)
            self.assertIn("-iTCP:24000-24009 -sTCP:LISTEN", self.log("lsof.log"))
            self.assertFalse(os.path.exists(stack.slot_dir(0) + "/beat.pid"), reason)
            if reason == "heartbeat":
                self.assertIsNone(beat.poll(), "the beat pid of a lease found dead is signalled")
            else:
                self.assertTrue(self.gone(beat), "%s: the old beat still runs" % reason)
            stack.slot_release(0)

    def test_release(self):
        "slot_release drops the lock and stops the heartbeat, except for reason heartbeat; no beat.pid or no slot is fine"
        p = self.plant(0)
        stack.slot_release(0)
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))
        self.assertTrue(self.gone(p))
        p = self.plant(0)
        stack.slot_release(0, "heartbeat")
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))
        self.assertIsNone(p.poll())
        for reason in ("hold-max", "run-ended", "no-info"):
            p = self.plant(0)
            stack.slot_release(0, reason)
            self.assertTrue(self.gone(p), reason)
        os.makedirs(stack.slot_dir(0))
        stack.slot_release(0)
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))
        stack.slot_release(0)

    def test_free_range_lsof(self):
        "free_range asks lsof for the slot's listening range and kills -9 what listens, sparing Docker's own"
        s = self.s()
        with open(self.tmp + "/lsof.out", "w") as f:
            f.write("p111\ncnode\np222\nccom.docker.backend\np333\ncdocker-proxy\np444\ncvpnkit-controller\np555\ncpython3\n")
        stack.free_range(s, 1)
        self.assertEqual(self.log("lsof.log"), "-nP -iTCP:24010-24019 -sTCP:LISTEN -Fpc\n")
        self.assertEqual(self.log("kill.log"), "-9 111 555\n")
        os.remove(self.tmp + "/kill.log")
        os.remove(self.tmp + "/lsof.log")
        open(self.tmp + "/lsof.out", "w").close()
        stack.free_range(s, 0)
        self.assertEqual(self.log("lsof.log"), "-nP -iTCP:24000-24009 -sTCP:LISTEN -Fpc\n")
        self.assertIsNone(self.log("kill.log"))
        with open(self.tmp + "/lsof.out", "w") as f:
            f.write("p77\ncdockerd\np88\ncvpnkit\n")
        stack.free_range(s, 0)
        self.assertIsNone(self.log("kill.log"))

    NETSTAT = """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:24010          0.0.0.0:0              LISTENING       4242
  TCP    0.0.0.0:24011          0.0.0.0:0              LISTENING       4343
  TCP    [::]:24012             [::]:0                 LISTENING       4444
  TCP    127.0.0.1:24013        0.0.0.0:0              LISTENING       4545
  TCP    0.0.0.0:24014          0.0.0.0:0              LISTENING       4646
  TCP    0.0.0.0:24015          0.0.0.0:0              LISTENING       4949
  TCP    0.0.0.0:24100          0.0.0.0:0              LISTENING       4747
  TCP    0.0.0.0:24009          0.0.0.0:0              LISTENING       4848
  TCP    127.0.0.1:24016        127.0.0.1:55000        ESTABLISHED     4141
  TCP    0.0.0.0:24010          0.0.0.0:0              LISTENING       4242
"""

    def test_free_range_windows(self):
        "free_range with netstat.exe kills each non-Docker LISTENING pid in the slot's range once; lsof is not used"
        win = self.path("win")
        with open(self.tmp + "/netstat.out", "w") as f:
            f.write(self.NETSTAT)
        _script(win + "/netstat.exe", 'cat "%s/netstat.out"\n' % self.tmp)
        _script(win + "/tasklist.exe", 'pid="${2##* }"\ncase "$pid" in\n'
                '  4242) echo \'"node.exe","4242","Console","1","40,000 K"\' ;;\n'
                '  4343) echo \'"com.docker.backend.exe","4343","Console","1","40,000 K"\' ;;\n'
                '  4444) echo \'"vpnkit.exe","4444","Console","1","40,000 K"\' ;;\n'
                '  4545) echo \'"wslrelay.exe","4545","Console","1","40,000 K"\' ;;\n'
                '  4646) echo \'"docker-proxy.exe","4646","Console","1","40,000 K"\' ;;\n'
                '  4747|4848|4141) echo \'"python.exe","\'"$pid"\'","Console","1","40,000 K"\' ;;\nesac\n')
        _script(win + "/taskkill.exe", 'echo "$*" >> "%s/taskkill.log"\n' % self.tmp)
        with open(self.tmp + "/lsof.out", "w") as f:
            f.write("p999\ncnode\n")
        os.environ["PATH"] = win + os.pathsep + os.environ["PATH"]
        s = self.s()
        stack.free_range(s, 1)
        self.assertEqual(self.log("taskkill.log"), "//PID 4242 //F\n")
        self.assertIsNone(self.log("lsof.log"))
        self.assertIsNone(self.log("kill.log"))
        os.remove(self.tmp + "/taskkill.log")
        stack.free_range(s, 0)
        self.assertEqual(self.log("taskkill.log"), "//PID 4848 //F\n", "slot 0's range is 24000-24009")


class Queue(StackCase):
    def test_tickets(self):
        "tickets are '<19-digit sequence>-<owner>' holding 'pid run solo', the next after the highest, under a lock"
        s = self.s()
        os.environ[stack.PID_ENV] = "4321"
        t1, t2 = stack.queue_ticket(s, "first"), stack.queue_ticket(s, "second")
        self.assertEqual((os.path.basename(t1), os.path.basename(t2)),
                         ("0000000000000000001-first", "0000000000000000002-second"))
        self.assertEqual(open(t1).read(), "4321 - -\n")
        self.assertFalse(os.path.isdir(self.Q + "/.lock"))
        for n in ("0000000000000000009-gap", "junk"):
            open(os.path.join(self.Q, n), "w").close()
        self.assertEqual(os.path.basename(stack.queue_ticket(s, "third")), "0000000000000000010-third")
        os.environ["SHIPFLOOR_RUN_LOCK"] = "/some/run"
        self.assertEqual(open(stack.queue_ticket(s, "fourth")).read(), "4321 /some/run -\n")
        del os.environ["SHIPFLOOR_RUN_LOCK"]
        del os.environ[stack.PID_ENV]
        self.project()
        self.assertEqual(open(stack.queue_ticket(self.s(), "fifth")).read(), "%d - shop\n" % os.getpid())

    def test_arrival_order(self):
        "tickets sort in arrival order: zeta before alpha, and an 11th after the 9th and 10th (not before the 2nd)"
        s = self.s()
        names = ["w%02d" % (100 - i) for i in range(1, 12)]
        for n in names:
            stack.queue_ticket(s, n)
        self.assertEqual([q.split("-", 1)[1] for q in self.queue()], names)

    def sleep_stub(self, script=""):
        _script(self.stubs + "/sleep", 'echo "$*" >> "%s/sleep.log"\n%s' % (self.tmp, script))

    def test_stuck_lock(self):
        "a queue lock nobody frees is waited for 50 tries of 0.1 s, then broken and the ticket taken; the lock goes"
        self.sleep_stub()
        s = self.s()
        os.makedirs(self.Q + "/.lock")
        t = stack.queue_ticket(s, "stuck")
        self.assertEqual(self.log("sleep.log"), "0.1\n" * 50)
        self.assertEqual(os.path.basename(t), "0000000000000000001-stuck")
        self.assertTrue(os.path.isfile(t))
        self.assertFalse(os.path.isdir(self.Q + "/.lock"))

    def test_lock_freed(self):
        "a queue lock that is freed in time is simply waited for"
        s = self.s()
        os.makedirs(self.Q + "/.lock")
        open(self.Q + "/.lock/held", "w").close()
        self.sleep_stub('[ "$(grep -c . "%s/sleep.log")" -ge 3 ] && rm -rf "%s/.lock"\nexit 0\n' % (self.tmp, self.Q))
        t = stack.queue_ticket(s, "patient")
        self.assertTrue(os.path.isfile(t))
        self.assertEqual(self.log("sleep.log"), "0.1\n" * 3)

    def busy_slots(self):
        for k in (0, 1):
            self.plant(k, "holder%d" % k, beat=False)

    def test_wait_gives_up(self):
        "all slots busy: 'waiting, position 1 of 1' once, then 'no free slot after 2s' (exit 3), no ticket left"
        self.busy_slots()
        with self.stderr() as err:
            self.assertIsNone(stack.lease(self.s(), "waiter"))
        self.assertEqual(err[0], "stack: waiting, position 1 of 1\nstack: no free slot after 2s\n")
        self.assertEqual(self.queue(), [])
        with self.stderr():
            self.assertEqual(stack.main(["lease", "waiter"]), 3)

    def test_wait_behind(self):
        "a waiter behind a live ticket says 'position 2 of 2'; the ticket ahead stays when the later one gives up"
        self.busy_slots()
        self.ticket(1, "ahead")
        with self.stderr() as err:
            self.assertIsNone(stack.lease(self.s(), "behind"))
        self.assertEqual(err[0].split("\n")[0], "stack: waiting, position 2 of 2")
        self.assertEqual(self.queue(), ["0000000000000000001-ahead"])

    def test_waiting_note_every_minute(self):
        "a long wait repeats its position once a minute"
        self.machine(2, 125)
        self.busy_slots()
        with self.stderr() as err:
            stack.lease(self.s(), "waiter")
        self.assertEqual(err[0].count("stack: waiting, position 1 of 1"), 3)

    def test_head_served(self):
        "a free slot goes to the head of the queue: a later arrival waits behind a live earlier one, gone ones leave"
        self.machine(1, 2)
        s = self.s()
        self.ticket(1, "zeta")
        with self.stderr():
            self.assertIsNone(stack.lease(s, "alpha"))
        self.assertFalse(os.path.isdir(stack.slot_dir(0)), "the later arrival took the slot")
        self.assertEqual(self.queue(), ["0000000000000000001-zeta"])
        os.remove(os.path.join(self.Q, "0000000000000000001-zeta"))
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.ticket(1, "gone", pid=gone.pid)
        self.ticket(2, "ended", run=self.tmp + "/no-run")
        self.assertEqual(stack.lease(s, "second"), 0)
        self.assertEqual(self.queue(), [])

    def test_lease(self):
        "two leases take slots 0 and 1, recorded in info and beat; a third waits and gives up (3)"
        s = self.s()
        os.environ["SHIPFLOOR_RUN_LOCK"] = ""
        self.assertEqual(stack.lease(s, "a"), 0)
        self.assertEqual(stack.lease(s, "b"), 1)
        owner, run, epoch = open(stack.slot_dir(1) + "/info").read().split()
        self.assertEqual((owner, run), ("b", "-"))
        self.assertLess(abs(int(epoch) - time.time()), 5)
        self.assertTrue(os.path.exists(stack.slot_dir(1) + "/beat"))
        self.assertFalse(os.path.exists(stack.slot_dir(1) + "/solo"))
        with self.stderr() as err:
            self.assertIsNone(stack.lease(s, "c"))
        self.assertIn("stack: no free slot after 2s", err[0])

    def test_solo(self):
        "a solo ticket blocked by its own project's running slot does not hold the queue; a solo run records the run"
        s = self.s()
        stack.lease(s, "a")
        with open(stack.slot_dir(0) + "/solo", "w") as f:
            f.write("shop\n")
        self.ticket(5, "solo", solo="shop")
        self.assertEqual(stack.lease(s, "e"), 1)
        self.assertEqual(self.queue(), ["0000000000000000005-solo"])
        self.assertTrue(stack.solo_busy(s, "shop"))
        self.assertFalse(stack.solo_busy(s, "other"))
        os.remove(os.path.join(self.Q, "0000000000000000005-solo"))
        self.project()
        run = self.path("run")
        os.environ["SHIPFLOOR_RUN_LOCK"] = run
        with self.stderr():
            self.assertIsNone(stack.lease(self.s(), "g1"), "a solo project's second run waits for its first")
        stack.slot_release(0)
        self.assertEqual(stack.lease(self.s(), "g"), 0)
        self.assertEqual(open(stack.slot_dir(0) + "/solo").read(), "shop\n")
        self.assertEqual(open(stack.slot_dir(0) + "/info").read().split()[:2], ["g", run])

    def test_run_lock_gone(self):
        "a waiter whose run lock is gone, or whose shell is gone, gives up (3) and its ticket leaves the queue"
        s = self.s()
        os.environ["SHIPFLOOR_RUN_LOCK"] = self.tmp + "/run-gone"
        with self.stderr():
            self.assertIsNone(stack.lease(s, "g0"))
        self.assertEqual(self.queue(), [])
        del os.environ["SHIPFLOOR_RUN_LOCK"]
        gone = subprocess.Popen(["true"])
        gone.wait()
        os.environ[stack.PID_ENV] = str(gone.pid)
        self.assertIsNone(stack.lease(s, "orphan"))
        self.assertEqual(self.queue(), [])


class Release(StackCase):
    def test_release_run(self):
        "release_run releases the run's slots (also through a symlinked run path) after their down; others stay"
        self.machine(3)
        s = self.s()
        r1, r2 = self.path("run1"), self.path("run2")
        os.symlink(r1, self.tmp + "/link")
        self.plant(0, "x", r1, beat=False)
        self.plant(1, "y", self.tmp + "/link", beat=False)
        self.plant(2, "x", r2, beat=False)
        stack.release_run(s, r1)
        self.assertEqual(sorted(os.listdir(self.L)), ["stack-2.lock", "stack-queue"])
        self.assertEqual(self.log("calls.log"), "down slot=0 cwd=%s\ndown slot=1 cwd=%s\n" % (self.tmp, self.tmp))
        os.remove(self.calls)
        stack.down(s, "x")
        self.assertFalse(os.path.isdir(stack.slot_dir(2)))
        self.assertEqual(self.log("calls.log"), "down slot=2 cwd=%s\n" % self.tmp)
        stack.down(s, "nobody")

    def test_down_beyond_stacks(self):
        "down releases the owner's slots below STACKS only; release_run releases a run's slot whatever its number"
        s = self.s()
        run = self.path("run")
        self.plant(1, "late", beat=False)
        self.plant(2, "late", run, beat=False)
        stack.down(s, "late")
        self.assertFalse(os.path.isdir(stack.slot_dir(1)))
        self.assertTrue(os.path.isdir(stack.slot_dir(2)))
        self.assertEqual(self.log("calls.log"), "down slot=1 cwd=%s\n" % self.tmp)
        stack.down(s, "nobody")
        self.assertTrue(os.path.isdir(stack.slot_dir(2)))
        stack.release_run(s, run)
        self.assertFalse(os.path.isdir(stack.slot_dir(2)))
        self.assertEqual(self.log("calls.log").split("\n")[-2], "down slot=2 cwd=%s" % self.tmp)

    def test_reclaim_logs(self):
        "slot_reclaim logs the owner, or '?' for a lease with no info, with the reason"
        s = self.s()
        self.plant(0, None, beat=False)
        self.plant(1, "z", epoch=int(time.time()) - 5000, beat=False)
        stack.slot_reclaim(s, 0, "no-info")
        stack.slot_reclaim(s, 1, "hold-max")
        log = open(os.path.join(self.home, "logs", "stacks.log")).read()
        self.assertIn("reclaimed slot 0 from ? no-info", log)
        self.assertIn("reclaimed slot 1 from z hold-max", log)
        self.assertEqual(os.listdir(self.L), ["stack-queue"])

    def test_status(self):
        "status: one line per slot '<k> <state> <owner> <held_s> <reason>', then 'queue <n>'"
        s = self.s()
        self.plant(1, "o", epoch=int(time.time()) - 30, beat=False)
        self.ticket(1, "w")
        lines = stack.status(s).split("\n")
        self.assertEqual(lines[0], "0\tfree\t-\t0\t")
        self.assertRegex(lines[1], r"^1\tbusy\to\t(29|30|31)\t$")
        self.assertEqual(lines[2], "queue\t1")
        self.plant(0, "old", epoch=int(time.time()) - 5000, beat=False)
        self.assertRegex(stack.status(s).split("\n")[0], r"^0\tstuck\told\t[0-9]+\thold-max$")


class Env(StackCase):
    def test_slot_vars(self):
        "the slot's environment: slot, stack, one port per name, the URL with its ports; unknown names stay"
        self.machine(2, 2, 26000)
        self.project("up: 'true'", "down: 'true'", "ports: [web, api]", 'url: "http://localhost:{web}/x?a=1&b=two words"')
        s = self.s()
        self.assertEqual(stack.slot_vars(s, 1), [("SHIPFLOOR_SLOT", "1"), ("SHIPFLOOR_STACK", "shipfloor-shop-1"),
                                                 ("SHIPFLOOR_PORT_WEB", "26010"), ("SHIPFLOOR_PORT_API", "26011"),
                                                 ("SHIPFLOOR_STACK_URL", "http://localhost:26010/x?a=1&b=two words")])
        self.assertEqual(stack.fill_ports(s, 1, "http://h:{web}/{api}/{web}/{db}"), "http://h:26010/26011/26010/{db}")
        s.PORTS, s.URL = "web-app db", "http://h:{web-app}/{db}"
        self.assertEqual(dict(stack.slot_vars(s, 1))["SHIPFLOOR_PORT_DB"], "26011")
        self.assertEqual(dict(stack.slot_vars(s, 1))["SHIPFLOOR_STACK_URL"], "http://h:26010/26011")
        self.assertIn("SHIPFLOOR_PORT_WEB-APP", dict(stack.slot_vars(s, 1)))


class Up(StackCase):
    """up and down (the heartbeat a stub process: the real detached one is in stack-cli.test.sh)."""

    DOWN = ("down: 'echo \"down slot=$SHIPFLOOR_SLOT stack=$SHIPFLOOR_STACK web=$SHIPFLOOR_PORT_WEB "
            "url=$SHIPFLOOR_STACK_URL pwd=$PWD\" >> \"%s\"'")

    def setUp(self):
        super().setUp()
        self.machine(1, 3, 26100)
        p = mock.patch.object(stack, "start_heartbeat", lambda d: self.sleeper().pid)
        p.start()
        self.addCleanup(p.stop)
        self.curlstub = self.path("curlstub")
        _script(self.curlstub + "/curl", 'echo "$*" >> "%s/curl.log"\nmode="$(cat "%s/health.mode" 2>/dev/null)"\n'
                'case "$mode" in\n  fail) exit 22 ;;\n  fail-once) echo "body:fine" > "%s/health.mode"; exit 7 ;;\n'
                '  body:*) printf \'%%s\\n\' "${mode#body:}" ;;\nesac\n' % (self.tmp, self.tmp, self.tmp))
        self.work = self.path("w")
        self.here = os.getcwd()
        os.chdir(self.work)
        self.addCleanup(os.chdir, self.here)

    def health(self, mode):
        os.environ["PATH"] = self.curlstub + os.pathsep + os.environ["PATH"]
        if mode:
            with open(self.tmp + "/health.mode", "w") as f:
                f.write(mode + "\n")

    def up(self, owner, *lines, export=None):
        self.project(*lines, self.DOWN % self.calls)
        with self.stderr() as err:
            url = stack.up(self.s(), owner, export=export)
        return url, err[0]

    def curls(self):
        return (self.log("curl.log") or "").splitlines()

    def test_up_fails(self):
        "an up that fails: exit 3, 'stack: up failed:' then the last 20 lines of up.log, down twice, slot given back"
        lines = "".join("echo line %d\n" % i for i in range(1, 31)) + "echo boom >&2\nexit 1\n"
        sh = self.write("up.sh", lines)
        url, err = self.up("failing", "up: 'bash %s'" % sh, "ports: [web]", 'url: "http://localhost:{web}"')
        self.assertIsNone(url)
        self.assertEqual(err, "stack: up failed:\n" + "".join("line %d\n" % i for i in range(12, 31)) + "boom\n")
        self.assertEqual(len(self.log("calls.log").splitlines()), 2)
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))

    def test_healthy(self):
        "a healthy up prints the URL; the down before up runs with the new slot's env; up's output goes to up.log"
        self.machine(2, 3, 26100)
        self.plant(0, "other", beat=False)
        self.health("body:ok")
        exp = self.tmp + "/export"
        url, err = self.up("fine", "up: 'echo up-out; echo up-err >&2; echo \"up slot=$SHIPFLOOR_SLOT\" >> \"%s\"'"
                           % self.calls, "ports: [web, api]", 'url: "http://localhost:{web}/app"',
                           'health: "http://localhost:{api}/health"', "timeout: 3", export=exp)
        self.assertEqual(url, "http://localhost:26110/app")
        self.assertEqual(err, "")
        self.assertEqual(self.curls()[0], "-fsS -m 3 http://localhost:26111/health")
        d = stack.slot_dir(1)
        self.assertEqual(self.log("calls.log"), "down slot=1 stack=shipfloor-shop-1 web=26110 url=http://localhost:"
                         "26110/app pwd=%s\nup slot=1\n" % self.work)
        self.assertEqual(open(d + "/up.log").read(), "up-out\nup-err\n")
        self.assertEqual(open(d + "/cwd").read(), self.work + "\n")
        self.assertTrue(open(d + "/beat.pid").read().strip().isdigit())
        self.assertEqual(open(exp).read().split("\n")[0], "SLOT=1")
        self.assertIn("SHIPFLOOR_PORT_API=26111", open(exp).read())
        os.remove(self.calls)
        stack.down(self.s(), "fine")
        self.assertIn("down slot=1 stack=shipfloor-shop-1", self.log("calls.log"))
        self.assertFalse(os.path.isdir(d))

    def test_env_file(self):
        "the slot's env file: NAME=value lines (slot, stack, URL as it is, one port per name), nothing else"
        self.machine(2, 3, 25000)
        url, _ = self.up("special", "up: 'true'", "ports: [web, api]",
                         'url: "http://localhost:{web}/?a=1&b=two words&c=%20#frag"')
        want = "http://localhost:25000/?a=1&b=two words&c=%20#frag"
        self.assertEqual(url, want)
        self.assertEqual(sorted(open(stack.slot_dir(0) + "/env").read().splitlines()),
                         sorted(["SHIPFLOOR_PORT_API=25001", "SHIPFLOOR_PORT_WEB=25000", "SHIPFLOOR_SLOT=0",
                                 "SHIPFLOOR_STACK=shipfloor-shop-0", "SHIPFLOOR_STACK_URL=" + want]))
        os.remove(self.calls)
        stack.down(self.s(), "special")
        self.assertEqual(len(self.log("calls.log").splitlines()), 1)
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))

    def test_sick(self):
        "a stack never healthy: exit 3, 'not healthy after <T>s at <url>' then up.log; probes take the time left (>= 1)"
        self.health("fail")
        url, err = self.up("sick", "up: 'echo started'", "ports: [web]", 'url: "http://localhost:{web}"',
                           'health: "http://localhost:{web}/health"', "timeout: 2")
        self.assertIsNone(url)
        self.assertEqual(err, "stack: not healthy after 2s at http://localhost:26100/health\nstarted\n")
        self.assertEqual(sorted({c.split()[2] for c in self.curls()}), ["1", "2"])
        self.assertEqual(self.curls()[0], "-fsS -m 2 http://localhost:26100/health")
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))

    def test_clamp(self):
        "a probe that fails once then passes is healthy; a 9 s timeout probes with -m 5"
        self.health("fail-once")
        url, _ = self.up("clamp", "up: 'true'", "ports: [web]", 'url: "http://localhost:{web}"',
                         'health: "http://localhost:{web}/h"', "timeout: 9")
        self.assertEqual(url, "http://localhost:26100")
        self.assertEqual(self.curls()[0], "-fsS -m 5 http://localhost:26100/h")
        self.assertEqual(len(self.curls()), 2)

    def test_reject(self):
        "a body matching REJECT is not healthy, one that does not is; a REJECT grep refuses lets the stack through"
        self.health("body:500 Runtime Error at line 3")
        url, err = self.up("rejected", "up: 'echo started'", "ports: [web]", 'url: "http://localhost:{web}"',
                           'health: "http://localhost:{web}/h"', 'reject: "Runtime Error|Exception"', "timeout: 1")
        self.assertIsNone(url)
        self.assertIn("stack: not healthy after 1s at http://localhost:26100/h", err)
        self.health("body:all good")
        url, _ = self.up("accepted", "up: 'echo started'", "ports: [web]", 'url: "http://localhost:{web}"',
                         'health: "http://localhost:{web}/h"', 'reject: "Runtime Error|Exception"', "timeout: 1")
        self.assertEqual(url, "http://localhost:26100")
        stack.down(self.s(), "accepted")
        self.health("body:x")
        url, err = self.up("bad", "up: 'true'", "ports: [web]", 'url: "http://localhost:{web}"',
                           'health: "http://localhost:{web}/h"', 'reject: "a("', "timeout: 1")
        self.assertEqual(url, "http://localhost:26100")
        self.assertIn("grep", err)

    def test_no_health(self):
        "no health URL: healthy at once, REJECT or not, and no probe"
        self.health(None)
        url, _ = self.up("nohealth", "up: 'true'", "ports: [web]", 'url: "http://localhost:{web}"', 'reject: "anything"',
                         "timeout: 1")
        self.assertEqual(url, "http://localhost:26100")
        self.assertEqual(self.curls(), [])

    def test_file_url(self):
        "file:// health URLs with the real curl: missing is not healthy, present is"
        h = self.tmp + "/health-{web}"
        url, err = self.up("nofile", "up: 'true'", "ports: [web]", 'url: "http://localhost:{web}"',
                           'health: "file://%s"' % h, "timeout: 1")
        self.assertIsNone(url)
        self.assertIn("stack: not healthy after 1s at file://%s/health-26100" % self.tmp, err)
        with open(self.tmp + "/health-26100", "w") as f:
            f.write("ok\n")
        url, _ = self.up("hasfile", "up: 'true'", "ports: [web]", 'url: "http://localhost:{web}"',
                         'health: "file://%s"' % h, "timeout: 1")
        self.assertEqual(url, "http://localhost:26100")

    def test_solo_up(self):
        "a project without an up command (or a broken config) leases a solo slot and gives the configured URL"
        self.project()
        with self.stderr():
            self.assertEqual(stack.up(self.s(), "solo-run"), "http://localhost:3000")
        self.assertEqual(open(stack.slot_dir(0) + "/solo").read(), "shop\n")
        stack.down(self.s(), "solo-run")
        self.write("broken.yml", "layers: not-a-list\nstack: {ports: [Web], up: 1}\n")
        os.environ["FACTORY_CONFIG"] = self.tmp + "/broken.yml"
        with self.stderr():
            self.assertEqual(stack.up(self.s(), "solo-run"), "")
        self.assertEqual(open(stack.slot_dir(0) + "/solo").read(), "project\n")

    def test_interrupted(self):
        "INT/TERM during a command: its ticket goes, a slot it took is downed and given back, exit 3"
        s = self.s()

        def taken(held):
            held.slot = stack.lease(s, "x")
            held.ticket = stack.queue_ticket(s, "w")
            raise stack.Interrupted()
        self.assertEqual(stack._guarded(s, taken), 3)
        self.assertEqual(self.queue(), [])
        self.assertIn("-iTCP:26100-26109 -sTCP:LISTEN", self.log("lsof.log"), "the slot's ports were not freed")
        self.assertFalse(os.path.isdir(stack.slot_dir(0)))
        import signal
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        self.assertRaises(stack.Interrupted, stack._on_signal, 15, None)


class Heartbeat(StackCase):
    def test_loop(self):
        "the heartbeat touches beat every 15 s from /, ignores HUP, and ends soon after its lock dir goes"
        import signal
        d = os.path.join(self.tmp, "locks", "stack-0.lock")
        os.makedirs(d)
        touched = []
        saved_hup = signal.getsignal(signal.SIGHUP)
        here = os.getcwd()
        self.addCleanup(signal.signal, signal.SIGHUP, saved_hup)
        self.addCleanup(os.chdir, here)

        def sleep(secs):
            self._sleep(secs)
            if len(self.slept) == 20:
                os.rmdir(d)
        with mock.patch.object(stack, "_touch", touched.append), mock.patch.object(stack.time, "sleep", sleep):
            self.assertEqual(stack.heartbeat(d), 0)
            self.assertEqual(os.getcwd(), "/")
            self.assertEqual(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)
        self.assertEqual(touched, [d + "/beat", d + "/beat"])
        self.assertEqual(self.slept, [1] * 20)
        self.assertFalse(os.path.exists(d))


class Main(StackCase):
    def run_main(self, *args):
        out = io.BytesIO()
        saved = sys.stdout
        sys.stdout = io.TextIOWrapper(out, encoding="utf-8", write_through=True)
        try:
            with self.stderr() as err:
                rc = stack.main(list(args))
        finally:
            sys.stdout.flush()
            sys.stdout.detach()
            sys.stdout = saved
        return rc, out.getvalue().decode(), err[0]

    def test_usage(self):
        "sf.py stack with no command, an unknown one or the wrong arguments: the usage, exit 2"
        for args in ((), ("bogus",), ("lease",), ("fill-ports", "1"), ("status", "x"), ("up", "--export", "f"),
                     ("slot-release", "1", "2", "3")):
            rc, out, err = self.run_main(*args)
            self.assertEqual(rc, 2, args)
            self.assertEqual(err, stack.USAGE + "\n")

    def test_commands(self):
        "the commands the shim runs print what it reads: settings (NUL-ended), state, ports, env, ticket, lease, url"
        self.machine(1, 2, 24000)
        rc, out, _ = self.run_main("settings")
        self.assertEqual(out.split("\0")[:3], ["1", "24000", "10"])
        self.assertEqual(out.count("\0"), 15)
        self.assertEqual(self.run_main("slot-state", "0")[1], "free\n")
        self.assertEqual(self.run_main("fill-ports", "0", "{api}")[1], "24001")
        self.assertIn("SHIPFLOOR_STACK=shipfloor-shop-0\n", self.run_main("slot-env", "0")[1])
        self.assertTrue(self.run_main("queue-ticket", "t")[1].strip().endswith("0000000000000000001-t"))
        os.remove(os.path.join(self.Q, "0000000000000000001-t"))
        self.assertEqual(self.run_main("lease", "x"), (0, "0\n", ""))
        self.assertEqual(self.run_main("solo-busy", "shop")[0], 1)
        self.assertEqual(self.run_main("status")[1].split("\n")[-2], "queue\t0")
        self.assertEqual(self.run_main("slot-down", "0")[0], 0)
        self.assertEqual(self.run_main("slot-release", "0")[0], 0)
        self.assertEqual(self.run_main("free-range", "0")[0], 0)
        self.assertEqual(self.run_main("down", "x")[0], 0)
        self.assertEqual(self.run_main("release-run", self.tmp)[0], 0)
        self.plant(0, beat=False)
        self.assertEqual(self.run_main("slot-reclaim", "0", "hold-max")[0], 0)
        with mock.patch.object(stack, "start_heartbeat", lambda d: self.sleeper().pid):
            rc, out, _ = self.run_main("up", "--export", self.tmp + "/exp", "u")
        self.assertEqual((rc, out), (0, "http://localhost:{web}\n".replace("{web}", "24000")))
        self.machine(1, 1, 24000)
        rc, out, _ = self.run_main("up", "v")
        self.assertEqual((rc, out), (3, ""))
