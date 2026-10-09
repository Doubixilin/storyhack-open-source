#!/usr/bin/env python3
"""Run the real CLI against a loopback synthetic SSE provider, without real books or keys."""
import argparse
import http.server
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import threading


def verify(executable):
    secret = "fixture-only-never-a-real-key-7302"
    received, release = threading.Event(), threading.Event()
    state = {"mode": "normal", "count": 0, "authorized": True}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["count"] += 1
            state["authorized"] &= self.headers.get("Authorization") == "Bearer " + secret
            mode = state["mode"]
            received.set()
            if mode == "pause":
                release.wait(20)
            if mode == "error":
                self.send_response(500)
                self.end_headers()
                self.wfile.write(secret.encode())
                return
            prompt = request["messages"][-1]["content"]
            if prompt.startswith("写作输入（结构化资料）：\n"):
                context, _ = json.JSONDecoder().raw_decode(prompt.split("\n", 1)[1])
                chapter = context["context"]["target"]["chapter_id"]
                result = {"title": "合成章" + chapter, "body": "林舟在渡口收好信件，沿着山路返回。",
                          "recap": "带信返程", "review_line": "合成章审",
                          "recipe": {"trigger": chapter, "setting": "渡口", "technique": "动作"}}
            elif "<bake_input>" in prompt:
                value = json.loads(prompt.split("<bake_input>")[1].split("</bake_input>")[0])
                result = {"entries": [{"id": e["id"], "content": "林舟留在渡口守候。",
                                       "decision_ids": e["decisionIDs"]} for e in value["entries"]]}
            elif prompt.startswith("元数据：\n"):
                header, _ = json.JSONDecoder().raw_decode(prompt.split("\n", 1)[1])
                chapter = header["chapter_id"]
                text = prompt.split("<source>\n")[1].split("\n</source>")[0]
                quote = text[:8]
                if "改编位置" in request["messages"][0]["content"]:
                    result = {"anchors": [{"chapter_id": chapter, "quote": quote, "note": "补充环境",
                                           "action": "insertion", "focus_names": []}]}
                else:
                    evidence = [{"chapter_id": chapter, "quote": quote, "utf16_location": int(header["utf16_start"])}]
                    result = {"characters": [{"id": "p", "name": "林舟", "identity_core": "旅行者", "evidence": evidence}],
                              "chapters": [{"chapter_id": chapter, "summary": "林舟来到渡口。", "evidence": evidence}]}
            else:
                chapters = re.findall(r'<chapter id="([^"]+)"[^>]*>\s*(.*?)\s*</chapter>', prompt, re.S)
                assert chapters, "Expected a real factory chapter request"
                chapter, text = chapters[0]
                quote = "林舟来到渡口"
                assert quote in text
                evidence = [{"chapter_id": chapter, "quote": quote}]
                result = {"covered_chapter_ids": [c[0] for c in chapters],
                          "chapter_summaries": [{"chapter_id": c[0], "summary": "林舟来到渡口等船。"} for c in chapters],
                          "proposals": [{"kind": "character", "title": "林舟", "content": "林舟来到渡口等船。",
                                         "activation_keys": ["林舟"], "always_active": False, "evidence": evidence}],
                          "decisions": [{"question": "林舟是否留在渡口？", "recommendation": "留在渡口守候",
                                         "rationale": "作者决定", "impact": "后续行程", "evidence": evidence}]}
            text = json.dumps(result, ensure_ascii=False)
            payload = {"choices": [{"delta": {"content": text}, "finish_reason": None}]}
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(("data: " + json.dumps(payload) + "\n\ndata: [DONE]\n\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass  # The cancelled request deliberately disconnected.

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    children = []
    try:
        with tempfile.TemporaryDirectory(prefix="worldbook-cli-process-") as directory:
            root = Path(directory)
            env = {"PATH": "/usr/bin:/bin", "WORLDBOOK_API_KEY": secret, "WORLDBOOK_MODEL": "synthetic",
                   "WORLDBOOK_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1"}

            def command(*args):
                return [str(executable), *map(str, args), "--root", str(root)]

            def run(*args, code=0, credentials=True):
                selected = env if credentials else {k: v for k, v in env.items() if k != "WORLDBOOK_API_KEY"}
                result = subprocess.run(command(*args), env=selected, capture_output=True, text=True, timeout=40)
                assert secret not in result.stdout + result.stderr, "Credential leaked to terminal output"
                assert result.returncode == code, (args[:2], result.returncode, code, result.stderr)
                return json.loads(result.stdout) if result.stdout else None

            def save(name, value):
                path = root / name
                path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
                return path

            plan = root / "plan.txt"
            plan.write_text("开篇｜林舟来到渡口。\n返程｜林舟带信返回。", encoding="utf-8")
            job = run("adaptation", "original", "--source", plan, "--title", "合成写作")
            jid, variant = job["id"], job["variants"][0]
            vid = variant["id"]
            contract = run("adaptation", "contract", "--job", jid, "--variant", vid)
            contract["contract"]["minimum_character_count"] = 1
            contract["contract"]["target_character_count"] = 100
            run("adaptation", "contract", "--job", jid, "--variant", vid, "--revision", contract["id"],
                "--file", save("contract.json", contract["contract"]))
            write = ("adaptation", "write", "--job", jid, "--variant", vid, "--max-requests", "1")
            assert run(*write, code=3)["new_request_count"] == 1
            assert run(*write)["new_request_count"] == 1
            before = state["count"]
            assert run(*write)["new_request_count"] == 0
            assert state["count"] == before
            drafts = run("adaptation", "drafts", "--job", jid, "--variant", vid)
            for row in drafts["current"]:
                current = run("adaptation", "drafts", "--job", jid, "--variant", vid)
                review = {"kind": "draft", "jobID": jid, "variantID": vid, "draftID": row["draft"]["id"],
                          "revision": current["revision"], "action": "approve", "acknowledge": True}
                run("adaptation", "review", "--job", jid, "--file", save("review.json", review))
            assembly = run("adaptation", "assemble", "--job", jid, "--variant", vid)
            file = save("assembly.json", assembly)
            exports = run("adaptation", "export", "--job", jid, "--file", file, credentials=False)
            assert Path(exports["epub"]).is_file()
            run("adaptation", "publish", "--job", jid, "--file", file, credentials=False)
            assert state["count"] == before

            # A still-running process cannot be restarted or have its request acknowledged.
            state["mode"] = "pause"; received.clear(); release.clear()
            running = subprocess.Popen(command(*write, "--regenerate"), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            children.append(running)
            assert received.wait(10), "CLI did not reach provider"
            run(*write, code=75)
            pending = run("adaptation", "pending", "--job", jid)
            pending_file = save("pending.json", pending)
            run("adaptation", "acknowledge", "--job", jid, "--file", pending_file, "--allow-resend", code=75)
            running.send_signal(signal.SIGTERM)
            out, err = running.communicate(timeout=10)
            assert secret not in out + err
            assert running.returncode == 130, (running.returncode, err)
            run(*write, code=4)
            config = run("adaptation", "config", "--job", jid)
            run(*write, "--regenerate", code=4)
            assert run("adaptation", "config", "--job", jid) == config
            run("adaptation", "acknowledge", "--job", jid, "--file", pending_file, "--allow-resend")
            state["mode"] = "normal"; release.set()
            run(*write, code=3); run(*write)
            zero = (*write[:-1], "0")
            before = state["count"]
            run(*zero, credentials=False)
            assert state["count"] == before

            # SIGKILL drops the lease but leaves the unknown request for explicit review.
            state["mode"] = "pause"; received.clear(); release.clear()
            killed = subprocess.Popen(command(*write, "--regenerate"), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            children.append(killed)
            assert received.wait(10)
            killed.kill(); killed.communicate(timeout=10)
            assert killed.returncode == -signal.SIGKILL
            run(*write, code=4)
            pending = run("adaptation", "pending", "--job", jid)
            run("adaptation", "acknowledge", "--job", jid, "--file", save("pending.json", pending), "--allow-resend")
            state["mode"] = "error"; release.set()
            run(*write, code=1)
            assert run("adaptation", "pending", "--job", jid) is not None

            # Factory analysis, explicit decision, bake, cache reuse and publication.
            state["mode"] = "normal"
            source = root / "factory.txt"
            source.write_text("第一章 渡口\n林舟来到渡口，打算乘船。", encoding="utf-8")
            factory = run("factory", "create", "--source", source)
            fid = factory["id"]
            status = run("factory", "analyze", "--job", fid, code=4)
            decision = status["decisions"][0]
            run("factory", "answer", "--job", fid, "--file", save("missing-answer.json", {"reviewed": decision}), code=2)
            answer_file = save("answer.json", {"reviewed": decision, "answer": None})
            run("factory", "answer", "--job", fid, "--file", answer_file, code=4)
            run("factory", "answer", "--job", fid, "--file", answer_file, code=1)
            run("factory", "generate", "--job", fid)
            before = state["count"]
            run("factory", "generate", "--job", fid, "--regenerate")
            run("factory", "publish", "--job", fid, credentials=False)
            run("factory", "publish", "--job", fid, credentials=False)
            assert state["count"] == before
            # Shared extraction/manual-card retention and reviewed-anchor commands.
            imported = run("adaptation", "import", "--source", source)
            aid = imported["id"]
            run("adaptation", "extract", "--job", aid)
            bookcase = run("adaptation", "bookcases", "--job", aid)[0]
            content = bookcase["content"]
            content["characters"][0]["speech_style"] = "说话简短"
            status = run("adaptation", "status", "--job", aid)
            edited = run("adaptation", "edit-bookcase", "--job", aid, "--file", save("bookcase-edit.json",
                         {"jobID": aid, "revision": status["job"]["revision"], "parentID": bookcase["id"], "content": content}))
            status = run("adaptation", "status", "--job", aid)
            run("adaptation", "review", "--job", aid, "--file", save("bookcase-review.json",
                {"kind": "bookcase", "jobID": aid, "revision": status["job"]["revision"], "proposalID": edited["id"], "action": "approve"}))
            before = state["count"]
            extraction = run("adaptation", "extract", "--job", aid, "--max-requests", "0", credentials=False)
            retained = next(b for b in run("adaptation", "bookcases", "--job", aid) if b["id"] == extraction["proposal_id"])
            assert retained["content"]["characters"][0]["speech_style"] == "说话简短"
            assert state["count"] == before
            run("adaptation", "scan", "--job", aid)
            anchors = run("adaptation", "anchors", "--job", aid)
            chapter = run("adaptation", "source", "--job", aid)["chapters"][0]["id"]
            run("adaptation", "add-anchor", "--job", aid, "--revision", anchors["revision"],
                "--file", save("anchor.json", {"chapter_id": chapter, "quote": "", "note": "章首环境"}))
            anchors = run("adaptation", "anchors", "--job", aid)
            manual = next(a for a in anchors["anchors"] if a["anchor"]["origin"] == "m")
            run("adaptation", "review", "--job", aid, "--file", save("anchor-review.json",
                {"kind": "anchor", "jobID": aid, "revision": anchors["revision"], "anchorID": manual["id"],
                 "generationAction": "insertion", "action": "approve"}))
            status = run("adaptation", "status", "--job", aid)
            direction = run("adaptation", "contract", "--job", aid, "--title", "锚点稿", "--revision", status["job"]["revision"],
                            "--file", save("anchor-contract.json", contract["contract"]))
            config = run("adaptation", "config", "--job", aid)
            config["write_scope"] = "anchors"
            run("adaptation", "config", "--job", aid, "--file", save("anchor-config.json", config))
            report = run("adaptation", "write", "--job", aid, "--variant", direction["id"])
            assert len(report["completed_draft_ids"]) == 1
            assert state["authorized"]
            assert not (root / "Providers").exists(), "CLI wrote an App provider profile"
            for path in root.rglob("*"):
                if path.is_file():
                    assert secret.encode() not in path.read_bytes(), "Credential persisted in a task file"
            print("PASS: actual CLI SSE, resume, author review, export, factory, bookcase/manual cards/anchors, process exclusion, SIGTERM/SIGKILL, unknown-request approval, credential isolation")
    finally:
        release.set()
        for child in children:
            if child.poll() is None:
                child.kill(); child.communicate(timeout=10)
        server.shutdown(); server.server_close(); thread.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug/WorldbookTaskTool")
    arguments = parser.parse_args()
    verify(arguments.executable.resolve(strict=True))
