"""What a dispatcher cycle starts and what it leaves: queues, WIP, the machine pool and stage slots, locks, the waits
(PAUSE, usage limit, GitHub limit, working hours), the infra retry, refresh_staged, exit codes and streams, the board
read, the "Blocked by" dependencies it waits on, the markers and tmp/ it cleans, its language, and the control
checkout (shipfloor_core/dispatch.py).

The runs a cycle launches are recorded, not run (DispatchCase.cycle(runs=False)), unless a case needs what a run does."""
import os
import shutil
import subprocess
import time
from unittest import mock

import dispatch_support as ds
from shipfloor_core import cycle as cyclemod, dispatch, project


def dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


class Base(ds.DispatchCase):
    def started(self):
        """'<stage> <card>' of every run the cycles launched, in launch order (refreshes left out)."""
        return ["%s %s" % (s["p"], s["n"]) for s in self.launches if s.get("mode") == "run"]

    def again(self):
        """Forget what was launched (and its locks): the next cycle starts from the same board."""
        shutil.rmtree(os.path.join(self.home, "locks"), ignore_errors=True)
        os.makedirs(os.path.join(self.home, "locks"))
        self.launches, self.pending = [], []


class Queues(Base):
    def test_each_stage_takes_its_queue(self):
        "each stage starts the card waiting in its queue: refine, develop, validate (Validation) and deploy"
        self.machine_cfg()
        self.board(queues={"Ready for Refinement": 25, "Ready for Dev": 40, "Validation": 36, "Ready for Prod": 47})
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.started(), ["refine 25", "develop 40", "validate 36", "deploy 47"])

    def test_wip_limits(self):
        "a full WIP column starts nothing: Spec Review (2) for refine, Coding+Validation (4) for develop"
        self.board(queues={"Ready for Refinement": 25}, counts={"Spec Review": 2})
        self.cycle(runs=False)
        self.board(queues={"Ready for Dev": 40}, counts={"Coding": 4})
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.board(queues={"Ready for Dev": "26 27 28"}, counts={"Coding": 3})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"], "one WIP slot left: one run")

    def test_a_full_wip_says_so_once(self):
        "a full WIP column with cards waiting starts nothing and says which column is full; nothing waiting, nothing said"
        self.board(queues={"Ready for Dev": "40 41"}, counts={"Coding": 4})
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertIn("dispatch: develop: Coding + Validation is full (limits.develop.wip 4); 2 cards wait", self.out)
        self.board(queues={"Ready for Dev": ""})
        self.cycle(runs=False)
        self.assertNotIn("is full", self.out)

    def test_wip_zero_is_no_limit(self):
        "limits.develop.wip: 0 is no limit: a card starts however many are in Coding + Validation (the agent's step 1 reads it so too)"
        self.project_cfg(text=open(ds.FIXTURE_CONFIG, encoding="utf-8").read() + "\nlimits:\n  develop: {wip: 0}\n")
        self.board(queues={"Ready for Dev": "40"}, counts={"Coding": 9})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"])
        self.assertNotIn("is full", self.out)

    def test_low_disk_starts_nothing(self):
        "under the machine's disk floor (free GB, free inodes %) no run starts and the line says where and how much"
        self.board(queues={"Ready for Dev": "40", "Ready for Refinement": "25"})
        with mock.patch.object(dispatch, "_disk_free", lambda path: (int(0.5 * 2 ** 30), 50.0)):
            self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertRegex(self.out, r"dispatch: .* has 0\.5 GB free, the floor is 2 GB; no run starts until there is space")
        self.again()
        with mock.patch.object(dispatch, "_disk_free", lambda path: (50 * 2 ** 30, 4.0)):
            self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertRegex(self.out, r"has 4% of its inodes free, the floor is 10%")
        self.again()
        with mock.patch.object(dispatch, "_disk_free", lambda path: (50 * 2 ** 30, None)):  # Windows: no inodes
            self.cycle(runs=False)
        self.assertEqual(sorted(self.started()), ["develop 40", "refine 25"])

    def test_disk_floor_off_and_set(self):
        "min_free_gb 0 turns the space check off; the machine's own floor replaces the default"
        self.board(queues={"Ready for Dev": "40"})
        free = lambda path: (int(1.5 * 2 ** 30), 50.0)
        self.machine_cfg(ds.POOL8 + "\ndisk: {min_free_gb: 0}")
        with mock.patch.object(dispatch, "_disk_free", free):
            self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"])
        self.again()
        self.machine_cfg(ds.POOL8 + "\ndisk: {min_free_gb: 1}")
        with mock.patch.object(dispatch, "_disk_free", free):
            self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"])
        self.again()
        self.machine_cfg(ds.POOL8 + "\ndisk: {min_free_gb: 1.6}")
        with mock.patch.object(dispatch, "_disk_free", free):
            self.cycle(runs=False)
        self.assertEqual(self.started(), [])

    def test_two_stops_hold_the_card(self):
        "a card whose last two runs stopped without doing their stage waits for the owner: moving the card frees it"
        mark = os.path.join(self.home, "stopped", "40")
        self.write(mark, "1\tdevelop\tno-report\tReady for Dev\n1\tdevelop\towner-only\tReady for Dev\n")
        self.board(queues={"Ready for Dev": "40"}, snapshot="40\tReady for Dev\tx\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertIn("dispatch: #40 stopped twice in a row (owner-only); not started again until you move the card or delete " + mark, self.out)
        self.board(snapshot="40\tCoding\tx\n")  # the owner moved it
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"])
        self.assertFalse(os.path.exists(mark))
        self.assertEqual(self.launches[0]["col"], "Coding", "the run records the column it started from")

    def test_one_stop_does_not_hold(self):
        "one mark is a retry: the card starts again"
        self.write(os.path.join(self.home, "stopped", "40"), "1\tdevelop\tno-report\tReady for Dev\n")
        self.board(queues={"Ready for Dev": "40"}, snapshot="40\tReady for Dev\tx\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"])

    def test_marks_go_with_the_card(self):
        "a stop mark whose card left the board goes with the cycle"
        mark = os.path.join(self.home, "stopped", "40")
        self.write(mark, "1\tdevelop\tno-report\tReady for Dev\n")
        self.board(snapshot="41\tDone\tx\n")
        self.cycle(runs=False)
        self.assertFalse(os.path.exists(mark))

    def test_stage_slots_and_in_flight_runs(self):
        "develop runs 2 at once by default, a live run takes a slot, and a run not yet in a WIP column takes a WIP slot"
        self.board(queues={"Ready for Dev": "26 27"})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26", "develop 27"])
        self.again()
        self.lock("develop-26")
        self.board(queues={"Ready for Dev": "27 28"}, counts={"Coding": 1}, snapshot="26\tCoding\tI26\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 27"], "max 2 develop runs")
        self.again()
        self.lock("refine-30")
        self.board(queues={"Ready for Refinement": "25 26"}, counts={"Spec Review": 1},
                   snapshot="30\tTechnical Refinement\tI30\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), [], "an in-flight refinement counts toward Spec Review's WIP")

    def test_one_run_per_card(self):
        "a card with a live run of any pipeline gets no second run (they would share its worktree)"
        self.lock("develop-26")
        self.lock("develop-36")
        self.board(queues={"Ready for Dev": 26, "Validation": 36})
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])

    def test_deploy_is_serial(self):
        "one deploy at a time in a project, whatever the machine allows"
        self.board(queues={"Ready for Prod": "47 48"})
        self.cycle(runs=False)
        self.again()
        self.machine_cfg("pool: 6\nstages: {deploy: 3}")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["deploy 47"])

    def test_orphans_resume_first(self):
        "an orphan (Coding, no live run) resumes before new cards and already counts toward WIP; Validation is validate's"
        self.board(queues={"Coding": 42, "Ready for Dev": 60}, counts={"Coding": 1})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 42", "develop 60"])
        self.again()
        self.board(queues={"Coding": "42 43", "Validation": 54, "Ready for Dev": 60}, counts={"Coding": 2})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 42", "develop 43", "validate 54"],
                         "two orphans fill develop's slots; no new card")

    def test_top_of_the_board_first(self):
        "the real board.sh over the fake gh: the top card of the owner's order starts, the blocked one is skipped"
        sh = self.write("realboard", '#!/bin/sh\nexec bash "%s/board.sh" "$@"\n' % ds.support.SCRIPTS)
        os.chmod(sh, 0o755)
        gh = self.path("gh")
        os.environ.update({"FACTORY_BOARD": sh, "FACTORY_GH": os.path.join(ds.support.SCRIPTS, "test", "fake-gh"),
                           "FAKE_GH_DIR": gh})
        self.write(os.path.join(self.shome, "registry.tsv"), "shop\t/x/shop\t/x/wt\tmain\n")
        self.machine_cfg("pool: 4\nstages: {refine: 1, develop: 1, validate: 1, deploy: 1}")
        self.write("gh/items.tsv", "PVTI_41\t41\tReady for Dev\nPVTI_9\t9\tInbox\nPVTI_40\t40\tReady for Dev\n"
                                   "PVTI_51\t51\tReady for Refinement\nPVTI_50\t50\tReady for Refinement\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["refine 51", "develop 41"], "one slot: the top card, not the lowest number")
        self.assertIn("orderBy: {field: POSITION, direction: ASC}", open(os.path.join(gh, "calls")).read())
        self.again()
        self.write("gh/items.tsv", "PVTI_41\t41\tReady for Dev\nPVTI_40\t40\tReady for Dev\nPVTI_42\t42\tReady for Dev\n")
        self.write("gh/labels-41", "blocked\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 40"], "the first card that can start")


class Dependencies(Base):
    """A card with an open "Blocked by" dependency is not started (#202): no label, no slot, it stays queued."""
    OPEN = [{"number": 162, "title": "The base", "state": "open"}]

    def touched(self, n):
        """The board calls that name card n (a block would label it, a move would move it)."""
        return [c for c in self.board_calls() if str(n) in c.split()]

    def reads(self, n):
        return [c for c in self.deps_calls() if "/issues/%s/dependencies/blocked_by" % n in " ".join(c)]

    def test_open_dependency_skips_the_card(self):
        "an open dependency: the top card is not started, gets no label or move, the next card starts; deps.json says so"
        self.board(queues={"Ready for Dev": "41 40"})
        self.deps(41, self.OPEN)
        self.assertEqual(self.cycle(runs=False), 0, "waiting is not a failed cycle")
        self.assertEqual(self.started(), ["develop 40"])
        self.assertEqual(self.touched(41), [])
        self.assertEqual(self.deps_record()["41"], {"read": True, "deps": [{"n": 162, "title": "The base", "state": "open"}]})

    def test_waiting_orphan_is_not_resumed(self):
        "an orphan (Coding, no run) with an open dependency is not resumed, and gets no label"
        self.board(queues={"Coding": 60}, counts={"Coding": 1})
        self.deps(60, self.OPEN)
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertEqual(self.touched(60), [])

    def test_every_later_stage_waits(self):
        "validate and deploy candidates wait on an open dependency too"
        self.board(queues={"Validation": 36, "Ready for Prod": 47})
        self.deps(36, self.OPEN)
        self.deps(47, self.OPEN)
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.assertEqual((len(self.reads(36)), len(self.reads(47))), (1, 1))

    def test_starts_once_the_dependency_closes(self):
        "the dependency closes: the next cycle starts the card, with no owner action"
        self.board(queues={"Ready for Dev": 41})
        self.deps(41, self.OPEN)
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.deps(41, [{"number": 162, "title": "The base", "state": "closed"}])
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 41"])

    def test_not_planned_is_closed(self):
        "a dependency closed as not planned does not block, and deps.json records it as closed"
        self.board(queues={"Ready for Dev": 41})
        self.deps(41, [{"number": 162, "title": "Dropped", "state": "closed", "state_reason": "not_planned"}])
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 41"])
        self.assertEqual([(d["n"], d["state"]) for d in self.deps_record()["41"]["deps"]], [(162, "closed")])

    def test_one_rest_read_per_candidate(self):
        "the read is gh api (REST) on project.repo, one call per candidate per cycle, never GraphQL"
        self.board(queues={"Ready for Dev": "41 40"})
        self.deps(41, self.OPEN)
        self.cycle(runs=False)
        self.assertEqual((len(self.reads(41)), len(self.reads(40))), (1, 1))
        self.assertEqual(self.reads(41), [["api", "repos/acme/shop/issues/41/dependencies/blocked_by?per_page=100"]])
        self.assertFalse([c for c in self.deps_calls() if "graphql" in c])

    def test_failed_read_waits_without_blocking(self):
        "an API error or a body that is not a JSON array: not started, not labeled, read false; it starts once GitHub answers"
        self.board(queues={"Ready for Dev": 41})
        self.deps(41, fail=True)
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.started(), [])
        self.assertEqual(self.touched(41), [])
        self.assertEqual(self.deps_record()["41"], {"read": False, "deps": []})
        self.deps(41, '{"message":"Not Found"}', fail=False)
        self.cycle(runs=False)
        self.assertEqual(self.started(), [], "a body that is not an array is an error too")
        self.deps(41, [])
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 41"])

    def test_refinement_never_reads_them(self):
        "refinement starts with open dependencies and does not even read them"
        self.board(queues={"Ready for Refinement": 51})
        self.deps(51, self.OPEN)
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["refine 51"])
        self.assertEqual(self.reads(51), [])


class Pool(Base):
    def test_stage_slots_are_machine_wide(self):
        "a stage's slots count live runs of that stage in every project; other stages still start"
        self.machine_cfg("pool: 6\nstages: {develop: 1}")
        self.lock("develop-9", project_home=os.path.join(self.shome, "projects", "other"))
        self.board(queues={"Ready for Dev": 26, "Ready for Refinement": 25})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["refine 25"])

    def test_pool_caps_every_stage(self):
        "the pool caps the stages together: a pool of 2 with one live run in another project leaves one start"
        self.machine_cfg("pool: 2\nstages: {refine: 2, develop: 2, validate: 2, deploy: 1}")
        self.lock("refine-3", project_home=os.path.join(self.shome, "projects", "other"))
        self.board(queues={"Ready for Refinement": 25, "Ready for Dev": 26, "Validation": 27})
        self.cycle(runs=False)
        self.assertEqual(len(self.started()), 1)

    def test_stage_slots_decide_without_project_cap(self):
        "no project cap by default: develop with 3 stage slots starts 3; a stage with 0 slots never runs"
        self.machine_cfg("pool: 6\nstages: {develop: 3, deploy: 0}")
        self.board(queues={"Ready for Dev": "26 27 28", "Ready for Prod": 47})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26", "develop 27", "develop 28"])

    def test_a_deploy_counts_once(self):
        "a running deploy is ONE unit of the pool, though it holds deploy-<n>.lock and deploysh-<n>.lock"
        self.machine_cfg("pool: 2\nstages: {refine: 2, develop: 2, validate: 2, deploy: 1}")
        self.lock("deploy-9")
        self.lock("deploysh-9")
        self.board(queues={"Ready for Dev": "26 27"})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"])
        self.again()
        self.machine_cfg("pool: 3\nstages: {refine: 3, develop: 3, validate: 3, deploy: 1}")
        self.lock("deploy-9")
        self.lock("deploysh-9")
        self.lock("develop-5", project_home=os.path.join(self.shome, "projects", "other"))
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"], "a deploy and a develop run use 2 of a pool of 3")

    def test_max_parallel(self):
        "SHIPFLOOR_MAX_PARALLEL counts live runs of every project"
        self.machine_cfg()
        self.lock("develop-9", project_home=os.path.join(self.shome, "projects", "other"))
        self.board(queues={"Ready for Dev": "26 27"})
        os.environ["SHIPFLOOR_MAX_PARALLEL"] = "1"
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        os.environ["SHIPFLOOR_MAX_PARALLEL"] = "2"
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"])

    def test_refresh_lock_is_not_a_run(self):
        "a refresh-<n>.lock is a script, not a run: with room for one, a develop run starts beside it; a live run takes it"
        self.machine_cfg()
        os.environ["SHIPFLOOR_MAX_PARALLEL"] = "1"
        self.lock("refresh-61")
        self.board(queues={"Ready for Dev": 54})
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 54"])
        self.again()
        self.lock("develop-5")
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])


class Locks(Base):
    def test_lock_live(self):
        "lock_live: younger than the TTL whatever the pid, past it only while the pid lives; the epoch from info, else the mtime"
        dead, now, me = dead_pid(), int(time.time()), os.getpid()
        cases = [  # (info, dir age, ttl, live)
            ("%d %d 54" % (dead, now - 90), None, 100, True),
            ("%d %d 54" % (dead, now - 400), None, 100, False),
            ("%d %d 54" % (me, now - 400), None, 100, True),
            ("nopid %d 54" % (now - 400), None, 100, False),
            ("%d %d 54" % (dead, now - 10000), None, 10800, True),
            ("-", 400, 100, False),
            ("-", 30, 100, True),
            ("%d" % me, 400, 100, True),
            ("%d" % dead, 400, 100, False),
        ]
        wrong = []
        for i, (info, age, ttl, live) in enumerate(cases):
            d = self.lock("develop-%d" % i, info=info, age=age)
            got = dispatch.lock_live(d, ttl)
            if got != live or os.path.isdir(d) != live:
                wrong.append((info, age, ttl, got, os.path.isdir(d)))
        self.assertEqual(wrong, [], "a live lock stays, a dead one is removed")
        self.assertFalse(dispatch.lock_live(os.path.join(self.tmp, "nolock"), 100))

    def test_cycle_honors_locks(self):
        "a fresh lock (with or without info) holds its card; a stale dead one is replaced; the default TTL is 3 hours"
        self.board(queues={"Ready for Refinement": 25})
        self.lock("refine-25")
        self.cycle(runs=False)
        shutil.rmtree(os.path.join(self.home, "locks", "refine-25.lock"))
        self.lock("refine-25", info="-")
        self.cycle(runs=False)
        self.lock("refine-25", info="%d %d 26" % (dead_pid(), time.time() - 10000))
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.lock("refine-25", info="%d %d 26" % (dead_pid(), time.time() - 20000))
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["refine 25"])

    def test_counting_reclaims_dead_locks(self):
        "counting the pool removes old dead locks (this project's and another's) and keeps the young and the live"
        os.environ["FACTORY_LOCK_TTL"] = "100"
        dead, now = dead_pid(), time.time()
        other = os.path.join(self.shome, "projects", "other")
        old = [self.lock("validate-31", info="%d %d x" % (dead, now - 200)),
               self.lock("develop-33", info="%d %d x" % (dead, now - 200)),
               self.lock("develop-7", info="%d %d 7" % (dead, now - 400), project_home=other)]
        kept = [self.lock("validate-32", info="%d %d x" % (dead, now - 50)),
                self.lock("develop-8", info="%d %d 8" % (os.getpid(), now - 400), project_home=other)]
        self.cycle(runs=False)
        self.assertEqual([os.path.isdir(d) for d in old + kept], [False, False, False, True, True])

    def test_lock_is_there_before_the_run_writes_info(self):
        "the lock dir exists when launch returns, before the run writes info; the next cycle counts it; the run writes info"
        self.board(queues={"Ready for Dev": 54})
        self.cycle(runs=False)
        spec = self.launches[0]
        self.assertEqual((spec["lock_at_launch"], spec["info_at_launch"]), (True, False))
        self.cycle(runs=False)
        self.assertEqual((self.rc, self.started()), (0, ["develop 54"]), "no second run for the card")
        self.run_pending()
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertEqual(self.log("develop", 54).count("== start"), 1)
        self.assertFalse(os.path.exists(spec["dir"]), "the run removed its own lock")

    def test_info_names_the_run(self):
        "info is '<pid> <epoch> <n>': the pid is the process that started the agent (the agent's parent), the epoch its start"
        self.board(queues={"Ready for Dev": 54})
        self.set_fake(claude={"steal_lock": False})
        info = {}
        real = dispatch._work

        def work(spec, agent, deploy, log, *rest):
            info["line"] = open(os.path.join(spec["dir"], "info")).read()
            return real(spec, agent, deploy, log, *rest)
        before = int(time.time())
        with ds.mock.patch.object(dispatch, "_work", work):
            self.cycle()
        pid, epoch, n = info["line"].split()
        self.assertEqual((pid, n), (str(os.getpid()), "54"))
        self.assertTrue(before <= int(epoch) <= int(time.time()))
        self.assertEqual(self.claude_calls()[0]["ppid"], os.getpid())


class Waits(Base):
    def test_pause(self):
        "PAUSE: exit 0, silently, without reading the board"
        self.board(queues={"Ready for Dev": 26})
        open(os.path.join(self.home, "PAUSE"), "w").close()
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual((self.out, self.err, self.board_calls(), self.started()), ("", "", [], []))

    def test_usage_limit(self):
        "a run log whose last run hit the usage limit in the last 30 min stops new runs (exit 0, stdout); older or followed by a start, no"
        self.board(queues={"Ready for Dev": 26})
        p = self.usage_log(age=25 * 60)
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual((self.started(), self.err), ([], ""))
        self.assertIn("dispatch: Claude usage limit hit recently; waiting", self.out)
        os.utime(p, (time.time() - 35 * 60,) * 2)
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"])
        self.again()
        self.usage_log(text="You've hit your session limit\n== start /sf:develop 5\nrunning\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"], "only the log's last run counts")
        self.again()
        self.usage_log(text="== start /sf:develop 5\nall fine\n")
        self.usage_log(name="old/y-5-develop.log")
        self.cycle(runs=False)
        self.assertEqual(self.started(), [], "a log in a folder under logs/ counts too")

    def test_usage_limit_home_with_a_space(self):
        "a SHIPFLOOR_HOME with a space gives the same verdicts"
        shome = self.path("with space", "shome")
        home = os.path.join(shome, "projects", "shop")
        os.makedirs(os.path.join(home, "control"))
        os.environ.update(SHIPFLOOR_HOME=shome, FACTORY_HOME=home)
        self.home = home
        self.board(queues={"Ready for Dev": 26})
        self.usage_log()
        self.cycle(runs=False)
        self.assertEqual(self.started(), [])
        self.usage_log(text="== start /sf:develop 5\nall fine\n")
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 26"])

    def test_github_limit(self):
        "a board read refused for the GitHub API limit (or a secondary one) marks the machine; while the mark is fresh nothing reads or starts"
        mark = os.path.join(self.shome, "github-limited")
        self.board(queues={"Ready for Dev": 60}, fail={"snapshot": "GraphQL: API rate limit already exceeded for user ID 1"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertTrue(os.path.exists(mark))
        self.board(fail={})
        calls = len(self.board_calls())
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertIn("dispatch: GitHub API limit hit recently; waiting", self.out)
        self.assertEqual((self.started(), len(self.board_calls())), ([], calls), "no board read, no start")
        os.utime(mark, (time.time() - 20 * 60,) * 2)
        os.environ["SHIPFLOOR_GITHUB_LIMIT_MIN"] = "30"
        self.cycle(runs=False)
        self.assertEqual(self.started(), [], "SHIPFLOOR_GITHUB_LIMIT_MIN sets the window")
        del os.environ["SHIPFLOOR_GITHUB_LIMIT_MIN"]
        os.utime(mark, (time.time() - 11 * 60,) * 2)
        self.cycle(runs=False)
        self.assertEqual(self.started(), ["develop 60"])
        os.unlink(mark)
        self.board(fail={"snapshot": "gh: Could not resolve to a ProjectV2"})
        self.cycle(runs=False)
        self.assertFalse(os.path.exists(mark), "another board error leaves no mark")
        self.board(fail={"snapshot": "You have exceeded a secondary rate limit"})
        self.cycle(runs=False)
        self.assertTrue(os.path.exists(mark))

    def test_working_hours(self):
        "outside the working hours nothing starts; a window includes its start, excludes its end, may cross midnight"
        self.board(queues={"Ready for Refinement": 25, "Ready for Dev": 40, "Ready for Prod": 47})
        cases = [('["08:00-23:00"]', "08:00", True), ('["08:00-23:00"]', "07:59", False),
                 ('["08:00-23:00"]', "22:59", True), ('["08:00-23:00"]', "23:00", False),
                 ('["20:00-04:00"]', "02:00", True), ('["20:00-04:00"]', "20:00", True),
                 ('["20:00-04:00"]', "12:00", False), ('["20:00-04:00"]', "04:00", False),
                 ('["06:00-08:00", "20:00-23:00"]', "21:00", True), ('["06:00-08:00", "20:00-23:00"]', "12:00", False),
                 (None, "03:00", True), (None, "23:30", True), ("[]", "23:30", True),
                 ('["8-23"]', "23:30", True), ('["23:00-23:00"]', "12:00", True)]
        wrong = []
        for hours, now, runs in cases:
            self.again()
            if hours is None:
                p = os.path.join(self.shome, "config.yml")
                if os.path.exists(p):
                    os.unlink(p)
            else:
                self.machine_cfg("hours: %s" % hours)
            os.environ["SHIPFLOOR_NOW"] = now
            rc = self.cycle(runs=False)
            if (self.started() == ["refine 25", "develop 40", "deploy 47"]) != runs or rc != 0:
                wrong.append((hours, now, rc, self.started()))
            if hours in (None, "[]") and "working hours" in self.out + self.err:
                wrong.append((hours, "spoke of working hours"))
        self.assertEqual(wrong, [])

    def test_outside_hours_the_rest_runs(self):
        "outside the hours only the starts are skipped: the board is read, dead locks reaped, the infra retry, markers and tmp sweep run"
        self.machine_cfg('hours: ["08:00-09:00"]')
        os.environ["SHIPFLOOR_NOW"] = "12:00"
        self.board(queues={"Ready for Dev": 54}, infra=[70], snapshot="5\tDone\tI_5\n70\tValidation\tI_70\n")
        self.write(os.path.join(self.home, "board.tsv"), "stale\n")
        live = self.lock("develop-26")
        dead = self.lock("refine-31", info="999999 %d 31" % (time.time() - 20000))
        for d in ("tmp/5", "tmp/70/junk", "stepup"):
            os.makedirs(os.path.join(self.home, d))
        self.write(os.path.join(self.home, "stepup", "9"), "sonnet\topus\tbuild\n")
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertIn("dispatch: outside working hours; runs start again at 08:00", self.out)
        self.assertEqual(self.started(), [])
        self.assertNotEqual(open(os.path.join(self.home, "board.tsv")).read(), "stale\n")
        self.assertEqual((os.path.isdir(live), os.path.isdir(dead)), (True, False))
        self.assertTrue(os.path.isfile(os.path.join(self.home, "infra", "70")))
        self.assertIn("label 70 remove blocked:infra", self.board_calls())
        for gone in ("tmp/70", "tmp/5", "stepup/9"):
            self.assertFalse(os.path.exists(os.path.join(self.home, gone)), gone)

    def test_malformed_hours_say_so(self):
        "a malformed hours does not fail the cycle: it says runs start at all hours"
        self.machine_cfg('hours: ["8-23"]')
        os.environ["SHIPFLOOR_NOW"] = "23:30"
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertIn("runs start at all hours", self.out + self.err)


class Infra(Base):
    def test_infra_retry_once(self):
        "blocked:infra: tmp/<n>/ cleaned, the label comes off, relaunched once with SHIPFLOOR_INFRA_RETRY=1; the marker outlives the run"
        self.board(queues={"Validation": 70}, infra=[70])
        os.makedirs(os.path.join(self.home, "tmp", "70", "junk"))
        self.cycle()
        self.assertIn("label 70 remove blocked:infra", self.board_calls())
        self.assertIn("SHIPFLOOR_INFRA_RETRY=1", self.launches[0]["envs"])
        self.assertEqual(self.claude_calls()[0]["env"].get("SHIPFLOOR_INFRA_RETRY"), "1")
        self.assertFalse(os.path.exists(os.path.join(self.home, "tmp", "70")))
        marker = os.path.join(self.home, "infra", "70")
        self.assertTrue(os.path.isfile(marker), "the retry's marker outlives the retried run")
        self.board(infra=[])
        self.cycle()
        self.assertFalse(os.path.exists(marker), "a marker whose block cleared is spent")

    def test_second_infra_block_goes_to_the_owner(self):
        "a card already retried and blocked by infrastructure again is labeled blocked, its marker spent, not retried"
        self.board(queues={"Ready for Dev": "54 55"}, infra=[54, 71])
        os.makedirs(os.path.join(self.home, "infra"))
        self.write(os.path.join(self.home, "infra", "71"), "1\n")
        self.cycle(runs=False)
        calls = self.board_calls()
        self.assertIn("label 71 add blocked", calls)
        self.assertIn("label 71 remove blocked:infra", calls)
        self.assertFalse(os.path.exists(os.path.join(self.home, "infra", "71")))
        envs = {s["n"]: s["envs"] for s in self.launches}
        self.assertIn("SHIPFLOOR_INFRA_RETRY=1", envs["54"])
        self.assertNotIn("SHIPFLOOR_INFRA_RETRY=1", envs["55"])
        self.assertFalse(os.path.exists(os.path.join(self.home, "infra", "55")))
        self.again()
        self.cycle(runs=False)
        self.assertNotIn("SHIPFLOOR_INFRA_RETRY=1", self.launches[0]["envs"],
                         "after a second block the card starts without the retry flag")
        self.assertFalse(os.path.exists(os.path.join(self.home, "infra", "54")))


class RefreshStaged(Base):
    def test_off_by_default(self):
        "refresh_staged is off by default: a Staged card is not refreshed"
        self.board(queues={"Staged": 35})
        self.cycle()
        self.assertEqual(self.deploy_calls(), [])

    def test_refresh(self):
        "with refresh_staged: true, deploy.sh <n> --refresh runs outside the agent pool, under refresh-<n>.lock, logged to <date>-<n>-refresh.log; a busy card is skipped"
        self.project_cfg(sed=("environment: production}", "environment: production, refresh_staged: true}"))
        self.machine_cfg("pool: 1\nstages: {refine: 1, develop: 1, validate: 1, deploy: 1}")
        self.lock("refine-3", project_home=os.path.join(self.shome, "projects", "other"))
        self.lock("validate-37")
        self.board(queues={"Staged": "35 36 37"})
        self.cycle(runs=False)
        spec = self.launches[0]
        self.assertTrue(os.path.isdir(spec["dir"]))
        self.run_pending()
        calls = self.deploy_calls()
        self.assertEqual([c["argv"] for c in calls], [["35", "--refresh"], ["36", "--refresh"]])
        self.assertIn("refresh-35.lock", calls[0]["locks"])
        self.assertRegex(calls[0]["infos"]["refresh-35.lock"], r"^%d [0-9]+ 35\n$" % os.getpid())
        self.assertEqual(self.claude_calls(), [], "refreshes use no agent")
        self.assertFalse(os.path.exists(os.path.join(self.home, "locks", "refresh-35.lock")))
        log = os.path.join(self.home, "logs", "%s-35-refresh.log" % time.strftime("%Y-%m-%d"))
        self.assertIn("refresh ran for 35", open(log).read())


class FinishClosed(Base):
    def closed(self, text):
        d = os.path.join(self.tmp, "board", "closed")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Ready for Prod"), "w") as f:
            f.write(text)

    def moves(self):
        return [c for c in self.board_calls() if c.startswith("move ")]

    def test_closed_card_goes_to_done(self):
        "a Ready for Prod card whose issue is closed (its PR merged by hand) is moved to Done and says so"
        self.closed("35\n")  # the deploy's own queue skips a card labelled blocked: nothing else would take it
        self.cycle(runs=False)
        self.assertEqual(self.moves(), ["move 35 Done"])
        self.assertIn("dispatch: #35 is closed and in Ready for Prod; moved to Done", self.out)

    def test_busy_card_is_left(self):
        "a card with a live run is not moved"
        self.lock("deploy-35")
        self.closed("35\n")
        self.cycle(runs=False)
        self.assertEqual(self.moves(), [])

    def test_read_failure_fails_the_cycle(self):
        "a failed read of the closed cards fails the cycle and moves nothing"
        self.board(fail={"closed Ready for Prod": "gh: HTTP 502"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertEqual(self.moves(), [])


class Exits(Base):
    def test_invalid_project_config(self):
        "an invalid project config: exit 2, on stderr, nothing on stdout, the board never read"
        p = self.project_cfg("project: {name: broken}\n")
        self.board(queues={"Ready for Dev": 26})
        self.assertEqual(self.cycle(runs=False), 2)
        self.assertIn("dispatch: invalid config %s" % p, self.err)
        self.assertEqual((self.out, self.board_calls()), ("", []))

    def test_invalid_machine_config(self):
        "an invalid machine config: exit 2, on stderr, nothing starts"
        self.machine_cfg("pool: 0")
        self.board(queues={"Ready for Dev": 26})
        self.assertEqual(self.cycle(runs=False), 2)
        self.assertIn("dispatch: invalid %s/config.yml" % self.shome, self.err)
        self.assertEqual(self.started(), [])

    def test_outside_a_project(self):
        "outside a registered project: exit 2 and says so"
        for k in ("FACTORY_CONFIG", "FACTORY_HOME"):
            del os.environ[k]
        os.chdir(self.path("nowhere"))
        self.assertEqual(self.cycle(runs=False), 2)
        self.assertIn("is not in a registered project (shipfloor add <repo>)", self.err)

    def test_board_failures(self):
        "a failed board read: exit 1, its error and the dispatcher's on stderr, nothing starts, no lock; a failed queue read fails the cycle but the others run"
        self.board(queues={"Ready for Dev": 26, "Ready for Refinement": 25}, fail={"snapshot": "board: snapshot failed"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertIn("board: snapshot failed", self.err)
        self.assertIn("dispatch: board read failed", self.err)
        self.assertEqual((self.out, self.started(), os.listdir(os.path.join(self.home, "locks"))), ("", [], []))
        self.board(fail={"eligible Ready for Refinement": "board: eligible failed"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertEqual(self.started(), ["develop 26"])

    def test_control_refresh_failure(self):
        "a control checkout that cannot be refreshed: exit 1, on stderr, no run, no lock"
        os.environ.update(FACTORY_CONTROL_REFRESH="1", FACTORY_REPO=self.path("notarepo"))
        self.board(queues={"Ready for Dev": 26})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertIn("dispatch: could not refresh %s/control from origin/main" % self.home, self.err)
        self.assertEqual((self.started(), os.listdir(os.path.join(self.home, "locks"))), ([], []))

    def test_quiet_success(self):
        "a cycle with nothing queued, or one that starts a run, exits 0"
        self.assertEqual(self.cycle(runs=False), 0)
        self.board(queues={"Ready for Dev": 26})
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.started(), ["develop 26"])


class BoardRead(Base):
    def test_snapshot_through_a_temp_file(self):
        "the board is read into board.tsv.<pid>.tmp, moved over board.tsv when whole; the runs read the live board"
        self.board(snapshot="7\tCoding\tI_7\n", queues={"Ready for Dev": 26})
        seen = self.path("seen")
        real = os.environ["FACTORY_BOARD"]
        w = self.write("bin/board-ls", '#!/bin/sh\n[ "$1" != snapshot ] || ls "$FACTORY_HOME" > "%s/ls"\nexec "%s" "$@"\n'
                       % (seen, real))
        os.chmod(w, 0o755)
        os.environ["FACTORY_BOARD"] = w
        self.cycle(runs=False)
        names = open(os.path.join(seen, "ls")).read().split()
        self.assertIn("board.tsv.%d.tmp" % os.getpid(), names)
        self.assertNotIn("board.tsv", names)
        self.assertEqual(open(os.path.join(self.home, "board.tsv")).read(), "7\tCoding\tI_7\n")
        self.assertEqual([f for f in os.listdir(self.home) if f.endswith(".tmp")], [])

    def test_failed_read_keeps_the_last(self):
        "a failed read leaves the board.tsv before it alone and no temp file"
        self.write(os.path.join(self.home, "board.tsv"), "7\tCoding\tI_7\n")
        self.board(fail={"snapshot": "partial"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertEqual(open(os.path.join(self.home, "board.tsv")).read(), "7\tCoding\tI_7\n")
        self.assertEqual([f for f in os.listdir(self.home) if f.endswith(".tmp")], [])


class Markers(Base):
    def markers(self):
        for d in ("cost", "stepup"):
            os.makedirs(os.path.join(self.home, d), exist_ok=True)
        for n in (54, 55, 56):
            self.write(os.path.join(self.home, "cost", "%d.json" % n), '{"total": 1}\n')
        for n in (54, 56, 57, 58):
            self.write(os.path.join(self.home, "stepup", str(n)), "sonnet\topus\tbuild\n")
        self.lock("develop-58")

    def left(self):
        return sorted(os.listdir(os.path.join(self.home, "cost"))), sorted(os.listdir(os.path.join(self.home, "stepup")))

    def test_markers_go_with_their_card(self):
        "cost/<n>.json goes when its card leaves the board; stepup/<n> when it leaves Coding, unless a live run holds it"
        self.markers()
        self.board(snapshot="54\tCoding\tI_54\n56\tValidation\tI_56\n")
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertEqual(self.left(), (["54.json", "56.json"], ["54", "58"]))

    def test_an_empty_read_removes_nothing(self):
        "an empty board.tsv (or one blank line) proves nothing: no marker goes"
        self.markers()
        for snap in ("", "\n"):
            self.board(snapshot=snap)
            self.assertEqual(self.cycle(runs=False), 0)
            self.assertEqual(self.left(), (["54.json", "55.json", "56.json"], ["54", "56", "57", "58"]))
        self.assertEqual(open(os.path.join(self.home, "board.tsv")).read(), "\n")


class TmpSweep(Base):
    def old(self, *paths):
        t = time.time() - 5 * 86400
        for p in paths:
            os.utime(os.path.join(self.home, "tmp", p), (t, t))

    def sweep(self, board="5\tDone\tI5\n6\tCoding\tI6\n7\tDone\tI7\n"):
        if board is not None:
            self.write(os.path.join(self.home, "board.tsv"), board)
        removed = project.sweep_tmp()
        return removed, sorted(os.listdir(os.path.join(self.home, "tmp")))

    def mk(self, *names, files=()):
        for n in names:
            os.makedirs(os.path.join(self.home, "tmp", n), exist_ok=True)
        for f in files:
            self.write(os.path.join(self.home, "tmp", f), "x\n")

    def test_card_folders(self):
        "sweep_tmp: the tmp/<n>/ of a card Done or off the board goes; an active card's and a running one's stay"
        self.mk("5/x", "6/x", "7", "8")
        self.lock("deploy-7", info="-")
        self.assertEqual(self.sweep(), (["tmp/5", "tmp/8"], ["6", "7"]))

    def test_strays(self):
        "loose files and folders go once untouched for 3 days (a folder is as fresh as its newest file); an active card's strays stay"
        self.mk("ux5", files=("green.txt", "ux5/a.png", "5-pw.txt", "fresh.txt"))
        self.old("green.txt", "ux5/a.png", "ux5", "5-pw.txt")
        self.assertEqual(self.sweep()[1], ["fresh.txt"])
        shutil.rmtree(os.path.join(self.home, "tmp"))
        self.mk("ux5", files=("ux5/old.png",))
        self.old("ux5/old.png", "ux5")
        self.mk(files=("ux5/new.png",))
        self.assertEqual(self.sweep()[1], ["ux5"])
        self.assertTrue(os.path.exists(os.path.join(self.home, "tmp", "ux5", "old.png")))
        shutil.rmtree(os.path.join(self.home, "tmp"))
        self.mk("ux6", files=("6-build.log", "v6-shot.png"))
        self.old("6-build.log", "v6-shot.png", "ux6")
        self.assertEqual(self.sweep()[1], ["6-build.log", "ux6", "v6-shot.png"])

    def test_no_board_no_sweep(self):
        "with no board read nothing goes: an empty board.tsv, or none"
        self.mk("6", files=("green.txt",))
        self.old("green.txt")
        self.assertEqual(self.sweep("\n"), ([], ["6", "green.txt"]))
        os.unlink(os.path.join(self.home, "board.tsv"))
        self.assertEqual(self.sweep(None), ([], ["6", "green.txt"]))

    def test_every_cycle_sweeps(self):
        "the dispatcher sweeps at the end of every cycle and prints each thing it removed"
        self.mk("5", "56/tmp/left", files=("green.txt",))
        self.old("green.txt")
        self.board(snapshot="5\tDone\tI5\n56\tCoding\tI56\n")
        self.cycle(runs=False)
        self.assertIn("dispatch: removed tmp/5\n", self.out)
        self.assertIn("dispatch: removed tmp/green.txt\n", self.out)
        self.assertTrue(os.path.isdir(os.path.join(self.home, "tmp", "56", "tmp", "left")))


class Language(Base):
    def test_lines_in_the_machine_language(self):
        "with language pt-BR the dispatcher's lines come out in Portuguese (usage limit, hours, board failure); with en or none, English"
        self.usage_log()
        self.machine_cfg("language: pt-BR")
        self.assertEqual(self.cycle(runs=False), 0)
        self.assertIn("dispatch: limite de uso do Claude atingido há pouco; aguardando", self.out)
        self.assertNotIn("usage limit hit recently", self.out)
        self.machine_cfg("language: en")
        self.cycle(runs=False)
        self.assertIn("dispatch: Claude usage limit hit recently; waiting", self.out)
        os.unlink(self.usage_log())
        self.machine_cfg('language: pt-BR\nhours: ["08:00-09:00"]')
        os.environ["SHIPFLOOR_NOW"] = "12:00"
        self.cycle(runs=False)
        self.assertIn("dispatch: fora do horário de trabalho; as execuções voltam a começar às 08:00", self.out)
        self.assertNotIn("outside working hours", self.out)
        self.machine_cfg("language: pt-BR")
        self.board(fail={"snapshot": "x"})
        self.assertEqual(self.cycle(runs=False), 1)
        self.assertIn("dispatch: a leitura do quadro falhou", self.err)

    def test_lines_before_the_language_is_read(self):
        "a line printed before the machine config is read is English whatever the language (invalid config, invalid machine config)"
        self.machine_cfg("language: pt-BR\npool: 0")
        self.assertEqual(self.cycle(runs=False), 2)
        self.assertIn("dispatch: invalid %s/config.yml" % self.shome, self.err)
        self.machine_cfg("language: pt-BR")
        p = self.project_cfg("project: {name: broken}\n")
        self.assertEqual(self.cycle(runs=False), 2)
        self.assertIn("dispatch: invalid config %s" % p, self.err)


class Control(Base):
    """refresh_control: the control checkout is exactly origin/<FACTORY_MAIN> (real git: that is the behavior)."""

    def setUp(self):
        super().setUp()
        self.remote = self.path("remote.git")
        self.git("init", "-q", "--bare", self.remote)
        self.repo = self.path("repo")
        self.git("init", "-q", "-b", "main", self.repo)
        self.commit("marker", "v1")
        self.git("-C", self.repo, "remote", "add", "origin", self.remote)
        self.git("-C", self.repo, "push", "-q", "origin", "main")
        shutil.rmtree(os.path.join(self.home, "control"))
        os.environ.update(FACTORY_CONTROL_REFRESH="1", FACTORY_REPO=self.repo)
        self.board(queues={"Ready for Dev": 26})
        self.control = os.path.join(self.home, "control")

    def commit(self, name, text):
        self.write(os.path.join(self.repo, name), text + "\n")
        self.git("-C", self.repo, "add", "-A")
        self.git("-C", self.repo, "commit", "-qm", name + " " + text)
        return self.git("-C", self.repo, "rev-parse", "HEAD")

    def test_tracks_origin_main(self):
        "the control checkout is made at origin/main, follows it, and drops local edits"
        self.cycle(runs=False)
        self.assertEqual(open(os.path.join(self.control, "marker")).read(), "v1\n")
        self.commit("marker", "v2")
        self.git("-C", self.repo, "push", "-q", "origin", "main")
        self.write(os.path.join(self.control, "marker"), "tampered\n")
        self.again()
        self.cycle(runs=False)
        self.assertEqual(open(os.path.join(self.control, "marker")).read(), "v2\n")
        self.assertEqual(self.started(), ["develop 26"])

    def test_main_named_otherwise(self):
        "FACTORY_MAIN=trunk: the control checkout is origin/trunk, and needs no origin/main"
        self.git("-C", self.repo, "checkout", "-qb", "trunk")
        sha = self.commit("trunk.txt", "trunk")
        self.git("-C", self.repo, "push", "-q", "origin", "trunk")
        self.git("-C", self.remote, "symbolic-ref", "HEAD", "refs/heads/trunk")
        self.git("-C", self.repo, "push", "-q", "origin", "--delete", "main")
        os.environ["FACTORY_MAIN"] = "trunk"
        self.cycle(runs=False)
        self.assertEqual(self.git("-C", self.control, "rev-parse", "HEAD"), sha)
        self.assertEqual(self.started(), ["develop 26"])
        sha = self.commit("more.txt", "more")
        self.git("-C", self.repo, "push", "-q", "origin", "trunk")
        self.again()
        self.cycle(runs=False)
        self.assertEqual(self.git("-C", self.control, "rev-parse", "HEAD"), sha)


class CycleUsageLimit(Base):
    def test_cycle_reads_only_run_logs(self):
        "the cycle's usage-limit check reads projects/<p>/logs/*.log only, and only each log's last run"
        h = self.path("h")
        hit = "== start /sf:develop 5\nYou have hit your session limit\n"
        for d in ("projects/shop/tmp/5/tmp/x/projects/blog/logs", "projects/shop/tmp/5/tmp/y/logs"):
            self.write(os.path.join(h, d, "x-5-develop.log"), hit)
        self.write(os.path.join(h, "projects/shop/logs/2026-10-14-7-develop.log"), "== start /sf:develop 7\nall fine\n")
        self.assertFalse(cyclemod.usage_limited(h), "fake logs under a card's tmp/ are not run logs")
        p = self.write(os.path.join(h, "projects/shop/logs/2026-10-14-8-develop.log"), hit)
        self.assertTrue(cyclemod.usage_limited(h))
        os.utime(p, (time.time() - 40 * 60,) * 2)
        self.assertFalse(cyclemod.usage_limited(h), "older than 30 minutes")
        self.write(os.path.join(h, "projects/shop/logs/2026-10-14-8-develop.log"), hit + "== end\n== start /sf:develop 8\nok\n")
        self.assertFalse(cyclemod.usage_limited(h), "only the log's last run counts")
