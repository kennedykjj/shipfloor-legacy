"""What a launched run gets and does (shipfloor_core/dispatch.py launch, supervise): the agent's argv, stdin, cwd and
environment, the log lines, the model from the card's weight and the machine's table, the step-up after a failed
gate, the deploy script and its rounds, the run's TMPDIR, and what goes when the run ends (its lock, stack slot,
tmp/<n>/, leftover processes). The runs are supervised in this process (dispatch_support)."""
import glob
import json
import os
import re
import shutil
import time

import dashboard
import dispatch_support as ds
from shipfloor_core import dispatch

SCRIPTS = ds.support.SCRIPTS


def today():
    return time.strftime("%Y-%m-%d")


class Base(ds.DispatchCase):
    def setUp(self):
        super().setUp()
        self.machine_cfg()

    def start_line(self, p, n):
        lines = [l for l in self.log(p, n).splitlines() if l.startswith("== start")]
        return lines[-1] if lines else ""

    def flag_model(self, call):
        a = call["argv"]
        return a[a.index("--model") + 1] if "--model" in a else None


class Agent(Base):
    def test_develop_run(self):
        "a develop run: the agent's argv flag for flag, the prompt on stdin, the control checkout, its environment, three log lines"
        self.board(queues={"Ready for Dev": 54})
        os.environ.update(CALLER_VAR="kept as is", FACTORY_BOARD_SNAPSHOT="/caller/snapshot")
        self.assertEqual(self.cycle(), 0)
        try:
            plugin = open(os.path.join(SCRIPTS, ".source")).read().rstrip("\n")
        except OSError:
            plugin = os.path.dirname(SCRIPTS)
        want = ["-p", "--permission-mode", "acceptEdits", "--add-dir", os.environ["FACTORY_WT_ROOT"],
                "--add-dir", self.home + "/tmp", "--add-dir", self.home + "/reviews", "--setting-sources",
                "project,local", "--strict-mcp-config", "--plugin-dir", plugin, "--allowedTools",
                "Read(/%s/**)" % SCRIPTS, "--disallowedTools", "PowerShell", "--append-system-prompt",
                "This is an unattended factory run. A personal CLAUDE.md is for its owner's interactive sessions: what "
                "it says to read or write under ~/.claude (memory, journals, notes, a vault) does not apply here.",
                "--model", "sonnet", "--output-format", "stream-json", "--verbose"]
        call = self.claude_calls()[0]
        self.assertEqual(call["argv"], want)
        self.assertEqual(call["stdin"], "/sf:develop 54", "the prompt, with no newline")
        control = self.home + "/control"
        self.assertEqual((call["cwd"], call["pwd"]), (os.path.realpath(control), control))
        env = call["env"]
        self.assertEqual({k: env.get(k) for k in ("SHIPFLOOR_FACTORY", "SHIPFLOOR_RUN_LOCK", "FACTORY_LANGUAGE",
                                                  "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS",
                                                  "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "FACTORY_HOME", "FACTORY_WT_ROOT",
                                                  "SHIPFLOOR_HOME", "FACTORY_CONFIG", "FACTORY_PROJECT", "CALLER_VAR")},
                         {"SHIPFLOOR_FACTORY": "1", "SHIPFLOOR_RUN_LOCK": self.home + "/locks/develop-54.lock",
                          "FACTORY_LANGUAGE": "en", "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS": "0",
                          "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "FACTORY_HOME": self.home,
                          "FACTORY_WT_ROOT": os.environ["FACTORY_WT_ROOT"], "SHIPFLOOR_HOME": self.shome,
                          "FACTORY_CONFIG": os.environ["FACTORY_CONFIG"], "FACTORY_PROJECT": "shop",
                          "CALLER_VAR": "kept as is"})
        for gone in ("FACTORY_BOARD_SNAPSHOT", "SHIPFLOOR_INFRA_RETRY", "MSYS_NO_PATHCONV", "SHIPFLOOR_TRAILER"):
            self.assertNotIn(gone, env)
        log = open(os.path.join(self.home, "logs", "%s-54-develop.log" % today())).read().splitlines()
        self.assertEqual(len(log), 3)
        self.assertRegex(log[0], r"^== start /sf:develop 54 %s pid=%d model=sonnet weight=standard runtime=claude-code$" % (ds.ISO, os.getpid()))
        self.assertEqual(log[1], "claude says hi")
        self.assertRegex(log[2], r"^== end /sf:develop 54 exit=0 %s outcome=ok$" % ds.ISO)
        self.assertFalse(os.path.exists(self.home + "/locks/develop-54.lock"), "the run's lock goes when it ends")

    def test_AC2_claude_code_runtime_changes_nothing(self):
        "AC-2 no runtime, runtime: claude-code (string or map) and a project's runtime give the same command line, stdin and environment"
        seen = []
        for machine, project in ((None, ""), ("runtime: claude-code", ""),
                                 ("runtime: {default: claude-code, stages: {develop: claude-code}}", ""),
                                 (None, "runtime: claude-code\n")):
            self.machine_cfg(ds.POOL8 + ("\n" + machine if machine else ""))
            if project:
                self.project_cfg(open(ds.FIXTURE_CONFIG, encoding="utf-8").read() + "\n" + project)
            self.board(queues={"Ready for Dev": 54})
            self.launches, self.pending = [], []
            for d in os.listdir(os.path.join(self.home, "locks")):
                os.rmdir(os.path.join(self.home, "locks", d))
            self.assertEqual(self.cycle(runs=False), 0, self.err)
            spec = self.launches[0]
            self.assertEqual(spec.get("runtime"), "claude-code", "the launch names the runtime it uses")
            self.run_pending()
            call = self.claude_calls()[-1]
            self.assertNotIn("SHIPFLOOR_TRAILER", call["env"], "the claude-code trailer is the default one: no variable")
            seen.append((call["argv"], call["stdin"], call["env"]["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"],
                         call["env"]["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], spec["argv"][-2:]))
        self.assertEqual(seen[1:], seen[:1] * 3)

    def test_end_line_has_the_agent_exit(self):
        "the == end line carries the agent's exit code"
        self.board(queues={"Validation": 60})
        self.set_fake(claude={"exit": 3})
        self.cycle()
        self.assertRegex(self.log("validate", 60).splitlines()[-1], r"^== end /sf:validate 60 exit=3 ")

    def state_runs(self):
        import sqlite3
        conn = sqlite3.connect(os.path.join(self.shome, "state.db"))
        try:
            return conn.execute("SELECT project, card, stage, started, ended, exit, outcome, model, weight, runtime, log "
                                "FROM runs").fetchall()
        finally:
            conn.close()

    def test_AC4_run_lands_in_the_database_and_the_log(self):
        "AC-4 a run is a row of runs, started and ended, and the log keeps its == start and == end lines as before"
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0)
        rows = self.state_runs()
        self.assertEqual(len(rows), 1)
        project, card, stage, started, ended, code, outcome, model, weight, runtime, log = rows[0]
        self.assertEqual((project, card, stage, code, outcome, model, weight, runtime),
                         ("shop", 54, "develop", 0, "ok", "sonnet", "standard", "claude-code"))
        self.assertTrue(started and ended)
        text = self.log("develop", 54)
        self.assertIn("== start /sf:develop 54 %s " % started, text)
        self.assertIn("== end /sf:develop 54 exit=0 %s " % ended, text)
        self.assertEqual(os.path.basename(log), "%s-54-develop.log" % today())

    def test_AC4_run_with_no_control_checkout_is_ended_in_the_database(self):
        "AC-4 the run that cannot enter the control checkout is a finished row with exit 1"
        os.rmdir(os.path.join(self.home, "control"))
        self.board(queues={"Ready for Dev": 26})
        self.cycle()
        rows = self.state_runs()
        self.assertEqual([(r[1], r[5], r[6]) for r in rows], [(26, 1, "fail")])
        self.assertTrue(rows[0][4])

    def test_AC4_a_broken_database_never_fails_the_run(self):
        "AC-4 with a corrupt state.db the log is written, the agent runs, the cycle exits 0 and the lock goes"
        with open(os.path.join(self.shome, "state.db"), "wb") as f:
            f.write(b"this is not a sqlite database" * 100)
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0)
        self.assertEqual(self.prompts(), ["/sf:develop 54"])
        lines = self.log("develop", 54).splitlines()
        self.assertTrue(lines[0].startswith("== start /sf:develop 54 "))
        self.assertTrue(lines[-1].startswith("== end /sf:develop 54 exit=0 "))
        self.assertFalse(os.path.exists(self.home + "/locks/develop-54.lock"))

    def test_language_read_at_launch(self):
        "a run starts with the language the project writes in, read when it is launched (overrides.yml beside the config)"
        cfg = self.project_cfg()
        self.write(os.path.join(os.path.dirname(cfg), "overrides.yml"), "language: pt-BR\n")
        self.board(queues={"Ready for Dev": 54})
        self.cycle()
        self.assertEqual(self.claude_calls()[0]["env"]["FACTORY_LANGUAGE"], "pt-BR")

    def test_read_rules(self):
        "a run may read the factory's scripts, and reports-wt only when it exists; it gets no write rule"
        self.board(queues={"Ready for Dev": 54})
        self.cycle(runs=False)
        args = self.launches[0]["argv"]
        i = args.index("--allowedTools")
        self.assertEqual(args[i:i + 4], ["--allowedTools", "Read(/%s/**)" % SCRIPTS, "--disallowedTools", "PowerShell"])
        os.makedirs(os.path.join(self.home, "reports-wt"))
        self.board(queues={"Ready for Dev": 55})
        self.cycle(runs=False)
        args = self.launches[1]["argv"]
        i = args.index("--allowedTools")
        self.assertEqual(args[i:i + 3], ["--allowedTools", "Read(/%s/**)" % SCRIPTS,
                                         "Read(/%s/reports-wt/**)" % os.path.realpath(self.home)])
        self.assertTrue(args[i + 2].startswith("Read(//"), "an absolute path in a rule opens with two slashes")
        self.assertFalse([a for a in args if re.match(r"(Write|Edit)\(", a)])

    def test_no_control_checkout(self):
        "a run that cannot enter the control checkout logs '== end ... exit=1 <date>: no <control>', starts no agent, leaves no lock"
        os.rmdir(os.path.join(self.home, "control"))
        self.board(queues={"Ready for Dev": 26})
        self.cycle()
        end = self.log("develop", 26).splitlines()[-1]
        self.assertRegex(end, r"^== end /sf:develop 26 exit=1 %s: no %s/control" % (ds.ISO, re.escape(self.home)))
        self.assertIn("outcome=fail", end)
        self.assertEqual((self.claude_calls(), os.listdir(os.path.join(self.home, "locks"))), ([], []))
        os.makedirs(os.path.join(self.home, "control"))
        self.cycle()
        self.assertEqual(self.prompts(), ["/sf:develop 26"], "the next cycle starts the card")


class Deploy(Base):
    def test_deploy_run(self):
        "a deploy run is the script: deploy.sh <n> in the control checkout with the run's environment; an agent only on exit 3, then --continue"
        self.board(queues={"Ready for Prod": 47})
        os.environ["FACTORY_BOARD_SNAPSHOT"] = "/caller/snapshot"
        self.set_fake(deploy_exits=[3, 0])
        self.cycle()
        d = self.deploy_calls()
        self.assertEqual([c["argv"] for c in d], [["47"], ["47", "--continue"]])
        self.assertEqual(self.prompts(), ["/sf:deploy 47"])
        self.assertEqual(d[0]["cwd"], os.path.realpath(self.home + "/control"))
        self.assertEqual((d[0]["env"]["SHIPFLOOR_FACTORY"], d[0]["env"]["SHIPFLOOR_RUN_LOCK"]),
                         ("1", self.home + "/locks/deploy-47.lock"))
        self.assertNotIn("FACTORY_BOARD_SNAPSHOT", d[0]["env"])
        log = self.log("deploy", 47).splitlines()
        self.assertRegex(log[0], r"^== start /sf:deploy 47 %s pid=\d+ model=sonnet weight=standard runtime=claude-code$" % ds.ISO)
        self.assertRegex(log[-1], r"^== end /sf:deploy 47 exit=0 %s outcome=ok$" % ds.ISO)

    def test_clean_deploy_needs_no_agent(self):
        "a deploy that exits 0 calls no agent"
        self.board(queues={"Ready for Prod": 47})
        self.cycle()
        self.assertEqual(([c["argv"] for c in self.deploy_calls()], self.prompts()), ([["47"]], []))

    def test_rounds_stop_at_three(self):
        "the deploy loop stops after 3 rounds of exit 3 (4 script calls, 3 agents, the last exit), or when the script succeeds"
        self.board(queues={"Ready for Prod": 47})
        self.set_fake(deploy_exits=[3])
        self.cycle()
        self.assertEqual([c["argv"] for c in self.deploy_calls()], [["47"]] + [["47", "--continue"]] * 3)
        self.assertEqual(self.prompts(), ["/sf:deploy 47"] * 3)
        self.assertIn("== end /sf:deploy 47 exit=3 ", self.log("deploy", 47))
        os.unlink(os.path.join(self.tmp, "deploy.calls"))
        os.unlink(os.path.join(self.tmp, "claude.calls"))
        self.set_fake(deploy_exits=[3, 3, 0])
        self.cycle()
        self.assertEqual((len(self.deploy_calls()), len(self.prompts())), (3, 2))
        self.assertEqual(self.log("deploy", 47).splitlines()[-1][:30], "== end /sf:deploy 47 exit=0 20")


class Models(Base):
    def models(self, machine=None):
        """{'<stage> <n>': model} of one cycle's launches with 54/55 in Ready for Dev, 60 in Validation, 70 in refine."""
        self.machine_cfg(ds.POOL8 + ("\n" + machine if machine else ""))
        self.board(queues={"Ready for Dev": "54 55", "Validation": 60, "Ready for Refinement": 70})
        self.launches, self.pending = [], []
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        rc = self.cycle(runs=False)
        self.assertEqual(rc, 0)
        out = {}
        for s in self.launches:
            a = s["argv"]
            flag = a[a.index("--model") + 1] if "--model" in a else None
            self.assertEqual(flag, s["model"] or None, "the --model flag is the run's model")
            out["%s %s" % (s["p"], s["n"])] = "%s/%s" % (s["model"], s["weight"])
        return out

    def test_weight_from_the_spec(self):
        "the model comes from the card's weight (its spec header): light and standard on sonnet, heavy develop on opus"
        self.card(54, "light")
        self.card(55, "heavy")
        self.card(60, "heavy")
        self.assertEqual(self.models(), {"develop 54": "sonnet/light", "develop 55": "opus/heavy",
                                         "validate 60": "sonnet/heavy", "refine 70": "sonnet/standard"})

    def test_no_weight_is_standard(self):
        "no weight line, another value, two lines, no spec or no worktree: standard, and the run starts"
        self.card(54, header="**Weight:** medium")
        self.card(55, header="**Weight:** light\n**Weight:** heavy")
        self.card(60, header="")
        self.card(70, "-")
        got = self.models("models:\n  stages:\n    develop: {light: haiku, standard: sonnet, heavy: opus}")
        self.assertEqual(got, {"develop 54": "sonnet/standard", "develop 55": "sonnet/standard",
                               "validate 60": "sonnet/standard", "refine 70": "sonnet/standard"})

    def test_machine_table(self):
        "the machine's models.stages: a stage, or one weight of it, set there wins; the rest keep the shipped table"
        self.card(54, "light")
        self.card(55, "heavy")
        self.card(60, "heavy")
        got = self.models("models:\n  stages:\n    develop: {light: haiku}\n    validate: {heavy: opus}")
        self.assertEqual(got, {"develop 54": "haiku/light", "develop 55": "opus/heavy", "validate 60": "opus/heavy",
                               "refine 70": "sonnet/standard"})
        got = self.models("models:\n  stages: {develop: fable, refine: opus}")
        self.assertEqual(got, {"develop 54": "fable/light", "develop 55": "fable/heavy", "validate 60": "sonnet/heavy",
                               "refine 70": "opus/standard"})

    def test_unknown_models(self):
        "an unknown model, stage or agent in the machine config never reaches a command: the shipped model, and the cycle runs"
        got = self.models("models:\n  stages: {develop: gpt, validate: gpt, review: opus}\n  agents: {nobody: opus}")
        self.assertEqual(got, {"develop 54": "sonnet/standard", "develop 55": "sonnet/standard",
                               "validate 60": "sonnet/standard", "refine 70": "sonnet/standard"})

    def test_start_line_is_what_the_dashboard_reads(self):
        "the == start line names model= and weight= last; dashboard.py's RUN_LINE and RUN_MODEL read it, and nothing from a line without model="
        self.card(54, "heavy")
        self.board(queues={"Ready for Dev": 54})
        self.cycle()
        line = self.start_line("develop", 54)
        self.assertTrue(line.endswith(" model=opus weight=heavy runtime=claude-code"), line)
        self.assertEqual(dashboard.RUN_LINE.match(line).group(2, 3), ("develop", "54"))
        self.assertEqual(dashboard.RUN_MODEL.search(line).group(1), "opus")
        self.assertEqual(self.flag_model(self.claude_calls()[0]), "opus")
        self.assertIsNone(dashboard.RUN_MODEL.search("== start /sf:develop 9 2026-10-14T10:00:00-03:00 pid=1"))


class StepUp(Base):
    def setUp(self):
        super().setUp()
        self.board(queues={"Ready for Dev": 54}, snapshot="54\tCoding\tI_1\n")
        self.set_fake(claude={"verdict": "FAIL", "gate": "build"})

    def labels(self):
        return [c for c in self.board_calls() if c.startswith("label ")]

    def marker(self):
        p = os.path.join(self.home, "stepup", "54")
        return open(p).read() if os.path.exists(p) else None

    def test_one_model_up_once(self):
        "a develop run on sonnet that ends on a failed gate: the block comes off and the next run is on opus, once; the marker lasts while in Coding"
        self.cycle()
        log = self.log("develop", 54)
        self.assertIn("model=sonnet", log)
        self.assertRegex(log, r"== step-up /sf:develop 54 sonnet -> opus: gate build failed %s\n" % ds.ISO)
        self.assertTrue(dashboard.STEPUP_LINE.match([l for l in log.splitlines() if l.startswith("== step-up")][0]))
        self.assertEqual(self.marker(), "sonnet\topus\tbuild\n")
        self.assertEqual(self.labels(), ["label 54 remove blocked"])
        self.assertIn("dispatch: #54 failed gate build on sonnet; the next run is on opus", self.out)
        self.board(queues={"Coding": 54}, snapshot="54\tCoding\tI_1\n")  # what the board shows once the block came off
        self.set_fake(claude={"verdict": "FAIL", "gate": "green"})
        self.cycle()
        self.assertEqual(self.log("develop", 54).count("== start"), 2)
        self.assertIn("model=opus", self.start_line("develop", 54))
        self.assertEqual(self.flag_model(self.claude_calls()[1]), "opus")
        self.assertIn("dispatch: #54 runs on opus, one model up after sonnet failed gate build", self.out)
        self.assertEqual(self.log("develop", 54).count("== step-up"), 1, "a stepped-up run steps no further")
        self.assertEqual(len(self.labels()), 1, "its block stays on")
        self.assertEqual(self.marker().split("\t")[1], "opus")
        self.cycle()
        self.assertIn("model=opus", self.start_line("develop", 54), "a card unblocked by hand keeps the higher model")
        self.board(queues={}, snapshot="54\tValidation\tI_1\n")
        self.cycle()
        self.assertIsNone(self.marker(), "the marker goes when the card leaves Coding")

    def test_haiku_steps_to_sonnet(self):
        "haiku steps up to sonnet"
        self.machine_cfg(ds.POOL8 + "\nmodels:\n  stages: {develop: haiku}")
        self.cycle()
        self.assertIn("== step-up /sf:develop 54 haiku -> sonnet: gate build failed", self.log("develop", 54))

    def test_no_step_up_on_rule_gates(self):
        "no step-up when the failed gate is acceptance-intact or qa-amend: a bigger model cannot change a rule"
        wrong = []
        for gate in ("acceptance-intact", "qa-amend"):
            self.set_fake(claude={"verdict": "FAIL", "gate": gate})
            self.cycle()
            if "== step-up" in self.log("develop", 54) or self.marker():
                wrong.append(gate)
        self.assertFalse(wrong, wrong)

    def test_no_step_up(self):
        "no step-up on the top model, off the ladder, for INFRA, a pass, no verdict, an agent that failed, or a validate run"
        cases = [("heavy card", {"verdict": "FAIL"}, None), ("off the ladder", {"verdict": "FAIL"}, "fable"),
                 ("INFRA", {"verdict": "INFRA"}, None), ("pass", {"verdict": "pass"}, None), ("no verdict", {}, None),
                 ("agent exit 1", {"verdict": "FAIL", "exit": 1}, None)]
        wrong = []
        for name, claude, model in cases:
            if name == "heavy card":
                self.card(54, "heavy")
            self.machine_cfg(ds.POOL8 + ("\nmodels:\n  stages: {develop: %s}" % model if model else ""))
            self.set_fake(claude=claude)
            self.cycle()
            if "== step-up" in self.log("develop", 54) or self.marker() or self.labels():
                wrong.append(name)
            if name == "heavy card":
                self.assertIn("model=opus", self.start_line("develop", 54))
                shutil.rmtree(os.path.join(os.environ["FACTORY_WT_ROOT"], "54"))
        self.board(queues={"Validation": 60})
        self.set_fake(claude={"verdict": "FAIL"})
        self.cycle()
        if os.path.exists(os.path.join(self.home, "stepup", "60")) or self.labels():
            wrong.append("validate")
        self.assertEqual(wrong, [])

    def test_lines_in_the_machine_language(self):
        "with language pt-BR the step-up lines are Portuguese; the log's == markers stay English"
        self.machine_cfg(ds.POOL8 + "\nlanguage: pt-BR")
        self.cycle()
        self.assertIn("dispatch: #54 falhou no gate build em sonnet; a próxima execução é em opus", self.out)
        self.assertNotIn("failed gate build on sonnet", self.out)
        log = self.log("develop", 54)
        for marker in ("== start /sf:develop 54", "== end /sf:develop 54 exit=0", "== step-up /sf:develop 54 sonnet -> opus: gate build failed"):
            self.assertIn(marker, log)
        self.board(queues={"Coding": 54})
        self.cycle()
        self.assertIn("dispatch: #54 roda em opus, um modelo acima, depois que sonnet falhou no gate build", self.out)


class RunEnd(Base):
    def test_tmpdir_per_run(self):
        "each run's TMPDIR is <home>/tmp/<n>/tmp, made before it starts, its own temp files land there, and it goes with the run"
        self.board(queues={"Ready for Dev": "54 55", "Ready for Prod": 47})
        mine = os.environ["TMPDIR"] = self.path("cycle-tmp")
        self.cycle()
        calls = {c["stdin"]: c for c in self.claude_calls()}
        for n in ("54", "55"):
            c = calls["/sf:develop " + n]
            self.assertEqual(c["env"]["TMPDIR"], "%s/tmp/%s/tmp" % (self.home, n))
            self.assertTrue(c["tmpdir_is_dir"])
            self.assertTrue(c["tmpfile"].startswith("%s/tmp/%s/tmp/" % (self.home, n)))
            self.assertFalse(os.path.exists(os.path.join(self.home, "tmp", n)))
        self.assertEqual(self.deploy_calls()[0]["env"]["TMPDIR"], "%s/tmp/47/tmp" % self.home)
        self.assertEqual(os.listdir(mine), [], "nothing of the runs' in the cycle's own temp dir")

    def test_stack_slot_and_tmp_go(self):
        "when a run ends its stack slot is released and its tmp/<n>/ removed; another run's slot stays"
        slots = os.path.join(self.shome, "locks")
        os.makedirs(os.path.join(slots, "stack-1.lock"))
        self.write(os.path.join(slots, "stack-1.lock", "info"),
                   "develop-99 %s/locks/develop-99.lock %d\n" % (self.home, time.time()))
        self.board(queues={"Ready for Dev": 26})
        self.set_fake(claude={"stack_slot": True, "scratch": True})
        self.cycle()
        self.assertEqual([d for d in sorted(os.listdir(slots)) if d.endswith(".lock")], ["stack-1.lock"])
        self.assertFalse(os.path.exists(os.path.join(self.home, "tmp", "26")))

    def test_only_its_own_lock(self):
        "a run removes its own lock, never one whose info names another owner by the time it ends"
        self.board(queues={"Ready for Refinement": 25})
        other = self.lock("refine-77")
        self.set_fake(claude={"steal_lock": True})
        self.cycle()
        self.assertTrue(os.path.isdir(other), "another card's lock is left alone")
        lock = os.path.join(self.home, "locks", "refine-25.lock")
        self.assertEqual(open(os.path.join(lock, "info")).read().split()[0], "99999")
        self.assertIn("== end /sf:refine 25 exit=0", self.log("refine", 25))

    def test_cleanup_processes(self):
        "with FACTORY_CLEANUP=1 each ended run has powershell.exe stop what runs under <worktrees>/<n>/ (non-interactive, no profile), lock still held"
        calls = self.path("ps")
        self.script("powershell.exe", r'''
import json, os, sys
home = os.environ["FACTORY_HOME"]
open(os.path.join(%r, "calls"), "a").write(json.dumps({"wt": os.environ.get("SHIPFLOOR_WT"), "argv": sys.argv[1:],
    "locks": sorted(os.listdir(os.path.join(home, "locks")))}) + "\n")
''' % calls)
        os.environ["PATH"] = os.path.join(self.tmp, "bin") + os.pathsep + os.environ["PATH"]
        os.environ["FACTORY_CLEANUP"] = "1"
        self.board(queues={"Ready for Dev": "54 55"})
        self.cycle()
        got = [json.loads(l) for l in open(os.path.join(calls, "calls"))]
        wt = os.environ["FACTORY_WT_ROOT"]
        self.assertEqual([g["wt"] for g in got], [wt + "/54/", wt + "/55/"])
        self.assertEqual(got[0]["argv"][:3], ["-NoProfile", "-NonInteractive", "-Command"])
        script = got[0]["argv"][3]
        self.assertRegex(script.replace("\n", " "), r"Win32_Process.*CommandLine -match")
        self.assertIn("ProcessId -ne $PID", script)
        self.assertIn("develop-54.lock", got[0]["locks"])
        os.unlink(os.path.join(calls, "calls"))
        os.environ["FACTORY_CLEANUP"] = "0"
        self.board(queues={"Ready for Dev": 56})
        self.cycle()
        self.assertFalse(os.path.exists(os.path.join(calls, "calls")), "FACTORY_CLEANUP=0 never calls powershell.exe")


def _use(tid, name, **inp):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}}


def _done(tid):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}}


RESULT = {"type": "result", "subtype": "success", "is_error": False, "result": "All done: #54 is in Validation.",
          "duration_ms": 61000, "duration_api_ms": 42000, "num_turns": 7, "total_cost_usd": 0.42, "session_id": "s-1",
          "usage": {"input_tokens": 120, "output_tokens": 3400, "cache_read_input_tokens": 90000,
                    "cache_creation_input_tokens": 8000}}


class Telemetry(Base):
    def stream(self, *events, **kw):
        self.set_fake(claude=dict(stream=[{"type": "system", "subtype": "init", "session_id": "s-1"}, *events], **kw))
        self.board(queues={"Ready for Dev": 54})
        self.cycle()
        log = self.log("develop", 54).splitlines()
        events = os.path.join(self.home, "logs", "%s-54-develop.events.jsonl" % today())
        runs = os.path.join(self.home, "logs", "runs.jsonl")
        return (log, [json.loads(l) for l in open(events)] if os.path.exists(events) else None,
                [json.loads(l) for l in open(runs)] if os.path.exists(runs) else None)

    def test_stream_log_is_the_text(self):
        "stream-json: the run log holds the result's text between == start and == end, as a plain -p printed it"
        log, _, _ = self.stream({"type": "assistant", "message": {"content": [{"type": "text", "text": "working"}]}},
                                RESULT)
        self.assertEqual(len(log), 3)
        self.assertTrue(log[0].startswith("== start /sf:develop 54 "))
        self.assertEqual(log[1], "All done: #54 is in Validation.")
        self.assertRegex(log[2], r"^== end /sf:develop 54 exit=0 %s outcome=ok$" % ds.ISO)

    def test_result_then_hang_is_stopped(self):
        "an agent that printed its result and stays alive is stopped after SHIPFLOOR_RESULT_GRACE_SEC: the run ends ok, its lock goes"
        os.environ["SHIPFLOOR_RESULT_GRACE_SEC"] = "1"
        self.addCleanup(os.environ.pop, "SHIPFLOOR_RESULT_GRACE_SEC", None)
        t0 = time.time()
        log, _, runs = self.stream(RESULT, hang=60)
        self.assertLess(time.time() - t0, 30, "the run waited for the hanging process")
        self.assertEqual(log[1], "All done: #54 is in Validation.")
        self.assertRegex(log[2], r"^== agent still alive 1s after its result; stopped$")
        self.assertRegex(log[3], r"^== end /sf:develop 54 exit=0 %s outcome=ok$" % ds.ISO)
        self.assertEqual(runs[0]["exit"], 0)
        self.assertFalse(os.path.exists(self.home + "/locks/develop-54.lock"))

    def test_result_then_exit_is_untouched(self):
        "an agent that exits on its own after the result is not reported as stopped"
        os.environ["SHIPFLOOR_RESULT_GRACE_SEC"] = "1"
        self.addCleanup(os.environ.pop, "SHIPFLOOR_RESULT_GRACE_SEC", None)
        log, _, _ = self.stream(RESULT)
        self.assertFalse([l for l in log if "still alive" in l])

    def test_hang_before_result_is_not_stopped(self):
        "silence before any result is work in progress: the guard waits for the result"
        os.environ["SHIPFLOOR_RESULT_GRACE_SEC"] = "1"
        self.addCleanup(os.environ.pop, "SHIPFLOOR_RESULT_GRACE_SEC", None)
        log, _, _ = self.stream(_use("t1", "Bash", command="sleep 3"), 3, _done("t1"), RESULT)
        self.assertFalse([l for l in log if "still alive" in l])

    def test_stream_events_file(self):
        "stream-json: every event goes to <log>.events.jsonl with when it arrived and the run's pid"
        _, events, _ = self.stream(_use("t1", "Read", file_path="a"), _done("t1"), RESULT)
        self.assertEqual([e["event"]["type"] for e in events], ["system", "assistant", "user", "result"])
        self.assertTrue(all(isinstance(e["t"], float) and e["pid"] == os.getpid() for e in events))

    def test_stream_summary(self):
        "stream-json: runs.jsonl gets one line: the run, the CLI's totals, tokens, and seconds per tool and Bash kind"
        _, _, runs = self.stream(
            _use("t1", "Bash", command="bash ~/.shipfloor/factory/gate.sh build 54"), 0.3, _done("t1"),
            _use("t2", "Bash", command="cd x && gh issue view 54"), 0.1, _done("t2"),
            _use("t3", "Read", file_path="a"), _done("t3"), _use("t4", "Edit", file_path="b"), RESULT)
        self.assertEqual(len(runs), 1)
        r = runs[0]
        self.assertEqual({k: r[k] for k in ("stage", "card", "pid", "model", "weight", "exit", "result", "is_error",
                                             "duration_ms", "duration_api_ms", "num_turns", "cost_usd", "unfinished")},
                         {"stage": "develop", "card": "54", "pid": os.getpid(), "model": "sonnet",
                          "weight": "standard", "exit": 0, "result": "success", "is_error": False,
                          "duration_ms": 61000, "duration_api_ms": 42000, "num_turns": 7, "cost_usd": 0.42,
                          "unfinished": 1})
        self.assertEqual(r["tokens"], {"input": 120, "output": 3400, "cache_read": 90000, "cache_creation": 8000})
        self.assertEqual({k: v["n"] for k, v in r["tools"].items()}, {"Bash": 2, "Read": 1})
        self.assertEqual({k: v["n"] for k, v in r["bash"].items()}, {"gate": 1, "gh": 1})
        self.assertGreaterEqual(r["bash"]["gate"]["s"], 0.25, "a tool's time runs from its tool_use to its result")
        self.assertGreaterEqual(r["bash"]["gh"]["s"], 0.05)
        self.assertGreaterEqual(r["seconds"], r["bash"]["gate"]["s"])
        self.assertRegex(r["start"], "^" + ds.ISO + "$")
        self.assertRegex(r["end"], "^" + ds.ISO + "$")

    def test_stream_without_result(self):
        "stream-json that ends with no result: the last assistant text goes to the log, and the summary says so"
        log, _, runs = self.stream({"type": "assistant", "message": {"content": [{"type": "text", "text": "first"}]}},
                                   {"type": "assistant", "message": {"content": [{"type": "text", "text": "last"}]}},
                                   exit=1)
        self.assertEqual(log[1:-1], ["last"])
        self.assertRegex(log[-1], r"^== end /sf:develop 54 exit=1 ")
        self.assertEqual((runs[0]["exit"], runs[0]["result"], runs[0]["tokens"]["output"]), (1, None, None))

    def test_stream_lines_not_json_and_stderr(self):
        "a line that is not JSON reaches the log as it came, and so does what the CLI writes to stderr"
        log, _, runs = self.stream("Error: something broke", "{not json", RESULT, stderr="warning: on stderr")
        self.assertIn("Error: something broke", log)
        self.assertIn("{not json", log)
        self.assertIn("warning: on stderr", log)
        self.assertIn("All done: #54 is in Validation.", log)
        self.assertEqual(runs[0]["parse_errors"], 1)

    def test_usage_limit_text_still_in_the_log(self):
        "the usage-limit message the cycle looks for in run logs comes through from the result's text"
        log, _, _ = self.stream(dict(RESULT, is_error=True, result="You've hit your session limit · resets 3pm"))
        self.assertIn("You've hit your session limit · resets 3pm", log)

    def test_usage_limit_quoted_by_a_tool_is_not_the_limit(self):
        "a file the agent read, or text it wrote into one, that quotes the limit message does not pause the factory"
        quoted = "LIMIT = \"You've hit your session limit \u00b7 resets 6pm\""
        log, _, _ = self.stream(_use("t1", "Read", file_path="a"),
                                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                                                                          "content": quoted}]}},
                                _use("t2", "Edit", file_path="b", new_string=quoted), _done("t2"), RESULT)
        self.assertFalse(any("hit your session limit" in l for l in log), log)
        self.assertTrue(log[-1].endswith("outcome=ok"), log[-1])

    def test_usage_limit_from_any_event_reaches_the_log(self):
        "the usage limit in an event the log does not get (an earlier turn, a system event) is written to it, once"
        said = {"type": "assistant", "message": {"content": [{"type": "text", "text": "You've hit your session limit"}]}}
        log, _, _ = self.stream(said, said, RESULT)
        self.assertEqual(sum("hit your session limit" in l for l in log), 1)
        self.assertIn("All done: #54 is in Validation.", log)
        log, _, _ = self.stream({"type": "system", "subtype": "error", "error": "hit your session limit"})
        self.assertEqual(sum("hit your session limit" in l for l in log), 1)

    def test_plain_text_has_no_telemetry(self):
        "an agent that prints plain text: the log as before, and no events or runs file"
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0)
        self.assertIn("claude says hi", self.log("develop", 54).splitlines())
        self.assertEqual(glob.glob(os.path.join(glob.escape(self.home), "logs", "*.jsonl")), [])

    def test_bash_kind(self):
        "Bash calls sort into gate, board, gh and other by their command"
        from shipfloor_core import telemetry
        self.assertEqual([telemetry.bash_kind(c) for c in (
            "bash ~/.shipfloor/factory/gate.sh green 54", "bash ~/.shipfloor/factory/board.sh move 54 Coding",
            "gh pr view 3", "x=$(gh api user)", "cd wt && gh issue list", "git status", "echo high", None)],
            ["gate", "board", "gh", "gh", "gh", "other", "other", "other"])


class Stopped(Base):
    """A run whose agent ended without doing its stage says so on its == end line and in runs.jsonl (stopped=<why>),
    and the ones that hold the card leave a mark (stopped/<n>); a run that did its stage clears the marks."""

    def report(self, n, outcome, stage="develop", **more):
        d = os.path.join(self.home, "reports-wt", "reports", "%s-thing" % n)
        os.makedirs(d, exist_ok=True)
        self.write(os.path.join(d, "%s-%s.json" % (stage, time.strftime("%Y-%m-%dT%H%M%S"))),
                   json.dumps(dict(issue=n, outcome=outcome, **more)))

    def run54(self, *events, **kw):
        self.set_fake(claude=dict(stream=[dict(RESULT)] if not events else list(events), **kw))
        self.board(queues={"Ready for Dev": 54}, snapshot="54\tReady for Dev\tx\n")
        self.cycle()
        end = [l for l in self.log("develop", 54).splitlines() if l.startswith("== end")][-1]
        runs = os.path.join(self.home, "logs", "runs.jsonl")
        rows = [json.loads(l) for l in open(runs)] if os.path.exists(runs) else []
        mark = os.path.join(self.home, "stopped", "54")
        return end, rows, [l.split("\t")[1:] for l in open(mark).read().splitlines()] if os.path.exists(mark) else []

    def test_blocked_report(self):
        "a blocked report with no round done: stopped=blocked, exit stays 0, the summary says it; a label already holds the card, so no mark"
        self.report(54, "blocked", step=1, reason="Spec Review is full")
        end, rows, marks = self.run54()
        self.assertRegex(end, r"^== end /sf:develop 54 exit=0 %s stopped=blocked outcome=ok$" % ds.ISO)
        self.assertEqual([r["stopped"] for r in rows], ["blocked"])
        self.assertEqual(marks, [])

    def test_infra_report(self):
        "an infra report with no round done: stopped=infra, no mark (the infra retry owns it)"
        self.report(54, "infra", step=1, note="GitHub API rate limit exceeded")
        end, rows, marks = self.run54()
        self.assertIn(" stopped=infra outcome=ok", end)
        self.assertEqual(marks, [])

    def test_owner_only_report_leaves_a_mark(self):
        "a report whose words say the change is the owner's: stopped=owner-only and a mark with the column the run started from"
        self.report(54, "blocked", step=1, reason="owner-only change to .github/workflows/ci.yml; factory may not touch it")
        end, rows, marks = self.run54()
        self.assertIn(" stopped=owner-only outcome=ok", end)
        self.assertEqual(marks, [["develop", "owner-only", "Ready for Dev"]])

    def test_no_report(self):
        "a run that ended well but wrote no report (reports-wt exists): stopped=no-report and a mark"
        os.makedirs(os.path.join(self.home, "reports-wt", "reports"))
        end, rows, marks = self.run54()
        self.assertIn(" stopped=no-report outcome=ok", end)
        self.assertEqual([r["stopped"] for r in rows], ["no-report"])
        self.assertEqual(marks, [["develop", "no-report", "Ready for Dev"]])

    def test_no_reports_wt_claims_nothing(self):
        "without a reports-wt there is nothing to read: the end line is the one it always was"
        end, rows, marks = self.run54()
        self.assertRegex(end, r"^== end /sf:develop 54 exit=0 %s outcome=ok$" % ds.ISO)
        self.assertEqual(([r["stopped"] for r in rows], marks), ([""], []))

    def test_work_is_not_a_stop(self):
        "blocked after rounds, or a report of another outcome, is work done: no stopped=, and the card's marks go"
        self.write(os.path.join(self.home, "stopped", "54"), "1\tdevelop\tno-report\tCoding\n")
        self.report(54, "blocked", step=7, rounds=2, failed_gates=["green"])
        end, rows, marks = self.run54()
        self.assertNotIn("stopped=", end)
        self.assertEqual(marks, [])
        self.write(os.path.join(self.home, "stopped", "54"), "1\tdevelop\tno-report\tCoding\n")
        self.report(54, "done", pr=12)
        end, rows, marks = self.run54()
        self.assertNotIn("stopped=", end)
        self.assertEqual(marks, [])

    def test_usage_limit_is_not_a_stop(self):
        "a run that ended on the usage limit is not judged: no stopped=, no mark (the pause owns it)"
        os.makedirs(os.path.join(self.home, "reports-wt", "reports"))
        end, rows, marks = self.run54(dict(RESULT, is_error=True, result="You've hit your session limit · resets 3pm"))
        self.assertTrue(end.endswith("outcome=usage_limit"), end)
        self.assertNotIn("stopped=", end)
        self.assertEqual(marks, [])

    def test_a_crash_is_not_judged(self):
        "an agent that exits non-zero is not judged and leaves the marks as they were"
        os.makedirs(os.path.join(self.home, "reports-wt", "reports"))
        self.write(os.path.join(self.home, "stopped", "54"), "1\tdevelop\tno-report\tCoding\n")
        end, rows, marks = self.run54(exit=3)
        self.assertIn("exit=3", end)
        self.assertNotIn("stopped=", end)
        self.assertEqual(len(marks), 1)


CODEX_MODELS = """runtime:
  default: codex
  models:
    stages:
      develop: gpt-6-mini
      validate: {light: gpt-6-mini, standard: gpt-6-mini, heavy: gpt-6-sol}
"""


class CodexSandbox(ds.CodexCase):
    def test_AC2_codex_writes_only_where_the_run_may(self):
        "AC-2 a Codex run is sandboxed to workspace-write with the worktrees, tmp and reviews as the only extra writable folders: not the installed scripts, reports-wt, its CODEX_HOME, nor any repo file the gates guard"
        os.makedirs(os.path.join(self.home, "reports-wt"))
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0, self.err)
        argv = self.codex_calls()[0]["argv"]
        self.assertEqual(argv[argv.index("-s") + 1], "workspace-write")
        for unsafe in ("danger-full-access", "--dangerously-bypass-approvals-and-sandbox", "--yolo"):
            self.assertNotIn(unsafe, argv)
        writable = [argv[i + 1] for i, a in enumerate(argv) if a == "--add-dir"]
        self.assertEqual(sorted(writable), sorted([os.environ["FACTORY_WT_ROOT"], self.home + "/tmp", self.home + "/reviews"]))
        roots = [os.environ["FACTORY_WT_ROOT"], self.home + "/tmp", self.home + "/reviews"]
        for folder in writable:
            # independent of where TMPDIR lives: compare by path, not by substring
            for guarded in (SCRIPTS, self.home + "/reports-wt", self.codex_home):
                rel = os.path.relpath(folder, guarded)
                self.assertTrue(rel == ".." or rel.startswith("../"), "%s is, or is under, %s" % (folder, guarded))
            root = next(r for r in roots if folder == r or folder.startswith(r + "/"))
            parts = os.path.relpath(folder, root).split("/")
            for guarded in (".shipfloor", ".github", ".codex", "AGENTS.md"):
                self.assertNotIn(guarded, parts)


class CodexModels(ds.CodexCase):
    def models(self, machine=CODEX_MODELS, queues=None):
        """{'<stage> <n>': the -m flag (None: no flag)} of one cycle's launches."""
        self.machine_cfg(ds.POOL8 + "\n" + machine)
        self.board(queues=queues or {"Ready for Dev": "54 55", "Validation": 60, "Ready for Refinement": 70})
        self.launches, self.pending = [], []
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        self.assertEqual(self.cycle(), 0, self.err)
        out = {}
        for c in self.codex_calls()[-len(self.launches):]:
            out[c["stdin"].split("Card: #")[-1].strip()] = self.flag(c, "-m")
        return out

    def test_AC3_the_configured_codex_model_is_the_run_model(self):
        "AC-3 runtime.models gives a Codex run its model, a stage alone or one weight of it, with the name as written; no model configured is no -m flag"
        self.card(54, "light")
        self.card(55, "heavy")
        self.card(60, "heavy")
        self.assertEqual(self.models(), {"54": "gpt-6-mini", "55": "gpt-6-mini", "60": "gpt-6-sol", "70": None})
        self.assertIn("model=gpt-6-mini", self.start_line("develop", 54))
        self.assertEqual(self.models("runtime: codex"), {"54": None, "55": None, "60": None, "70": None})

    def test_AC3_models_stages_is_for_claude_code_only(self):
        "AC-3 the machine's models.stages (Claude Code's aliases) never reaches a Codex run"
        got = self.models("runtime: codex\nmodels:\n  stages: {develop: haiku, validate: opus, refine: opus}")
        self.assertEqual(got, {"54": None, "55": None, "60": None, "70": None})
        self.assertNotIn("model=haiku", self.start_line("develop", 54))
        self.assertEqual(self.claude_calls(), [])

    def test_AC3_invalid_runtime_models_stop_the_dispatch(self):
        "AC-3 a runtime.ladder that is not a list, an empty model name or an unknown key of runtime.models is an invalid config: exit 2, nothing started"
        self.board(queues={"Ready for Dev": 54})
        for text in ("runtime: {default: codex, ladder: gpt-6-mini}", "runtime: {default: codex, models: {stages: {develop: ''}}}",
                     "runtime: {default: codex, models: {nope: gpt-6-mini}}"):
            self.machine_cfg(ds.POOL8 + "\n" + text)
            self.assertEqual(self.cycle(), 2, (text, self.err, self.out))
        self.assertEqual(self.codex_calls(), [])
        self.machine_cfg(ds.POOL8 + "\n" + CODEX_MODELS + "  ladder: [gpt-6-mini, gpt-6-sol]")
        self.assertEqual(self.cycle(), 0, self.err)

    def failing_develop(self, machine):
        self.machine_cfg(ds.POOL8 + "\n" + machine)
        self.board(queues={"Ready for Dev": 54}, snapshot="54\tCoding\tI_1\n")
        self.set_fake(codex={"verdict": "FAIL", "gate": "build"})
        self.cycle()
        self.assertTrue(self.codex_calls(), "the develop run ran on codex: %s %s" % (self.out, self.err))
        return self.log("develop", 54)

    def test_AC3_a_failed_gate_steps_up_the_runtime_ladder(self):
        "AC-3 a develop run that ends on a failed gate runs again one rung up runtime.ladder, once"
        log = self.failing_develop(CODEX_MODELS + "  ladder: [gpt-6-mini, gpt-6-sol]")
        self.assertRegex(log, r"== step-up /sf:develop 54 gpt-6-mini -> gpt-6-sol: gate build failed %s\n" % ds.ISO)
        self.assertEqual(open(os.path.join(self.home, "stepup", "54")).read(), "gpt-6-mini\tgpt-6-sol\tbuild\n")
        self.board(queues={"Coding": 54}, snapshot="54\tCoding\tI_1\n")
        self.set_fake(codex={"verdict": "FAIL", "gate": "green"})
        self.cycle()
        self.assertEqual(self.flag(self.codex_calls()[1], "-m"), "gpt-6-sol")
        self.assertIn("model=gpt-6-sol", self.start_line("develop", 54))
        self.assertIn("dispatch: #54 runs on gpt-6-sol, one model up after gpt-6-mini failed gate build", self.out)
        self.assertEqual(self.log("develop", 54).count("== step-up"), 1, "a stepped-up run steps no further")

    def test_AC3_no_ladder_no_step_up(self):
        "AC-3 without runtime.ladder, or on its top rung or off it, a failed gate steps nothing up"
        for name, machine in (("no ladder", CODEX_MODELS),
                              ("top rung", CODEX_MODELS.replace("develop: gpt-6-mini", "develop: gpt-6-sol") + "  ladder: [gpt-6-mini, gpt-6-sol]"),
                              ("off the ladder", CODEX_MODELS + "  ladder: [gpt-6-nano, gpt-6-sol]")):
            if os.path.exists(os.path.join(self.home, "stepup", "54")):
                os.unlink(os.path.join(self.home, "stepup", "54"))
            log = self.failing_develop(machine)
            self.assertNotIn("== step-up", log, name)
            self.assertFalse(os.path.exists(os.path.join(self.home, "stepup", "54")), name)

    def start_line(self, p, n):
        lines = [l for l in self.log(p, n).splitlines() if l.startswith("== start")]
        return lines[-1] if lines else ""


OC_MODELS = """runtime:
  default: opencode
  models:
    stages:
      develop: acme/mini
      validate: {light: acme/mini, standard: acme/mini, heavy: acme/sol}
"""


class OpencodeSandbox(ds.OpencodeCase):
    def test_AC2_opencode_runs_with_the_factorys_config_and_permissions(self):
        "AC-2 an opencode run has the factory's OPENCODE_CONFIG_DIR and OPENCODE_DISABLE_PROJECT_CONFIG=1, and its generated permissions deny external_directory outside the worktrees, tmp and reviews, edit on the installed factory and reports-wt (which it may read), and webfetch and websearch"
        os.makedirs(os.path.join(self.home, "reports-wt"))
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0, self.err)
        call = self.opencode_calls()[0]
        self.assertEqual(call["env"]["OPENCODE_CONFIG_DIR"], self.opencode_home, "the factory's, never the owner's")
        self.assertEqual(call["env"]["OPENCODE_DISABLE_PROJECT_CONFIG"], "1")
        rules = self.config_of(call)["permissions"]  # a list of {permission, pattern, action}; the last match wins
        self.assertIsInstance(rules, list)
        decide = lambda permission, path: self.decide(rules, permission, path)
        wt = os.environ["FACTORY_WT_ROOT"]
        for root in (wt, self.home + "/tmp", self.home + "/reviews"):
            self.assertEqual(decide("external_directory", root + "/54/src/x.py"), "allow", root)
            self.assertNotEqual(decide("edit", root + "/54/src/x.py"), "deny", root)
        for outside in ("/etc/passwd", os.path.expanduser("~/.ssh/id_ed25519"), self.home + "/logs/x.log"):
            self.assertEqual(decide("external_directory", outside), "deny", outside)
        for guarded in (SCRIPTS, self.home + "/reports-wt"):
            self.assertEqual(decide("external_directory", guarded + "/a/b.sh"), "allow", "it may read " + guarded)
            self.assertEqual(decide("edit", guarded + "/a/b.sh"), "deny", "it may not write " + guarded)
        for tool in ("webfetch", "websearch"):
            self.assertEqual(decide(tool, "https://example.com/x"), "deny", tool)


class OpencodeModels(ds.OpencodeCase):
    def models(self, machine=OC_MODELS, queues=None):
        """{'<n>': the -m flag (None: no flag)} of one cycle's launches."""
        self.machine_cfg(ds.POOL8 + "\n" + machine)
        self.board(queues=queues or {"Ready for Dev": "54 55", "Validation": 60, "Ready for Refinement": 70})
        self.launches, self.pending = [], []
        for d in os.listdir(os.path.join(self.home, "locks")):
            os.rmdir(os.path.join(self.home, "locks", d))
        self.assertEqual(self.cycle(), 0, self.err)
        out = {}
        for c in self.opencode_calls()[-len(self.launches):]:
            out[c["stdin"].split("Card: #")[-1].strip()] = self.flag(c, "-m")
        return out

    def failing_develop(self, machine, snapshot="54\tCoding\tI_1\n"):
        self.machine_cfg(ds.POOL8 + "\n" + machine)
        self.board(queues={"Ready for Dev": 54}, snapshot=snapshot)
        self.set_fake(opencode={"verdict": "FAIL", "gate": "build"})
        self.cycle()
        self.assertTrue(self.opencode_calls(), "the develop run ran on opencode: %s %s" % (self.out, self.err))
        return self.log("develop", 54)

    def test_AC4_the_configured_model_is_the_run_model(self):
        "AC-4 runtime.models gives an opencode run `-m <provider/model>` for its stage (one weight of it too), as written; no model configured is no -m flag"
        self.card(54, "light")
        self.card(55, "heavy")
        self.card(60, "heavy")
        self.assertEqual(self.models(), {"54": "acme/mini", "55": "acme/mini", "60": "acme/sol", "70": None})
        self.assertIn("model=acme/mini", self.start_line("develop", 54))
        self.assertEqual(self.models("runtime: opencode"), {"54": None, "55": None, "60": None, "70": None})

    def test_AC4_a_model_that_is_not_provider_slash_model_is_invalid(self):
        "AC-4 with runtime opencode a model or ladder name without a provider (`mini`) is an invalid config: exit 2, nothing started"
        self.board(queues={"Ready for Dev": 54})
        for text in ("runtime: {default: opencode, models: {stages: {develop: mini}}}",
                     "runtime: {default: opencode, ladder: [acme/mini, sol]}"):
            self.machine_cfg(ds.POOL8 + "\n" + text)
            self.assertEqual(self.cycle(), 2, (text, self.err, self.out))
        self.assertEqual(self.opencode_calls(), [])
        self.machine_cfg(ds.POOL8 + "\n" + OC_MODELS + "  ladder: [acme/mini, acme/sol]")
        self.assertEqual(self.cycle(), 0, self.err)
        self.assertTrue(self.opencode_calls(), "provider/model names are valid")

    def test_AC4_a_failed_gate_steps_up_the_ladder(self):
        "AC-4 a develop run that ends on a failed gate runs again one rung up runtime.ladder (-m of the next model), once"
        log = self.failing_develop(OC_MODELS + "  ladder: [acme/mini, acme/sol]")
        self.assertRegex(log, r"== step-up /sf:develop 54 acme/mini -> acme/sol: gate build failed %s\n" % ds.ISO)
        self.board(queues={"Coding": 54}, snapshot="54\tCoding\tI_1\n")
        self.set_fake(opencode={"verdict": "FAIL", "gate": "green"})
        self.cycle()
        self.assertEqual(self.flag(self.opencode_calls()[1], "-m"), "acme/sol")
        self.assertEqual(self.log("develop", 54).count("== step-up"), 1, "a stepped-up run steps no further")

    def test_AC4_no_ladder_no_step_up(self):
        "AC-4 without a ladder, on its top rung or off it, a failed gate steps nothing up"
        for name, machine in (("no ladder", OC_MODELS),
                              ("top rung", OC_MODELS.replace("develop: acme/mini", "develop: acme/sol") + "  ladder: [acme/mini, acme/sol]"),
                              ("off the ladder", OC_MODELS + "  ladder: [acme/nano, acme/sol]")):
            if os.path.exists(os.path.join(self.home, "stepup", "54")):
                os.unlink(os.path.join(self.home, "stepup", "54"))
            log = self.failing_develop(machine)
            self.assertNotIn("== step-up", log, name)
            self.assertFalse(os.path.exists(os.path.join(self.home, "stepup", "54")), name)

    def test_AC4_the_providers_models_and_ladder_count_too(self):
        "AC-4 provider.models and provider.ladder give the run its -m and the step-up, as runtime.models and runtime.ladder do"
        os.environ["SF_LLM_KEY"] = "sk-test"
        provider = ("runtime:\n  default: opencode\n  provider:\n    base_url: http://127.0.0.1:9/v1\n    api_key_env: SF_LLM_KEY\n"
                    "    models: {stages: {develop: sf/mini}}\n    ladder: [sf/mini, sf/sol]\n")
        log = self.failing_develop(provider)
        self.assertEqual(self.flag(self.opencode_calls()[0], "-m"), "sf/mini")
        self.assertRegex(log, r"== step-up /sf:develop 54 sf/mini -> sf/sol: gate build failed %s\n" % ds.ISO)

    def start_line(self, p, n):
        lines = [l for l in self.log(p, n).splitlines() if l.startswith("== start")]
        return lines[-1] if lines else ""


class OpencodeProvider(ds.OpencodeCase):
    KEY, SECRET = "SF_LLM_KEY", "sk-opencode-152-9d1f"

    def test_AC5_the_provider_is_an_openai_compatible_one_and_the_key_stays_in_the_environment(self):
        "AC-5 with runtime.provider the generated config points an openai-compatible provider at the base_url, experimental.policies allows only it, the key is `{env:<api_key_env>}` and nowhere as a value, and the run has OPENCODE_DISABLE_MODELS_FETCH=1 and OPENCODE_DISABLE_AUTOUPDATE=1"
        import fake_llm
        llm = fake_llm.FakeLLM("chat-only", ("qwen3-coder",))
        self.addCleanup(llm.stop)
        os.environ[self.KEY] = self.SECRET
        self.machine_cfg(ds.POOL8 + "\nruntime:\n  default: opencode\n  provider:\n    base_url: %s\n    api_key_env: %s\n"
                         "    models: {stages: {develop: sf/qwen3-coder}}" % (llm.base_url, self.KEY))
        self.board(queues={"Ready for Dev": 54})
        self.assertEqual(self.cycle(), 0, self.err)
        call = self.opencode_calls()[0]
        self.assertEqual(self.flag(call, "-m"), "sf/qwen3-coder")
        env = call["env"]
        self.assertEqual((env["OPENCODE_DISABLE_MODELS_FETCH"], env["OPENCODE_DISABLE_AUTOUPDATE"]), ("1", "1"))
        config = self.config_of(call)
        sf = config["providers"]["sf"]
        self.assertIn("openai-compatible", sf["package"])
        self.assertEqual(sf["settings"]["baseURL"], llm.base_url)
        self.assertEqual(sf["settings"]["apiKey"], "{env:%s}" % self.KEY)
        model = next((v for k, v in sf["models"].items() if k.endswith("qwen3-coder")), None)
        self.assertTrue(model and model["capabilities"]["tools"] is True, sf["models"])
        uses = []

        def walk(o):
            for k, v in (o.items() if isinstance(o, dict) else enumerate(o) if isinstance(o, list) else ()):
                if k == "use":
                    uses.append(v)
                walk(v)
        walk(config["experimental"]["policies"])
        self.assertEqual(uses, [["sf"]], "the policies let the run use the provider sf and no other")
        self.assertEqual(env[self.KEY], self.SECRET, "the key comes through the inherited environment")
        for where, text in (("config", env["OPENCODE_CONFIG_CONTENT"]), ("argv", json.dumps(call["argv"])), ("stdin", call["stdin"])):
            self.assertNotIn(self.SECRET, text, where)
        self.assertNotIn(self.SECRET, self.out + self.err + self.log("develop", 54))
