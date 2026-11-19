"""Async worker: one SQS queue carries three kinds of jobs.
   1. S3 upload events      -> email the tutor about the new submission
   2. {"type": "mark", ...}  -> auto-mark MCQ answers
   3. {"type": "results"...} -> email a student that results are released
"""
import json, os
import boto3

ses = boto3.client("ses")
FROM = os.environ["FROM_EMAIL"]
TUTOR = os.environ["TUTOR_EMAIL"]


def send_email(to, subject, body):
    ses.send_email(Source=FROM, Destination={"ToAddresses": [to]},
                   Message={"Subject": {"Data": subject}, "Body": {"Text": {"Data": body}}})


def mark(job):
    answers, key = job.get("answers", {}), job.get("answer_key", {})
    score = sum(1 for q, correct in key.items() if answers.get(q) == correct)
    print(json.dumps({"event": "marked", "attempt_id": job.get("attempt_id"), "score": score, "total": len(key)}))
    return score


def handle(body):
    if body.get("Event") == "s3:TestEvent":          # sent once when the S3 notification is created
        return
    if body.get("Records") and body["Records"][0].get("eventSource") == "aws:s3":
        for r in body["Records"]:
            key, size = r["s3"]["object"]["key"], r["s3"]["object"]["size"]
            print(json.dumps({"event": "upload", "key": key, "bytes": size}))
            send_email(TUTOR, "New assignment submission",
                       f"A new file was submitted:\n{key}\nSize: {size / 1048576:.1f} MB")
    elif body.get("type") == "mark":
        mark(body)
    elif body.get("type") == "results":
        send_email(body["email"], "Your exam results are released",
                   body.get("message", "Your results are now available on the exam portal."))
    else:
        print(json.dumps({"event": "unknown", "body": body}))


def handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            handle(json.loads(record["body"]))
        except Exception as exc:                       # failed messages retry, then go to the DLQ
            print(json.dumps({"event": "error", "error": str(exc), "messageId": record["messageId"]}))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
