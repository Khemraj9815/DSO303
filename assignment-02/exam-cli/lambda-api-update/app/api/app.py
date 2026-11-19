"""Exam platform API - runs behind the ALB (as a Lambda function, or on ECS Fargate), reached via CloudFront /api/*.

Auth: Cognito ID token in the X-Auth-Token header (role from the cognito:groups claim).
Data: RDS PostgreSQL (credentials injected from Secrets Manager as DB_SECRET).
Async: submit -> SQS "mark" job -> Lambda.  Uploads: presigned POST straight to S3.
"""
import datetime as dt
import functools
import json
import os
import re
import threading
import time
import urllib.request

import boto3
import jwt
import psycopg2
import psycopg2.extras
from botocore.config import Config
from flask import Flask, g, jsonify, request

REGION = os.environ.get("AWS_REGION", "us-east-1")
USER_POOL_ID = os.environ["USER_POOL_ID"]
APP_CLIENT_ID = os.environ["APP_CLIENT_ID"]
BUCKET = os.environ["SUBMISSIONS_BUCKET"]
QUEUE_URL = os.environ["QUEUE_URL"]
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "examdb")
DB_INSTANCE_ID = os.environ.get("DB_INSTANCE_ID", "")


def _load_db_secret():
    """ECS injects the secret as DB_SECRET; Lambda reads it from Secrets Manager once per cold start."""
    if os.environ.get("DB_SECRET"):
        return json.loads(os.environ["DB_SECRET"])
    sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    return json.loads(sm.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])


DB_SECRET = _load_db_secret()
MAX_UPLOAD = 50 * 1024 * 1024
GRACE = dt.timedelta(minutes=2)
ALLOWED_TYPES = {"application/pdf", "application/zip", "application/x-zip-compressed"}

ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{USER_POOL_ID}"
jwks = jwt.PyJWKClient(f"{ISSUER}/.well-known/jwks.json", cache_keys=True)
s3 = boto3.client("s3", region_name=REGION, config=Config(signature_version="s3v4"))
sqs = boto3.client("sqs", region_name=REGION)
rds = boto3.client("rds", region_name=REGION)
app = Flask(__name__)

EXAM = {
    "id": "dso303-quiz",
    "title": "DSO303 Cloud Architecture Quiz",
    "duration_min": 30,
    "questions": [
        {"id": "q1", "type": "mcq", "text": "Which service gives this platform a database with a synchronous standby in a second AZ?",
         "options": {"A": "Amazon S3", "B": "Amazon RDS Multi-AZ", "C": "Amazon CloudFront", "D": "Amazon SQS"}},
        {"id": "q2", "type": "mcq", "text": "In which subnet type does the Application Load Balancer run?",
         "options": {"A": "Public subnet", "B": "Private subnet", "C": "Isolated subnet", "D": "It does not use a subnet"}},
        {"id": "q3", "type": "mcq", "text": "Why does exam submission go through SQS before marking?",
         "options": {"A": "To encrypt answers", "B": "To serve static files", "C": "To buffer bursts and retry failed marking", "D": "To store files for 5 years"}},
        {"id": "q4", "type": "short", "text": "In two or three sentences, explain how the platform keeps working if one Availability Zone fails."},
    ],
    "answer_key": {"q1": "B", "q2": "A", "q3": "C"},
}

# ---------------------------------------------------------------- database
def db():
    return psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_SECRET["username"],
                            password=DB_SECRET["password"], sslmode="require", connect_timeout=5)


_schema_ready = False
_schema_lock = threading.Lock()


def ensure_schema():
    global _schema_ready
    if _schema_ready:
        return
    with _schema_lock:
        if _schema_ready:
            return
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_xact_lock(303)")   # two tasks may start at once
            cur.execute("""
              CREATE TABLE IF NOT EXISTS exams (
                id text PRIMARY KEY, title text NOT NULL, duration_min int NOT NULL,
                questions jsonb NOT NULL, answer_key jsonb NOT NULL);
              CREATE TABLE IF NOT EXISTS attempts (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                exam_id text NOT NULL REFERENCES exams(id),
                student_sub text NOT NULL, student_email text NOT NULL,
                started_at timestamptz NOT NULL DEFAULT now(), deadline timestamptz NOT NULL,
                answers jsonb NOT NULL DEFAULT '{}'::jsonb, saved_at timestamptz,
                save_count int NOT NULL DEFAULT 0, submitted_at timestamptz);
              CREATE TABLE IF NOT EXISTS submissions (
                id bigserial PRIMARY KEY, student_sub text NOT NULL, student_email text NOT NULL,
                s3_key text NOT NULL, filename text NOT NULL, requested_at timestamptz NOT NULL DEFAULT now());
            """)
            cur.execute("""INSERT INTO exams (id, title, duration_min, questions, answer_key)
                           VALUES (%s,%s,%s,%s,%s) ON CONFLICT (id) DO UPDATE
                           SET title=EXCLUDED.title, questions=EXCLUDED.questions, answer_key=EXCLUDED.answer_key""",
                        (EXAM["id"], EXAM["title"], EXAM["duration_min"],
                         json.dumps(EXAM["questions"]), json.dumps(EXAM["answer_key"])))
        _schema_ready = True


@app.errorhandler(psycopg2.Error)
def db_down(exc):
    return jsonify(error="database_unavailable", detail=str(exc).strip()[:200], served_by_az=my_az()), 503


# ---------------------------------------------------------------- helpers
_az = None


def my_az():
    """Where this API runs: the Fargate task's AZ, or 'lambda' (Lambda spreads over both private subnets)."""
    global _az
    if _az is None:
        if os.environ.get("AWS_LAMBDA_FUNCTION_NAME"):
            _az = "lambda (2 AZs)"
            return _az
        try:
            uri = os.environ["ECS_CONTAINER_METADATA_URI_V4"] + "/task"
            _az = json.load(urllib.request.urlopen(uri, timeout=2)).get("AvailabilityZone", "unknown")
        except Exception:
            _az = "unknown"
    return _az


_db_az = {"value": None, "at": 0.0}


def db_primary_az():
    """AZ of the current RDS primary (cached 15 s) - flips after a Multi-AZ failover."""
    if not DB_INSTANCE_ID:
        return None
    if time.time() - _db_az["at"] > 15:
        try:
            _db_az["value"] = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_ID)["DBInstances"][0]["AvailabilityZone"]
        except Exception:
            pass
        _db_az["at"] = time.time()
    return _db_az["value"]


def iso(t):
    return t.isoformat() if t else None


def auth(*roles):
    def deco(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            token = request.headers.get("X-Auth-Token", "")
            try:
                key = jwks.get_signing_key_from_jwt(token).key
                claims = jwt.decode(token, key, algorithms=["RS256"], audience=APP_CLIENT_ID, issuer=ISSUER)
                if claims.get("token_use") != "id":
                    raise jwt.InvalidTokenError("not an ID token")
            except Exception as exc:
                return jsonify(error="unauthorized", detail=str(exc)), 401
            groups = claims.get("cognito:groups", [])
            if roles and not set(roles) & set(groups):
                return jsonify(error="forbidden", required_role=list(roles), your_roles=groups), 403
            g.sub, g.email, g.groups = claims["sub"], claims.get("email", ""), groups
            return fn(*args, **kwargs)
        return wrapper
    return deco


def public_exam(row):
    return {"id": row["id"], "title": row["title"], "duration_min": row["duration_min"], "questions": row["questions"]}


def attempt_json(a):
    return {"attempt_id": str(a["id"]), "exam_id": a["exam_id"], "started_at": iso(a["started_at"]),
            "deadline": iso(a["deadline"]), "answers": a["answers"], "saved_at": iso(a["saved_at"]),
            "save_count": a["save_count"], "submitted_at": iso(a["submitted_at"])}


# ---------------------------------------------------------------- routes
@app.get("/")
def alb_health():                       # ALB target health check - must not depend on the DB
    return "ok", 200


@app.get("/api/health")
def health():
    ensure_schema()
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT now(), inet_server_addr()")
        now, server = cur.fetchone()
    return jsonify(status="ok", db="ok", db_time=iso(now), db_primary_az=db_primary_az(), served_by_az=my_az())


@app.get("/api/config")
def config():                           # public settings the browser needs for Cognito sign-in
    return jsonify(region=REGION, userPoolId=USER_POOL_ID, clientId=APP_CLIENT_ID, maxUploadMB=MAX_UPLOAD // 1048576)


@app.get("/api/me")
@auth()
def me():
    return jsonify(email=g.email, roles=g.groups, served_by_az=my_az())


@app.post("/api/exams/<exam_id>/start")
@auth("student")
def start_exam(exam_id):
    ensure_schema()
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM exams WHERE id=%s", (exam_id,))
        exam = cur.fetchone()
        if not exam:
            return jsonify(error="exam_not_found"), 404
        # resume an open attempt (page refresh, or a task/AZ failure mid-exam)
        cur.execute("""SELECT * FROM attempts WHERE exam_id=%s AND student_sub=%s AND submitted_at IS NULL
                       AND now() <= deadline + %s ORDER BY started_at DESC LIMIT 1""", (exam_id, g.sub, GRACE))
        attempt = cur.fetchone()
        resumed = attempt is not None
        if not attempt:
            cur.execute("""INSERT INTO attempts (exam_id, student_sub, student_email, deadline)
                           VALUES (%s,%s,%s, now() + make_interval(mins => %s)) RETURNING *""",
                        (exam_id, g.sub, g.email, exam["duration_min"]))
            attempt = cur.fetchone()
    return jsonify(exam=public_exam(exam), attempt=attempt_json(attempt), resumed=resumed, served_by_az=my_az())


@app.get("/api/attempts/<attempt_id>")
@auth("student")
def get_attempt(attempt_id):
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM attempts WHERE id=%s AND student_sub=%s", (attempt_id, g.sub))
        a = cur.fetchone()
    return (jsonify(attempt=attempt_json(a), served_by_az=my_az()) if a else (jsonify(error="not_found"), 404))


@app.put("/api/attempts/<attempt_id>/answers")
@auth("student")
def autosave(attempt_id):
    answers = (request.get_json(silent=True) or {}).get("answers")
    if not isinstance(answers, dict):
        return jsonify(error="answers must be an object"), 400
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""UPDATE attempts SET answers=%s, saved_at=now(), save_count=save_count+1
                       WHERE id=%s AND student_sub=%s AND submitted_at IS NULL AND now() <= deadline + %s
                       RETURNING saved_at, save_count""", (json.dumps(answers), attempt_id, g.sub, GRACE))
        row = cur.fetchone()
    if not row:
        return jsonify(error="attempt closed (submitted or past deadline)"), 409
    return jsonify(saved_at=iso(row["saved_at"]), save_count=row["save_count"], served_by_az=my_az())


@app.post("/api/attempts/<attempt_id>/submit")
@auth("student")
def submit(attempt_id):
    body = request.get_json(silent=True) or {}
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        if isinstance(body.get("answers"), dict):     # final save together with submit
            cur.execute("""UPDATE attempts SET answers=%s, saved_at=now(), save_count=save_count+1
                           WHERE id=%s AND student_sub=%s AND submitted_at IS NULL AND now() <= deadline + %s""",
                        (json.dumps(body["answers"]), attempt_id, g.sub, GRACE))
        cur.execute("""UPDATE attempts a SET submitted_at=now() FROM exams e
                       WHERE a.id=%s AND a.student_sub=%s AND a.submitted_at IS NULL AND a.exam_id=e.id
                       RETURNING a.id, a.answers, a.submitted_at, e.answer_key""", (attempt_id, g.sub))
        row = cur.fetchone()
    if not row:
        return jsonify(error="attempt not found or already submitted"), 409
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({
        "type": "mark", "attempt_id": str(row["id"]), "student": g.email,
        "answers": row["answers"], "answer_key": row["answer_key"]}))
    return jsonify(submitted_at=iso(row["submitted_at"]), marking="queued (SQS -> Lambda)", served_by_az=my_az())


@app.post("/api/uploads")
@auth("student")
def upload_url():
    body = request.get_json(silent=True) or {}
    filename = re.sub(r"[^A-Za-z0-9._-]", "_", str(body.get("filename", "")))[-100:] or "file"
    ctype = body.get("content_type", "")
    if ctype not in ALLOWED_TYPES:
        return jsonify(error="only PDF or ZIP files are allowed"), 400
    if int(body.get("size", 0)) > MAX_UPLOAD:
        return jsonify(error="file is larger than 50 MB"), 400
    key = f"submissions/DSO303/A2/{g.sub}/{int(time.time())}-{filename}"
    post = s3.generate_presigned_post(
        Bucket=BUCKET, Key=key, Fields={"Content-Type": ctype},
        Conditions=[{"Content-Type": ctype}, ["content-length-range", 1, MAX_UPLOAD]], ExpiresIn=300)
    with db() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO submissions (student_sub, student_email, s3_key, filename) VALUES (%s,%s,%s,%s)",
                    (g.sub, g.email, key, filename))
    return jsonify(url=post["url"], fields=post["fields"], key=key, expires_in=300, served_by_az=my_az())
