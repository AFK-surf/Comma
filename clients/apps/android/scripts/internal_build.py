#!/usr/bin/env python3
"""Local-only internal APK packaging helpers. Never print signing settings or ASR keys."""
import argparse
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Local tags that record each distributed internal build; versionCode comes from version.properties.
TAG_PREFIX = 'android-internal/'
SIGNING_NAMES = ('COMMA_INTERNAL_KEY_ALIAS', 'COMMA_INTERNAL_STORE_PASSWORD',
                 'COMMA_INTERNAL_KEY_PASSWORD')


def properties(path):
    """Read Java .properties escapes, separators and continuation lines (Gradle uses Properties)."""
    if not path.exists():
        return {}

    def unescape(value):
        return re.sub(r'\\u([0-9a-fA-F]{4})|\\(.)', lambda m:
                      chr(int(m[1], 16)) if m[1] else
                      {'t': '\t', 'r': '\r', 'n': '\n', 'f': '\f'}.get(m[2], m[2]), value)

    result = {}
    pending = ''
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = pending + raw.lstrip(' \t\f')
        if not pending and (not line or line[0] in '#!'):
            continue
        trailing = len(line) - len(line.rstrip('\\'))
        if trailing % 2:
            pending = line[:-1]
            continue
        pending = ''
        match = re.match(r'((?:\\.|[^\\:= \t\f])*)(?:[ \t\f]*[:=][ \t\f]*|[ \t\f]+)?(.*)', line)
        result[unescape(match[1])] = unescape(match[2])
    if pending:
        raise ValueError('Incomplete continuation in local.properties')
    return result


def settings():
    local = properties(ROOT / 'local.properties')
    return {**local, **{key: os.environ[key] for key in
                      ('COMMA_INTERNAL_KEYSTORE', *SIGNING_NAMES) if key in os.environ}}


def keystore_path(config):
    value = config.get('COMMA_INTERNAL_KEYSTORE') or '~/.comma-android/internal.keystore'
    path = Path(value).expanduser()
    return path if path.is_absolute() else ROOT / path


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def repository_root():
    """The whole Git checkout that contains this project, not just the Android directory."""
    result = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=ROOT,
                            capture_output=True, text=True)
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else ROOT


def outside_repository(path):
    path = path.resolve()
    for root in {ROOT, repository_root()}:
        if path == root or root in path.parents:
            raise ValueError('The internal keystore must be outside the Git repository.')


def require_signing():
    config = settings()
    path = keystore_path(config)
    outside_repository(path)
    if not path.is_file() or any(not config.get(name, '').strip() for name in SIGNING_NAMES):
        raise ValueError('Internal signing is not configured. Run scripts/create-internal-keystore.sh; '
                         'save the password in a password manager, then set COMMA_INTERNAL_KEY_ALIAS, '
                         'COMMA_INTERNAL_STORE_PASSWORD and COMMA_INTERNAL_KEY_PASSWORD in the '
                         'environment or local.properties. COMMA_INTERNAL_KEYSTORE optionally overrides '
                         'the default external keystore. There is no debug-key fallback.')


def create_keystore():
    config = settings()
    target = keystore_path(config)
    outside_repository(target)
    if target.exists() or target.is_symlink():
        raise ValueError('Keystore already exists; refusing to overwrite it.')
    keytool = shutil.which('keytool')
    if not keytool:
        raise ValueError('keytool is required; install a JDK and add its bin directory to PATH.')
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Also reject paths in another checkout, including linked Git worktrees.
    probe = subprocess.run(['git', '-C', str(target.parent), 'rev-parse', '--show-toplevel'],
                           capture_output=True)
    if probe.returncode == 0:
        raise ValueError('The internal keystore must be outside all Git repositories.')
    password = secrets.token_urlsafe(32)
    env = dict(os.environ, COMMA_GENERATED_KEY_PASSWORD=password)
    today = date.today()
    try:
        expiry = today.replace(year=today.year + 25)
    except ValueError:
        expiry = today.replace(year=today.year + 25, day=28)
    # Generate beside the target, then atomically link without ever replacing an existing key.
    with tempfile.TemporaryDirectory(prefix='.comma-key-', dir=target.parent) as directory:
        temporary = Path(directory) / 'internal.keystore'
        result = subprocess.run([
            keytool, '-genkeypair', '-noprompt', '-storetype', 'JKS',
            '-keystore', str(temporary), '-alias', config.get('COMMA_INTERNAL_KEY_ALIAS') or 'comma-internal',
            '-storepass:env', 'COMMA_GENERATED_KEY_PASSWORD',
            '-keypass:env', 'COMMA_GENERATED_KEY_PASSWORD',
            '-keyalg', 'RSA', '-keysize', '4096', '-validity', str((expiry - today).days),
            '-dname', 'CN=comma Internal, OU=Internal Testing, O=comma',
        ], env=env, capture_output=True)
        if result.returncode:
            raise ValueError('keytool failed; check the JDK and keystore configuration. '
                             'Output is suppressed to protect signing settings.')
        temporary.chmod(0o600)
        os.link(temporary, target)
    print('内部签名 key 已生成。下面的随机密码仅显示一次；请立即保存到密码管理器。')
    print('COMMA_INTERNAL_STORE_PASSWORD 和 COMMA_INTERNAL_KEY_PASSWORD 使用同一个密码：')
    print(password)
    print('请按 README 配置签名，并安全备份 keystore；后续覆盖安装必须复用此 key。')


def sdk_tools():
    local = properties(ROOT / 'local.properties')
    sdk = local.get('sdk.dir') or os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    candidates = [Path(sdk).expanduser()] if sdk else [Path.home() / 'Library/Android/sdk',
                                                     Path.home() / 'Android/Sdk']
    versions = [folder for base in candidates for folder in (base / 'build-tools').glob('*')
                if re.fullmatch(r'\d+\.\d+\.\d+', folder.name)
                and all((folder / tool).is_file() for tool in ('dexdump', 'aapt2', 'apksigner'))]
    if not versions:
        raise ValueError('Android SDK build-tools (dexdump, aapt2, apksigner) are required. '
                         'Set sdk.dir in local.properties or ANDROID_HOME.')
    return max(versions, key=lambda folder: tuple(map(int, folder.name.split('.'))))


def app_version():
    """versionCode and versionName from version.properties, the single version source."""
    config = properties(ROOT / 'version.properties')
    code, name = config.get('versionCode', ''), config.get('versionName', '').strip()
    if not re.fullmatch(r'[1-9]\d*', code) or not name:
        raise ValueError('version.properties needs a positive integer versionCode and a versionName.')
    return int(code), name


def version():
    if git('rev-parse', '--is-shallow-repository') == 'true':
        raise ValueError('A complete Git history is required for the changelog; use a full local checkout.')
    head = git('rev-parse', 'HEAD')
    code, base = app_version()
    # Only this Android project counts; changes elsewhere in the repository do not.
    dirty = bool(git('status', '--porcelain', '--untracked-files=normal', '--', '.'))
    name = f"{base}-{git('rev-parse', '--short', 'HEAD')}" + ('-dirty' if dirty else '')
    return head, code, name, dirty


def previous_tag(head, code):
    # Only earlier tags reachable from this commit can describe this build's ancestry.
    tags = git('tag', '--merged', head, '--list', f'{TAG_PREFIX}*').splitlines()
    number = lambda tag: int(tag[len(TAG_PREFIX):])
    candidates = [tag for tag in tags if re.fullmatch(re.escape(TAG_PREFIX) + r'\d+', tag)
                  and number(tag) < code]
    return max(candidates, key=number, default=None)


def changelog_subjects(revision_range):
    # Only commits that touch this Android project belong in its changelog.
    return git('log', '--reverse', '--format=%s', revision_range, '--', '.')


def latest_tag_code():
    """The highest versionCode any local internal tag records, on any branch."""
    tags = git('tag', '--list', f'{TAG_PREFIX}*').splitlines()
    codes = [int(tag[len(TAG_PREFIX):]) for tag in tags
             if re.fullmatch(re.escape(TAG_PREFIX) + r'\d+', tag)]
    return max(codes, default=None)


def build(asr):
    require_signing()
    build_tools = sdk_tools()
    before = version()
    head, code, name, dirty = before
    tag = f'{TAG_PREFIX}{code}'
    existing = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'],
                              cwd=ROOT, capture_output=True, text=True)
    if existing.returncode == 0 and existing.stdout.strip() != head:
        raise ValueError('This internal versionCode already tags a different commit. '
                         'Increase versionCode in version.properties; existing internal tags are never moved.')
    newest = latest_tag_code()
    if newest is not None and newest > code:
        raise ValueError(f'versionCode {code} is lower than an earlier internal build ({newest}). '
                         'Increase versionCode in version.properties.')
    subprocess.run([*shlex.split(os.environ.get('COMMA_GRADLE_COMMAND', './gradlew --max-workers=2')),
                    ':app:assembleStagingInternal',
                    f'-Pcomma.internal.asr={str(asr).lower()}'], cwd=ROOT, check=True)
    output = ROOT / 'app/build/outputs/apk/staging/internal'
    metadata = json.loads((output / 'output-metadata.json').read_text())
    elements = metadata['elements']
    if (metadata['applicationId'] != 'surf.comma.android.staging' or len(elements) != 1
            or elements[0]['versionCode'] != code or elements[0]['versionName'] != name):
        raise ValueError('APK metadata does not match version.properties and the Git revision.')
    if version() != before:
        raise ValueError('Git state changed during the build. Retry before distributing this APK.')
    apk = output / elements[0]['outputFile']
    # Signature verification and isolation both gate publication to dist and the local tag.
    result = subprocess.run([str(build_tools / 'apksigner'), 'verify', str(apk)], capture_output=True)
    if result.returncode:
        raise ValueError('APK signature verification failed; no distribution files or tag were created.')
    print('APK signature: PASS', flush=True)
    command = [sys.executable, 'scripts/verify-release-isolation.py', '--dexdump',
               str(build_tools / 'dexdump'), '--internal-only']
    if asr:
        command.append('--allow-internal-asr')
    subprocess.run(command, cwd=ROOT, check=True)
    mapping = ROOT / 'app/build/outputs/mapping/stagingInternal/mapping.txt'
    if not mapping.is_file() or mapping.stat().st_size == 0:
        raise ValueError('R8 mapping.txt is required; no distribution files or tag were created.')
    previous = previous_tag(head, code)
    revision_range = f'{previous}..{head}' if previous else head
    subjects = changelog_subjects(revision_range)
    changelog = (f'comma staging {name}\nVersion code: {code}\nCommit: {head}\n'
                 f'Previous internal tag: {previous or "none (first internal build)"}\n'
                 f'ASR: {"explicitly enabled" if asr else "disabled"}\n\n{subjects}\n')
    if dirty:
        changelog += '\nWARNING: This APK includes uncommitted changes; the tag records HEAD only.\n'
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    filename = f'comma-staging-{name}.apk'
    # Stage the complete bundle before replacing published files.
    with tempfile.TemporaryDirectory(prefix='.internal-', dir=dist) as directory:
        staging = Path(directory)
        shutil.copyfile(apk, staging / filename)
        shutil.copyfile(mapping, staging / f'comma-staging-{name}-mapping.txt')
        digest = hashlib.sha256()
        with (staging / filename).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        (staging / f'{filename}.sha256').write_text(f'{digest.hexdigest()}  {filename}\n')
        (staging / 'CHANGELOG.txt').write_text(changelog)
        for file in staging.iterdir():
            os.replace(file, dist / file.name)
    if existing.returncode != 0:
        subprocess.run(['git', 'tag', '--no-sign', tag, head], cwd=ROOT, check=True)
    print(f'dist/{filename}\ndist/{filename}.sha256\ndist/comma-staging-{name}-mapping.txt'
          f'\ndist/CHANGELOG.txt\nLocal tag: {tag}')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('create-keystore')
    package = commands.add_parser('build')
    package.add_argument('-Pcomma.internal.asr', dest='asr', choices=('true', 'false'), default='false')
    args = parser.parse_args()
    try:
        if args.command == 'create-keystore':
            create_keystore()
        else:
            build(args.asr == 'true')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Subprocess/OSError messages can contain signing paths or settings; keep those private.
        message = str(error) if isinstance(error, ValueError) else 'Command or file operation failed; no secrets are logged.'
        print(f'ERROR: {message}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
