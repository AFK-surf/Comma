#!/usr/bin/env python3
"""Resolve one TestFlight release and reconcile Apple's upload on retry."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


BACKENDS = {
    "staging": "https://salix-staging.comma.surf",
    "production": "https://salix.comma.surf",
}
PAGE_LIMIT = 200
MAX_PAGES = 10
VERSION_BUMPS = ("none", "patch", "minor", "major")


class ReleaseError(Exception):
    pass


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise ReleaseError(f"Missing required environment variable: {name}")
    return value


def version_parts(value):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ReleaseError("Version must contain two or three numeric components")
    parts = tuple(int(part) for part in value.split("."))
    return parts if len(parts) == 3 else (*parts, 0)


def normalize_version(value):
    return ".".join(map(str, version_parts(value)))


def asc(*args, timeout=120):
    try:
        result = subprocess.run(["asc", *args, "--output", "json"],
                                capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ReleaseError(f"asc {' '.join(args[:3])} exceeded its time budget") from error
    if result.returncode:
        # ASC errors contain status and API diagnostics. Never print auth env values.
        raise ReleaseError(result.stderr.strip() or f"asc {args[0]} failed")
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise ReleaseError(f"asc {args[0]} returned invalid JSON") from error


def data(document):
    value = document.get("data", [])
    return value if isinstance(value, list) else [value]


def pages(*args):
    response = asc(*args, "--limit", str(PAGE_LIMIT))
    result = []
    for page in range(MAX_PAGES):
        result.extend(data(response))
        next_url = response.get("links", {}).get("next")
        if not next_url:
            return result
        if page == MAX_PAGES - 1:
            raise ReleaseError("ASC query exceeded 2,000 records")
        response = asc(*args, "--limit", str(PAGE_LIMIT), "--next", next_url)
    return result


def context_path():
    return Path(env("IOS_RELEASE_CONTEXT"))


def load_context():
    return json.loads(context_path().read_text())


def save_context(context):
    path = context_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(context, indent=2) + "\n")
    temporary.replace(path)


def outputs(values):
    target = os.environ.get("GITHUB_OUTPUT")
    if not target:
        return
    with open(target, "a") as file:
        for name, value in values.items():
            if isinstance(value, bool):
                value = str(value).lower()
            value = str(value)
            if "\n" in value or "\r" in value:
                raise ReleaseError(f"Invalid multiline output: {name}")
            file.write(f"{name}={value}\n")


def github(path):
    url = f"{env('GITHUB_API_URL', 'https://api.github.com')}/repos/{env('GITHUB_REPOSITORY')}/{path}"
    request = Request(url, headers={"Accept": "application/vnd.github+json",
                                    "Authorization": f"Bearer {env('GITHUB_TOKEN')}"})
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise ReleaseError(f"GitHub API request failed with HTTP {error.code}") from error


def trusted_commit(ref):
    # Signing credentials are present while the selected source builds, so only
    # main or a tag on main may run. Tags alone are not trusted: anyone with
    # write access can point one at an unreviewed commit.
    if ref == "main":
        commit = github("commits/heads/main")
        sha = commit and commit.get("sha")
    else:
        if not re.fullmatch(r"[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*", ref) or ".." in ref:
            raise ReleaseError("Source must be main or a tag name")
        found = github(f"git/ref/tags/{quote(ref)}")
        target = found.get("object") if isinstance(found, dict) else None
        while target and target.get("type") == "tag":
            target = (github(f"git/tags/{target['sha']}") or {}).get("object")
        sha = target.get("sha") if target and target.get("type") == "commit" else None
    if not sha:
        raise ReleaseError("Source must be main or an existing tag")
    return require_on_main(sha)


def require_on_main(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError("Source must resolve to a full commit SHA")
    # Compare against the branch's SHA: a bare "main" could also name a tag.
    head = (github("commits/heads/main") or {}).get("sha")
    if not head or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ReleaseError("Could not resolve the main branch")
    comparison = github(f"compare/{head}...{sha}")
    if not comparison or comparison.get("status") not in ("identical", "behind"):
        raise ReleaseError("Source commit must already be on main")
    return sha


def source_ref():
    if context_path().exists():
        ref = require_on_main(load_context()["source_sha"])
    else:
        ref = trusted_commit(env("IOS_SOURCE_REF", "main").strip())
    outputs({"source_ref": ref})


def internal_group(app):
    name = env("IOS_TESTFLIGHT_GROUP", "Internal Testers")
    groups = pages("testflight", "groups", "list", "--app", app, "--internal")
    matches = [group for group in groups
               if group.get("id") == name or group.get("attributes", {}).get("name") == name]
    if len(matches) != 1:
        raise ReleaseError(f"Expected one internal TestFlight group named {name}")
    return matches[0]["id"]


def project_version(source):
    spec = (source / "clients/apps/apple/project.yml").read_text()
    marketing = re.search(r'^\s+MARKETING_VERSION:\s*[\"\x27]?([\d.]+)', spec, re.MULTILINE)
    build = re.search(r'^\s+CURRENT_PROJECT_VERSION:\s*[\"\x27]?(\d+)', spec, re.MULTILINE)
    if not marketing or not build:
        raise ReleaseError("Selected project has no marketing version or build number")
    return normalize_version(marketing[1]), int(build[1])


def latest_version(app, fallback):
    versions = pages("testflight", "pre-release", "list", "--app", app, "--platform", "IOS")
    uploaded = asc("builds", "uploads", "list", "--app", app, "--platform", "IOS",
                   "--sort", "-uploadedDate", "--limit", "200")
    candidates = [record.get("attributes", {}).get("version") for record in versions]
    candidates.extend(record.get("attributes", {}).get("cfBundleShortVersionString")
                      for record in data(uploaded))
    # The selected project's version is a floor, so a project bump is not ignored.
    base = max([version_parts(fallback), *(version_parts(value) for value in candidates if value)])
    return ".".join(map(str, base))


def bump_version(value, bump):
    parts = list(version_parts(value))
    if bump != "none":
        index = {"major": 0, "minor": 1, "patch": 2}[bump]
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
    return ".".join(map(str, parts))


def resolve():
    app = env("ASC_APP_ID")
    group_id = internal_group(app)
    source = Path(env("APPLE_SOURCE_DIR"))
    sha = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if context_path().exists():
        context = load_context()
        if context["app_id"] != app or context["source_sha"] != sha:
            raise ReleaseError("Restored release does not match the selected app and frozen source")
        if context["group_id"] != group_id:
            raise ReleaseError("The frozen internal tester group is no longer configured")
    else:
        backend = env("IOS_BACKEND", "staging")
        if backend not in BACKENDS:
            raise ReleaseError("Backend must be staging or production")
        fallback, initial_build = project_version(source)
        bump = os.environ.get("IOS_VERSION_BUMP", "").strip() or "none"
        if bump not in VERSION_BUMPS:
            raise ReleaseError("Version bump must be none, patch, minor, or major")
        resume = os.environ.get("IOS_RESUME_BUILD_ID", "").strip()
        context = {"app_id": app, "group_id": group_id, "source_ref": env("IOS_SOURCE_REF", "main"),
                   "source_sha": sha, "backend": backend, "api_base_url": BACKENDS[backend],
                   "test_notes": os.environ.get("IOS_TEST_NOTES", ""), "upload_started": False,
                   "resume_build_id": resume, "status": "prepared"}
        if resume:
            if bump != "none":
                raise ReleaseError("Version bump must be none when resuming an existing build")
            related_app = asc("builds", "app", "view", "--build-id", resume)
            if data(related_app)[0]["id"] != app:
                raise ReleaseError("Resume build belongs to another App Store Connect app")
            record = data(asc("builds", "info", "--build-id", resume))[0]
            version_record = data(asc("builds", "pre-release-version", "view", "--build-id", resume))[0]
            if version_record["attributes"].get("platform") != "IOS":
                raise ReleaseError("Resume build must be an iOS build")
            context["version"] = version_record["attributes"]["version"]
            context["build_number"] = record["attributes"]["version"]
            # Apple's build metadata cannot prove which source or backend produced it.
            context["origin"] = "existing build; source and backend are not verified"
        else:
            context["version"] = bump_version(latest_version(app, fallback), bump)
            next_build = asc("builds", "next-build-number", "--app", app, "--platform", "IOS",
                             "--initial-build-number", str(initial_build + 1))
            value = next_build.get("nextBuildNumber")
            if value is None or not re.fullmatch(r"[1-9]\d*", str(value)):
                raise ReleaseError("ASC did not return a positive next build number")
            context["build_number"] = str(value)
    save_context(context)
    outputs({name: context[name] for name in ("source_sha", "version", "build_number", "backend",
                                             "api_base_url", "resume_build_id", "group_id")})
    outputs({"needs_build": not context["upload_started"] and not context["resume_build_id"]})
    if context.get("origin"):
        print(f"TestFlight {context['version']} ({context['build_number']}): {context['origin']}")
    else:
        print(f"TestFlight {context['version']} ({context['build_number']}), backend {context['backend']}")


def prepare_publish():
    context = load_context()
    needed = not context["upload_started"] and not context["resume_build_id"]
    if needed:
        if not (Path(env("IOS_RELEASE_DIR")) / "Comma.ipa").is_file():
            raise ReleaseError("Signed Comma.ipa is unavailable")
        if exact_build(context) or pending_uploads(context):
            raise ReleaseError("Frozen version and build number are already in use by an Apple build or upload; start a new release")
        context["upload_started"] = True
        context["upload_attempt"] = int(env("GITHUB_RUN_ATTEMPT", "1"))
        context["status"] = "upload outcome pending"
        save_context(context)
    outputs({"upload_marker_needed": needed})


def exact_build(context):
    matches = data(asc("builds", "list", "--app", context["app_id"], "--platform", "IOS",
                       "--version", context["version"], "--build-number", context["build_number"],
                       "--limit", "2"))
    if len(matches) > 1:
        raise ReleaseError("Apple returned multiple builds for the frozen version and build number")
    return matches[0]["id"] if matches else None


def pending_uploads(context):
    return data(asc("builds", "uploads", "list", "--app", context["app_id"], "--platform", "IOS",
                    "--cf-bundle-short-version", context["version"],
                    "--cf-bundle-version", context["build_number"], "--limit", "2"))


def publish():
    context = load_context()
    build_id = context["resume_build_id"]
    attempt = int(env("GITHUB_RUN_ATTEMPT", "1"))
    if not build_id:
        if not context["upload_started"] or context.get("upload_attempt") is None:
            raise ReleaseError("Upload intent has not been recorded; run prepare-publish before publish")
        if context["upload_attempt"] == attempt:
            # The persisted marker precedes this attempt's one actual IPA upload.
            try:
                asc("builds", "upload", "--app", context["app_id"],
                    "--ipa", str(Path(env("IOS_RELEASE_DIR")) / "Comma.ipa"), timeout=1500)
            except ReleaseError:
                context["status"] = "upload outcome unknown; retry reconciles this build"
                save_context(context)
                raise
        else:
            context["origin"] = ("retry reconciliation matches only the Apple app/platform/version/build tuple; "
                                 "source and backend are not independently verified")
            save_context(context)
    if not build_id:
        deadline = time.monotonic() + int(env("IOS_DISCOVERY_TIMEOUT_SECONDS", "1200"))
        while True:
            build_id = exact_build(context)
            if build_id:
                break
            if time.monotonic() >= deadline:
                context["status"] = "upload outcome unresolved"
                save_context(context)
                raise ReleaseError("Apple has not exposed this build. Retry to reconcile it, or use resume_build_id "
                                   "when it appears. If the earlier attempt stopped before its upload began, "
                                   "start a new release")
            time.sleep(30)
    context["build_id"] = build_id
    context["status"] = "processing"
    save_context(context)
    try:
        asc("builds", "wait", "--build-id", build_id, "--timeout", "20m", "--poll-interval", "30s",
            "--fail-on-invalid", timeout=1260)
    except ReleaseError:
        context["status"] = "processing failed or wait timed out; see the failed step"
        save_context(context)
        raise
    notes = context["test_notes"]
    arguments = ["publish", "testflight", "--app", context["app_id"], "--build", build_id,
                 "--group", context["group_id"], "--wait", "--timeout", "5m"]
    if notes:
        arguments += ["--test-notes", notes, "--locale", "en-US"]
    try:
        asc(*arguments, timeout=360)
    except ReleaseError:
        context["status"] = "internal distribution failed; see the failed step"
        save_context(context)
        raise
    context["status"] = "available to Internal Testers"
    save_context(context)
    print(f"TestFlight build {build_id} is available to Internal Testers")


def summary():
    if not context_path().exists():
        text = "TestFlight release did not resolve. See the failed step.\n"
    else:
        context = load_context()
        text = (f"### TestFlight {context['version']} ({context['build_number']})\n\n"
                f"- Status: {context['status']}\n"
                f"- App: {context['app_id']}\n"
                f"- Internal group: {context['group_id']}\n")
        if context.get("origin"):
            text += f"- Origin: {context['origin']}\n"
        else:
            text += (f"- Source: `{context['source_sha']}`\n"
                     f"- Backend: {context['backend']} ({context['api_base_url']})\n")
        if context.get("build_id"):
            text += f"- Apple build ID: {context['build_id']}\n"
        text += f"- [App Store Connect](https://appstoreconnect.apple.com/apps/{context['app_id']}/testflight)\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(text)
    else:
        print(text)


def main():
    commands = {"source-ref": source_ref, "resolve": resolve, "prepare-publish": prepare_publish,
                "publish": publish, "summary": summary}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise ReleaseError("Use source-ref, resolve, prepare-publish, publish, or summary")
    commands[sys.argv[1]]()


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"TestFlight release failed: {error}", file=sys.stderr)
        sys.exit(1)
