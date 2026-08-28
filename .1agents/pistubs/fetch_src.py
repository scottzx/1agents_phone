#!/usr/bin/env python3
"""Fetch the pi_agent_rust src/ blobs from raw.githubusercontent.com and verify
each against its git blob SHA from the local tree. Retries per file; parallel."""
import concurrent.futures, hashlib, json, os, subprocess, sys, time, urllib.request

COMMIT = "44ddf80ff1fccbeb08501c1e8eaa69f2b5dd5d92"
OWNER_REPO = "Dicklesworthstone/pi_agent_rust"
WORKTREE = os.path.abspath("deps/pi_agent_rust")
BASE = f"https://raw.githubusercontent.com/{OWNER_REPO}/{COMMIT}/"

def git_hash_object(path):
    r = subprocess.run(["git", "hash-object", path], cwd=WORKTREE,
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def fetch(sha, relpath):
    dest = os.path.join(WORKTREE, relpath)
    if os.path.exists(dest):
        if git_hash_object(dest) == sha:
            return (relpath, "have")
        os.remove(dest)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    url = BASE + relpath
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if data.startswith(b"404: Not Found") or len(data) == 0:
                time.sleep(3); continue
            with open(dest, "wb") as f:
                f.write(data)
            if git_hash_object(dest) == sha:
                return (relpath, "ok")
            # mismatch — retry
        except Exception as e:
            pass
        time.sleep(2 + attempt)
    return (relpath, "FAIL")

def main():
    lines = [l.split() for l in open("/tmp/src-blobs.txt") if l.strip()]
    targets = [(sha, path) for sha, path in lines]
    print(f"targets={len(targets)}", flush=True)
    results = []
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(fetch, sha, path): (sha, path) for sha, path in targets}
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            relpath, status = fut.result()
            done += 1
            if status != "have":
                results.append(status)
            if done % 20 == 0 or status == "FAIL":
                print(f"[{done}/{len(targets)}] {status} {relpath} ({time.time()-t0:.0f}s)", flush=True)
    fails = [r for r in results if r == "FAIL"]
    print(f"DONE ok={results.count('ok')} have={results.count('have')} fail={len(fails)} elapsed={time.time()-t0:.0f}s", flush=True)
    if fails:
        print("FAILED FILES:", flush=True)
        for sha, path in targets:
            dest = os.path.join(WORKTREE, path)
            if not (os.path.exists(dest) and git_hash_object(dest) == sha):
                print(" ", path, flush=True)

if __name__ == "__main__":
    main()
