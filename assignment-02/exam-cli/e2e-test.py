#!/usr/bin/env python3
"""End-to-end test of both walkthroughs through CloudFront (stdlib only).
   Usage: python3 e2e-test.py <cloudfront-domain> <region> <app-client-id>"""
import json, sys, time, urllib.error, urllib.request, uuid

DOMAIN, REGION, CLIENT = sys.argv[1], sys.argv[2], sys.argv[3]
BASE = f"https://{DOMAIN}/api"
results = []

def report(name, ok, detail=""):
    results.append(ok); print(f"  {'✅' if ok else '❌'} {name}{(' - ' + detail) if detail else ''}")

def call(method, path, token=None, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"X-Auth-Token": token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

def login(user, pw):
    req = urllib.request.Request(f"https://cognito-idp.{REGION}.amazonaws.com/", method="POST",
        data=json.dumps({"AuthFlow": "USER_PASSWORD_AUTH", "ClientId": CLIENT, "AuthParameters": {"USERNAME": user, "PASSWORD": pw}}).encode(),
        headers={"Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth"})
    with urllib.request.urlopen(req, timeout=15) as r: return json.loads(r.read())["AuthenticationResult"]["IdToken"]

s, h = call("GET", "/health")
report("API + database healthy", s == 200 and h.get("db") == "ok", f"served from {h.get('served_by_az')}")
s, _ = call("GET", "/me")
report("Unauthenticated request rejected", s == 401, f"HTTP {s}")

student = login("student@example.com", "Exam@2026"); tutor = login("tutor@example.com", "Exam@2026")
s, me = call("GET", "/me", student)
report("Student signs in with Cognito (role from JWT)", s == 200 and "student" in me.get("roles", []), f"roles={me.get('roles')}")
s, _ = call("POST", "/exams/dso303-quiz/start", tutor)
report("Role check: tutor cannot start a student exam", s == 403, f"HTTP {s}")

print("  -- Walkthrough 1: open exam, autosave, submit --")
s, st = call("POST", "/exams/dso303-quiz/start", student)
aid = st.get("attempt", {}).get("attempt_id")
report("Student opens the exam (attempt created in RDS)", s == 200 and bool(aid), f"attempt {aid}, deadline {st.get('attempt', {}).get('deadline')}")
s1, a1 = call("PUT", f"/attempts/{aid}/answers", student, {"answers": {"q1": "B"}})
s2, a2 = call("PUT", f"/attempts/{aid}/answers", student, {"answers": {"q1": "B", "q2": "A", "q4": "ALB and ECS run in two AZs; RDS fails over to its standby."}})
report("Autosave writes answers to RDS", s1 == 200 and s2 == 200 and a2.get("save_count", 0) >= 2, f"save #{a2.get('save_count')} at {a2.get('saved_at')}")
s, got = call("GET", f"/attempts/{aid}", student)
report("Saved answers read back from RDS", s == 200 and got["attempt"]["answers"].get("q2") == "A")
s, sub = call("POST", f"/attempts/{aid}/submit", student, {"answers": {"q1": "B", "q2": "A", "q3": "C"}})
report("Submit queues a marking job on SQS", s == 200, sub.get("marking", sub.get("error", "")))
s, _ = call("PUT", f"/attempts/{aid}/answers", student, {"answers": {"q1": "A"}})
report("Answers are locked after submit", s == 409, f"HTTP {s}")

print("  -- Walkthrough 2: presigned upload straight to S3 --")
size = 2 * 1024 * 1024
s, p = call("POST", "/uploads", student, {"filename": "e2e-test.pdf", "content_type": "application/pdf", "size": size})
report("API returns a presigned POST", s == 200 and "url" in p, p.get("key", p.get("error", "")))
if s == 200:
    boundary = uuid.uuid4().hex; parts = []
    for k, v in p["fields"].items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="e2e-test.pdf"\r\nContent-Type: application/pdf\r\n\r\n'.encode())
    body = b"".join(parts) + b"%PDF-1.4\n" + b"0" * (size - 9) + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(p["url"], data=body, method="POST", headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: report("File uploaded directly to S3 (bypasses the API)", r.status in (201, 204), f"HTTP {r.status}, {size // 1048576} MB")
    except urllib.error.HTTPError as e:
        report("File uploaded directly to S3", False, f"HTTP {e.code}")
s, _ = call("POST", "/uploads", student, {"filename": "x.exe", "content_type": "application/x-msdownload", "size": 10})
report("Non-PDF/ZIP upload refused", s == 400, f"HTTP {s}")

print(f"  ATTEMPT_ID={aid}")
sys.exit(0 if all(results) else 1)