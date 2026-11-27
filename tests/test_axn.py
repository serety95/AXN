"""AXN regression test suite (zero external dependencies)."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

AXN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_bash():
    if os.name == "nt":
        git_bash = r"C:\Program Files\Git\bin\bash.exe"
        if os.path.isfile(git_bash):
            return git_bash
    found = shutil.which("bash")
    if found and os.name == "nt" and found.lower().endswith(r"\system32\bash.exe"):
        # Avoid WSL shim when running Windows-path subprocess tests
        return None
    return found


BASH_BIN = find_bash()


class ManifestIntegrityTests(unittest.TestCase):
    def test_profiles_reference_existing_modules_and_paths(self):
        with open(os.path.join(AXN_ROOT, "manifests", "install-modules.json"), "r", encoding="utf-8") as fh:
            modules_doc = json.load(fh)
        with open(os.path.join(AXN_ROOT, "manifests", "install-profiles.json"), "r", encoding="utf-8") as fh:
            profiles_doc = json.load(fh)

        mod_map = {m["id"]: m for m in modules_doc["modules"]}
        for pname, pobj in profiles_doc["profiles"].items():
            for mid in pobj["modules"]:
                self.assertIn(mid, mod_map, f"Profile '{pname}' references unknown module '{mid}'")
        for mid, mod in mod_map.items():
            for rel in mod["paths"]:
                self.assertTrue(
                    os.path.exists(os.path.join(AXN_ROOT, rel)),
                    f"Module '{mid}' references missing path '{rel}'",
                )

    def test_cost_tiers_has_relative_costs(self):
        cost_yaml = os.path.join(AXN_ROOT, "config", "cost-tiers.yaml")
        with open(cost_yaml, "r", encoding="utf-8") as fh:
            text = fh.read()
        for tier in ("T0_local:", "T1_scout:", "T2_builder:", "T3_architect:"):
            self.assertIn(tier, text)
        self.assertGreaterEqual(text.count("relative_cost:"), 4)


class LearnRouterTests(unittest.TestCase):
    def test_cli_self_test_and_roi_pipeline(self):
        script = os.path.join(AXN_ROOT, "scripts", "learn-router.py")
        res = subprocess.run([sys.executable, script, "--self-test"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        with tempfile.TemporaryDirectory(prefix="axn-test-state-") as tmp:
            env = dict(os.environ, AXN_STATE_DIR=tmp)
            for idx in range(3):
                payload = json.dumps({
                    "task_type": "lint_fix",
                    "stack": "python",
                    "initial_tier": "T1",
                    "final_tier": "T1",
                    "retries": 0,
                    "escalated": False,
                    "escalated_effort": False,
                    "passed": True,
                    "instincts_used": ["bounded-slice-reads"],
                    "failure_signatures": ["ruff:.py"] if idx < 2 else [],
                })
                p = subprocess.run(
                    [sys.executable, script, "--ingest-stdin"],
                    input=payload,
                    env=env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(p.returncode, 0, p.stderr)

            rec = subprocess.run(
                [sys.executable, script, "--recommend", "--task-type", "lint_fix", "--stack", "python"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rec.returncode, 0, rec.stderr)
            rec_data = json.loads(rec.stdout)
            self.assertEqual(rec_data["recommended_tier"], "T1_scout")

            roi = subprocess.run(
                [sys.executable, script, "--roi-report"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(roi.returncode, 0, roi.stderr)
            roi_data = json.loads(roi.stdout)
            self.assertEqual(roi_data["cost_summary"]["runs"], 3)
            self.assertGreater(roi_data["cost_summary"]["savings_vs_t2"], 0)
            self.assertEqual(roi_data["failure_promotion_candidates"][0]["signature"], "ruff:.py")
            self.assertEqual(roi_data["failure_promotion_candidates"][0]["count"], 2)


@unittest.skipUnless(BASH_BIN is not None, "Git Bash / POSIX bash required")
class SyncAndHookTests(unittest.TestCase):
    def _run_bash(self, cmd_args, env=None, stdin_text=None, cwd=None):
        return subprocess.run(
            [BASH_BIN, *cmd_args],
            env=env,
            input=stdin_text,
            cwd=cwd or AXN_ROOT,
            capture_output=True,
            text=True,
        )

    def test_sync_core_dry_run_and_wire_hooks_merge(self):
        sync_sh = os.path.join(AXN_ROOT, "scripts", "sync.sh")
        with tempfile.TemporaryDirectory(prefix="axn-test-home-") as tmp_home:
            claude_dir = os.path.join(tmp_home, ".claude")
            os.makedirs(claude_dir, exist_ok=True)
            settings_path = os.path.join(claude_dir, "settings.json")
            existing = {
                "permissions": {"allow": ["Bash(git status)"]},
                "hooks": {
                    "PreToolUse": [
                        {"matcher": "Custom", "hooks": [{"type": "command", "command": "echo user-hook"}]}
                    ]
                },
            }
            with open(settings_path, "w", encoding="utf-8") as fh:
                json.dump(existing, fh)

            env = dict(os.environ, HOME=tmp_home)
            dry = self._run_bash([sync_sh, "--dry-run", "--claude", "--wire-hooks"], env=env)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("profile=core", dry.stdout)
            self.assertIn("repo-map-compressor", dry.stdout)
            self.assertNotIn("0x-dev-guide", dry.stdout)
            self.assertIn("wired 6 hook(s)", dry.stdout)

            # Verify --dry-run did not alter settings.json
            with open(settings_path, "r", encoding="utf-8") as fh:
                self.assertEqual(json.load(fh), existing)

            # Live --profile minimal --claude --wire-hooks (fast + tests idempotent merge)
            res = self._run_bash([sync_sh, "--profile", "minimal", "--claude", "--wire-hooks"], env=env)
            self.assertEqual(res.returncode, 0, res.stderr)
            with open(settings_path, "r", encoding="utf-8") as fh:
                merged = json.load(fh)
            self.assertEqual(merged["permissions"], existing["permissions"])
            cmds = [
                h["command"]
                for ev in merged["hooks"].values()
                for entry in ev
                for h in entry.get("hooks", [])
            ]
            self.assertIn("echo user-hook", cmds)
            self.assertIn("~/.claude/hooks/pre-tool-use/config-protection.sh", cmds)
            self.assertIn("~/.claude/hooks/stop/orchestrator-feedback.sh", cmds)

            res2 = self._run_bash([sync_sh, "--profile", "minimal", "--claude", "--wire-hooks"], env=env)
            self.assertEqual(res2.returncode, 0, res2.stderr)
            self.assertIn("hooks already wired", res2.stdout)

            # Unwire preserves custom user hook while removing AXN hooks
            unwire = self._run_bash([sync_sh, "--uninstall", "--profile", "minimal", "--claude", "--wire-hooks"], env=env)
            self.assertEqual(unwire.returncode, 0, unwire.stderr)
            with open(settings_path, "r", encoding="utf-8") as fh:
                after = json.load(fh)
            after_cmds = [
                h["command"]
                for ev in after["hooks"].values()
                for entry in ev
                for h in entry.get("hooks", [])
            ]
            self.assertIn("echo user-hook", after_cmds)
            self.assertNotIn("~/.claude/hooks/stop/orchestrator-feedback.sh", after_cmds)

    def test_pre_tool_use_guards(self):
        brg = os.path.join(AXN_ROOT, "hooks", "pre-tool-use", "blast-radius-guard.sh")
        cfg = os.path.join(AXN_ROOT, "hooks", "pre-tool-use", "config-protection.sh")
        tbg = os.path.join(AXN_ROOT, "hooks", "pre-tool-use", "token-budget-guard.sh")

        r_block = self._run_bash([brg], stdin_text=json.dumps({"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}}))
        self.assertEqual(r_block.returncode, 2, r_block.stderr)

        r_allow = self._run_bash([brg], stdin_text=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git status"}}))
        self.assertEqual(r_allow.returncode, 0, r_allow.stderr)

        with tempfile.TemporaryDirectory(prefix="axn-cfg-") as cfg_tmp:
            eslint_path = os.path.join(cfg_tmp, ".eslintrc.json")
            with open(eslint_path, "w", encoding="utf-8") as fh:
                fh.write("{}\n")
            r_cfg = self._run_bash([cfg], stdin_text=json.dumps({"tool_name": "Edit", "tool_input": {"file_path": eslint_path.replace("\\", "/")}}))
            self.assertEqual(r_cfg.returncode, 2, r_cfg.stderr)
            r_cfg_new = self._run_bash([cfg], stdin_text=json.dumps({"tool_name": "Edit", "tool_input": {"file_path": os.path.join(cfg_tmp, ".prettierrc").replace("\\", "/")}}))
            self.assertEqual(r_cfg_new.returncode, 0, r_cfg_new.stderr)

        r_tbg_block = self._run_bash([tbg], stdin_text=json.dumps({"tool_name": "Read", "tool_input": {"file_path": "package-lock.json"}}))
        self.assertEqual(r_tbg_block.returncode, 2, r_tbg_block.stderr)

        r_tbg_allow = self._run_bash([tbg], stdin_text=json.dumps({"tool_name": "Read", "tool_input": {"file_path": "src/app.py", "offset": 1, "limit": 50}}))
        self.assertEqual(r_tbg_allow.returncode, 0, r_tbg_allow.stderr)

    def test_stop_gate_and_feedback_e2e(self):
        stop_gate = os.path.join(AXN_ROOT, "hooks", "stop", "stop-gate-verifier.sh")
        feedback = os.path.join(AXN_ROOT, "hooks", "stop", "orchestrator-feedback.sh")

        with tempfile.TemporaryDirectory(prefix="axn-e2e-") as tmp:
            repo_dir = os.path.join(tmp, "repo")
            strike_dir = os.path.join(tmp, "strikes")
            state_dir = os.path.join(tmp, "state")
            os.makedirs(os.path.join(repo_dir, ".ai"), exist_ok=True)
            os.makedirs(strike_dir, exist_ok=True)
            os.makedirs(state_dir, exist_ok=True)
            subprocess.run(["git", "init", "-q"], cwd=repo_dir, check=True)

            env = dict(
                os.environ,
                AXN_STRIKE_DIR=strike_dir.replace("\\", "/"),
                AXN_STATE_DIR=state_dir.replace("\\", "/"),
                AXN_ROOT=AXN_ROOT.replace("\\", "/"),
            )
            # Fail once via .ai/verify.cmd
            with open(os.path.join(repo_dir, ".ai", "verify.cmd"), "w", encoding="utf-8") as fh:
                fh.write("false\n")
            fail_run = self._run_bash([stop_gate], env=env, stdin_text="{}", cwd=repo_dir)
            self.assertEqual(fail_run.returncode, 2, fail_run.stderr)

            # Pass on retry
            with open(os.path.join(repo_dir, ".ai", "verify.cmd"), "w", encoding="utf-8") as fh:
                fh.write("true\n")
            pass_run = self._run_bash([stop_gate], env=env, stdin_text="{}", cwd=repo_dir)
            self.assertEqual(pass_run.returncode, 0, pass_run.stderr)

            # Feedback consumes turn-state + filters bad instincts
            telemetry = {
                "task_type": "feature_impl",
                "stack": "python",
                "initial_tier": "T2",
                "final_tier": "T2",
                "retries": 0,
                "escalated": False,
                "escalated_effort": True,
                "instincts_used": ["bounded-slice-reads", "../bad/path"],
            }
            fb_payload = json.dumps({"last_assistant_message": "Done.\nAXN_TELEMETRY: " + json.dumps(telemetry)})
            fb_run = self._run_bash([feedback], env=env, stdin_text=fb_payload, cwd=repo_dir)
            self.assertEqual(fb_run.returncode, 0, fb_run.stderr)

            weights_path = os.path.join(state_dir, "routing-weights.json")
            self.assertTrue(os.path.isfile(weights_path), "orchestrator-feedback.sh did not invoke learn-router.py")
            with open(weights_path, "r", encoding="utf-8") as fh:
                weights = json.load(fh)
            self.assertEqual(weights["totals"]["runs"], 1)
            self.assertEqual(weights["totals"]["retries"], 1)
            self.assertIn("bounded-slice-reads", weights["instinct_stats"])
            self.assertNotIn("../bad/path", weights["instinct_stats"])


if __name__ == "__main__":
    unittest.main()
