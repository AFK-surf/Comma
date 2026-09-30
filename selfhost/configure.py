"""Generate instance configuration without replacing persistent secrets."""
import json
import os
from pathlib import Path
import secrets
from urllib.parse import urlsplit

root = Path(os.environ.get("COMMA_CONFIG_DIR", "/config"))
root.mkdir(parents=True, exist_ok=True)
os.umask(0o077)
secret_path = root / "secrets.json"
if secret_path.exists():
    keys = json.loads(secret_path.read_text())
else:
    keys = {name: secrets.token_hex(32) for name in (
        "postgres", "storage", "api", "cookie", "auth", "rate_limit", "dashboard")}
    keys["subscription"] = __import__("base64").b64encode(secrets.token_bytes(32)).decode()
    # Exclusive creation prevents a concurrent initializer from replacing keys.
    with secret_path.open("x") as out:
        json.dump(keys, out)

public = os.environ.get("COMMA_PUBLIC_URL", "http://localhost:8080").rstrip("/")
admin = os.environ.get("COMMA_ADMIN_URL", "http://localhost:8082").rstrip("/")
salix = os.environ.get("COMMA_SALIX_URL", "http://localhost:4000").rstrip("/")
api = os.environ.get("COMMA_API_URL", "http://localhost:8081").rstrip("/")
for url in (public, admin, salix, api):
    parsed = urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname or
            parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment):
        raise SystemExit("Public URLs must be bare HTTP(S) origins.")
    if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise SystemExit("Remote access requires HTTPS public URLs.")
if api in (public, admin):
    raise SystemExit("COMMA_API_URL must differ from Web and Admin origins for browser Origin validation.")
if public == admin:
    raise SystemExit("COMMA_ADMIN_URL must differ from COMMA_PUBLIC_URL.")

smtp_host = os.environ.get("COMMA_SMTP_HOST", "mailpit")
if urlsplit(public).hostname not in ("localhost", "127.0.0.1", "::1") and smtp_host == "mailpit":
    raise SystemExit("Configure COMMA_SMTP_HOST before public deployment. Mailpit is a local inbox.")

owner_email = os.environ.get("COMMA_OWNER_EMAIL", "").strip()
allow_signup = os.environ.get("COMMA_ALLOW_SIGNUP", "false") == "true"
local = urlsplit(public).hostname in ("localhost", "127.0.0.1", "::1")
if not local and not owner_email and not allow_signup:
    raise SystemExit("Set COMMA_OWNER_EMAIL, or explicitly enable COMMA_ALLOW_SIGNUP for public registration.")

dsn = f"ecto://comma:{keys['postgres']}@postgres:5432/comma"
config = {
    "storage": {"endpoint": "http://minio:9000", "region": "us-east-1", "bucket": "comma",
                "access_key_id": "comma", "secret_access_key": keys["storage"],
                "atomic_operations": "s3", "conditional_delete": "emulate"},
    "web": {"port": 4000, "api_token": keys["api"], "api_base_url": salix,
            "sites_domain": os.environ.get("COMMA_SITES_DOMAIN", "sites.localhost"), "sites_port": 4000},
    "transfer": {"port": 4400, "advertise_host": "comma"},
    "salix_dashboard": {"secret_key_base": keys["dashboard"]},
    "salix": {"database": {"url": dsn, "pool_size": 4}},
    "billing": {"database": {"url": dsn, "pool_size": 6}},
    "comma": {"selfhost": {"owner_email": owner_email}, "database": {"url": dsn, "pool_size": 8},
            "auth": {"secret": keys["auth"], "rate_limit_secret": keys["rate_limit"],
                     "redis_url": "redis://redis:6379/0", "auto_create_users": local or allow_signup},
            "web": {"web_cookie_origin": public, "admin_cookie_origin": admin,
                    "allowed_origins": [public, admin]},
            "email": {"provider": "smtp", "from": os.environ.get("COMMA_SMTP_FROM", "comma@localhost"),
                      "smtp": {"host": smtp_host, "port": int(os.environ.get("COMMA_SMTP_PORT", "1025")),
                               "username": os.environ.get("COMMA_SMTP_USERNAME", ""),
                               "password": os.environ.get("COMMA_SMTP_PASSWORD", ""),
                               "tls": os.environ.get("COMMA_SMTP_TLS", "never" if smtp_host == "mailpit" else "always"),
                               "ssl": os.environ.get("COMMA_SMTP_SSL", "false") == "true"}}},
    "clickhouse": {"url": "http://clickhouse:8123", "table": "salix_analytics.events"},
    "subscription_proxy": {"storage_key": keys["subscription"]},
    "search": {"exa_api_key": os.environ.get("COMMA_EXA_API_KEY", "")},
    "llm": {"default_template": {
        "template_id": "selfhost-default", "name": "Instance default",
        "model": os.environ.get("COMMA_LLM_MODEL", "gpt-4.1"),
        "max_tokens": int(os.environ.get("COMMA_LLM_MAX_TOKENS", "8192")),
        "context_tokens": int(os.environ.get("COMMA_LLM_CONTEXT_TOKENS", "128000")),
        "provider_config": {"protocol": os.environ.get("COMMA_LLM_PROTOCOL", "chat_completions"),
                            "base_url": os.environ.get("COMMA_LLM_BASE_URL", "https://api.openai.com/v1"),
                            "api_key": os.environ.get("COMMA_LLM_API_KEY", "")}}}
}
for name, value in {"config.json": json.dumps(config), "postgres-password": keys["postgres"],
                    "storage-password": keys["storage"], "release-cookie": keys["cookie"]}.items():
    temporary = root / (name + ".tmp")
    temporary.write_text(value)
    temporary.replace(root / name)
for path in root.iterdir():
    os.chown(path, 10001, 10001)
# PostgreSQL drops privileges before it reads POSTGRES_PASSWORD_FILE.
(root / "postgres-password").chmod(0o644)
print("Instance configuration is ready. Existing secrets were preserved.")
