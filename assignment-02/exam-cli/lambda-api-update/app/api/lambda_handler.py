"""Lets the Flask app run as an ALB Lambda target: ALB event -> WSGI request -> ALB response."""
import base64

from werkzeug.test import EnvironBuilder, run_wsgi_app

from app import app

TEXT_TYPES = ("text/", "application/json", "application/javascript", "application/xml")


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw = event.get("body") or ""
    data = base64.b64decode(raw) if event.get("isBase64Encoded") else raw.encode()
    # ALB passes query parameters still URL-encoded, so they can be joined as-is
    query = "&".join(f"{k}={v}" for k, v in (event.get("queryStringParameters") or {}).items())
    content_type = headers.pop("content-type", None)
    headers.pop("content-length", None)
    builder = EnvironBuilder(
        path=event.get("path", "/"), method=event.get("httpMethod", "GET"), query_string=query,
        headers=headers, data=data, content_type=content_type,
        base_url=f"{headers.get('x-forwarded-proto', 'https')}://{headers.get('host', 'localhost')}")
    environ = builder.get_environ()
    environ["REMOTE_ADDR"] = headers.get("x-forwarded-for", "").split(",")[0].strip()
    app_iter, status, resp_headers = run_wsgi_app(app, environ)
    try:
        payload = b"".join(app_iter)
    finally:
        if hasattr(app_iter, "close"):
            app_iter.close()
    ctype = resp_headers.get("Content-Type", "")
    is_text = ctype.startswith(TEXT_TYPES)
    return {
        "statusCode": int(status.split(" ", 1)[0]),
        "statusDescription": status,
        "headers": {k: v for k, v in resp_headers.items()},
        "body": payload.decode("utf-8") if is_text else base64.b64encode(payload).decode(),
        "isBase64Encoded": not is_text,
    }
