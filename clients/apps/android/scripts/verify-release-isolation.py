#!/usr/bin/env python3
"""Verify APK definitions against original R8 names, plus bundled fixture PNGs,
the debug-only composer, task and media demos and settings developer section, and ASR credential
isolation (internal requires opt-in)."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile
from internal_build import properties

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'Lsurf/comma/android/'
COMPOSER_DEMO = PREFIX + 'ui/composer/demo/ComposerDemoActivity;'
DEVELOPER_PAGE = PREFIX + 'settings/NetworkLogPage;'
ASR_FIELDS = ('DOUBAO_ASR_API_KEY', 'DOUBAO_ASR_RESOURCE_ID')
SIZES = [(640, 640), (960, 540), (540, 960), (1024, 256), (256, 1024)]


def local_asr_key():
    """The developer's local key, used only as a search needle. Never printed."""
    path = ROOT / 'local.properties'
    if not path.exists():
        return None
    return properties(path).get('DOUBAO_ASR_API_KEY', '').strip() or None


def descriptor(name):
    return 'L' + name.replace('.', '/') + ';'


class Mapping:
    """Preserve every original for merged classes and inlined method holders."""
    def __init__(self, text):
        self.classes = {}
        self.fields = {}
        self.origins = {}
        match = re.search(r'^# pg_map_id: (\S+)$', text, re.M)
        assert match, 'Missing R8 mapping ID'
        self.id = match[1]
        original = residual = None
        for line in text.splitlines():
            match = re.fullmatch(r'(\S+) -> (\S+):', line)
            if match:
                original, residual = map(descriptor, match.groups())
                self.classes[original] = residual
                self.origins.setdefault(residual, set()).add(original)
            elif residual and line.startswith('    ') and not line.lstrip().startswith('#'):
                # Qualified holders record code inlined/moved out of another class.
                method = re.search(r' ([\w.$]+)\.[^ .(]+(?:\(| ->)', line)
                if method:
                    self.origins[residual].add(descriptor(method[1]))
                field = re.fullmatch(r'    java.lang.String (\w+) -> (\S+)', line)
                if field:
                    self.fields[(original, field[1])] = field[2]
        assert self.classes, 'Empty R8 class mapping'

    def original_descriptors(self, residuals):
        return residuals | {name for residual in residuals
                            for name in self.origins.get(residual, ())}


def load_mapping(path, dex_bytes):
    assert path.is_file(), f'Required R8 mapping is missing: {path}'
    data = path.read_bytes()
    header = re.search(rb'^# pg_map_hash: SHA-256 ([0-9a-f]{64})\n', data, re.M)
    assert header, 'Missing R8 mapping hash'
    assert hashlib.sha256(data[header.end():]).hexdigest().encode() == header[1], 'R8 mapping is incomplete or modified'
    mapping = Mapping(data.decode('utf-8'))
    markers = [json.loads(value) for dex in dex_bytes
               for value in re.findall(rb'~~R8(\{[^\x00]+\})', dex)]
    assert markers and {marker.get('pg-map-id') for marker in markers} == {mapping.id}, 'R8 mapping does not match this APK'
    assert all(marker.get('r8-mode') == 'full' and marker.get('compilation-mode') == 'release'
               for marker in markers), 'APK must use R8 full mode with release optimization'
    return mapping


def class_header(path):
    """Read only the class/interface declaration from a pre-R8 JVM class file."""
    data = path.read_bytes()
    assert data[:4] == b'\xca\xfe\xba\xbe', f'Invalid JVM class: {path.name}'
    pool = {}
    offset, index = 10, 1
    count = struct.unpack_from('>H', data, 8)[0]
    while index < count:
        tag = data[offset]
        offset += 1
        if tag == 1:
            size = struct.unpack_from('>H', data, offset)[0]
            offset += 2
            pool[index] = data[offset:offset + size].decode('utf-8', errors='replace')
            offset += size
        elif tag == 7:
            pool[index] = struct.unpack_from('>H', data, offset)[0]
            offset += 2
        else:
            sizes = {3: 4, 4: 4, 5: 8, 6: 8, 8: 2, 9: 4, 10: 4, 11: 4,
                     12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
            assert tag in sizes, f'Unknown JVM constant tag: {tag}'
            offset += sizes[tag]
            if tag in (5, 6):
                index += 1
        index += 1
    flags, this, _, count = struct.unpack_from('>HHHH', data, offset)
    interfaces = struct.unpack_from('>' + 'H' * count, data, offset + 8)
    return flags, pool[pool[this]], {pool[pool[item]] for item in interfaces}


def compiled_classes(mapping_path):
    variant = mapping_path.parent.name
    task = 'compile' + variant[0].upper() + variant[1:] + 'Kotlin'
    return ROOT / 'app/build/intermediates/built_in_kotlinc' / variant / task / 'classes'


def verify_removed_class(name, mapping_path):
    assert mapping_path is not None, f'Missing {name}'
    removed = mapping_path.with_name('usage.txt').read_text().splitlines()
    assert name.replace('/', '.') in removed, f'Missing removal evidence for {name}'
    header = class_header(compiled_classes(mapping_path) / (name + '.class'))
    assert header[1] == name, f'Missing compiled {name}'
    return header


def verify_task_contract(descriptors, mapping_path):
    interface = PREFIX + 'tasks/TaskRepository;'
    if interface in descriptors:
        return
    # A fully devirtualized interface has no DEX definition or mapping. Require proof
    # of its removal and the compiled implementation relationship, not a keep rule.
    name = 'surf/comma/android/tasks/TaskRepository'
    flags, _, _ = verify_removed_class(name, mapping_path)
    assert flags & 0x0200, 'Missing compiled TaskRepository interface'
    _, actual, interfaces = class_header(compiled_classes(mapping_path) / 'surf/comma/android/tasks/data/ServerTaskRepository.class')
    assert actual == 'surf/comma/android/tasks/data/ServerTaskRepository' and name in interfaces, 'Server repository lost its task contract'


def build_config_values(dump, mapping=None):
    original = PREFIX + 'BuildConfig;'
    target = mapping.classes.get(original) if mapping else original
    assert target, 'BuildConfig not mapped'
    block = re.search(r"Class descriptor\s*:\s*'" + re.escape(target) + r"'(.*?)(?:Class #|\Z)",
                      dump, re.S)
    assert block, 'BuildConfig not found'
    fields = {name: value for name, value in
              re.findall(r"name\s*:\s*'(\w+)'\n\s*type\s*:\s*'Ljava/lang/String;'\n[^\n]*\n"
                         r"\s*value\s*:\s*\"([^\"]*)\"", block.group(1))}
    if not mapping:
        return fields
    return {name: fields[residual] for (holder, name), residual in mapping.fields.items()
            if holder == original and residual in fields}


def inspect(apk, dexdump, fixtures, debug, internal=False, allow_internal_asr=False, mapping_path=None):
    descriptors = set()
    dumps = []
    dex_bytes = []
    with tempfile.TemporaryDirectory(prefix='comma-dex-') as directory, zipfile.ZipFile(apk) as archive:
        dex_files = [name for name in archive.namelist() if re.fullmatch(r'classes\d*\.dex', name)]
        assert dex_files, f'No DEX in {apk}'
        for name in dex_files:
            path = Path(directory) / name
            dex_bytes.append(archive.read(name))
            path.write_bytes(dex_bytes[-1])
            # DEX strings use modified UTF-8. Match ASCII class-descriptor records as bytes.
            result = subprocess.run([str(dexdump), str(path)], check=True, capture_output=True)
            dumps.append(result.stdout.decode('utf-8', errors='replace'))
            descriptors.update(value.decode('utf-8', errors='replace') for value in
                               re.findall(rb"Class descriptor\s*:\s*'([^']+)'", result.stdout))
        assert descriptors, 'dexdump returned no class descriptors'
        mapping = None
        if not debug:
            assert mapping_path is not None, 'An optimized APK requires mapping.txt'
            mapping = load_mapping(mapping_path, dex_bytes)
            descriptors = mapping.original_descriptors(descriptors)
        telemetry = sorted(value for value in descriptors if 'FrameTelemetry' in value)
        fixture_classes = sorted(value for value in descriptors if value.startswith(PREFIX + 'fixture/'))
        metrics = sorted(value for value in descriptors if value.startswith('Landroidx/metrics/'))
        # aapt2 shortens paths in benchmark/release even when R8 is off; use the resource table.
        resources = subprocess.run([str(dexdump.with_name('aapt2')), 'dump', 'resources', str(apk)],
                                   check=True, capture_output=True, text=True).stdout
        images = sorted(re.findall(r'resource \S+ drawable/(fixture_image_\d+)\s+'
                                   r'\(nodpi\) \(file\) (\S+) type=PNG', resources))
        if fixtures:
            assert PREFIX + 'performance/FrameTelemetry;' in telemetry, 'Missing positive telemetry control'
            assert PREFIX + 'fixture/FixtureConversationSource;' in fixture_classes
            assert metrics, 'Missing JankStats dependency in measured APK'
            assert len(images) == 25, f'Expected 25 bundled images, found {len(images)}'
            for index, (_, name) in enumerate(images):
                png = archive.read(name)
                assert png[:8] == b'\x89PNG\r\n\x1a\n'
                assert struct.unpack('>II', png[16:24]) == SIZES[index % 5], name
        else:
            assert not telemetry, f'FrameTelemetry leaked into release: {telemetry}'
            assert not fixture_classes, f'Fixture classes leaked into release: {fixture_classes}'
            assert not metrics, 'JankStats dependency leaked into release'
            assert not images, 'Fixture images leaked into release'
        assert not any(value.startswith('Lcom/example/chat/') for value in descriptors)
        # The composer demo lives in the debug source set only.
        has_demo = COMPOSER_DEMO in descriptors
        assert has_demo == debug, f'ComposerDemoActivity present={has_demo}, expected {debug}'
        # The task demo and its fixture repository live in the debug source set only.
        demo_classes = sorted(value for value in descriptors if value.startswith(PREFIX + 'tasks/demo/'))
        if debug:
            assert PREFIX + 'tasks/demo/TasksDemoActivity;' in demo_classes, 'Missing task demo'
            assert PREFIX + 'tasks/demo/FixtureTaskRepository;' in demo_classes, 'Missing task fixture'
        else:
            assert not demo_classes, f'Task demo leaked: {demo_classes}'
        verify_task_contract(descriptors, mapping_path)
        assert PREFIX + 'tasks/data/ServerTaskRepository;' in descriptors, 'Missing server task repository'
        assert PREFIX + 'tasks/data/TaskGraph;' in descriptors, 'Missing task data entry point'
        # The media demo and its sample videos live in the debug source set only; the real
        # viewer, player, file card and sign-in adapter ship everywhere.
        media_demo = sorted(value for value in descriptors if value.startswith(PREFIX + 'media/demo/'))
        if debug:
            assert PREFIX + 'media/demo/MediaDemoActivity;' in media_demo, 'Missing media demo'
        else:
            assert not media_demo, f'Media demo leaked: {media_demo}'
        for name in ('media/AuthMediaHttp;', 'media/MediaGraph;', 'media/viewer/ImageViewerActivity;',
                     'media/video/VideoPlayerActivity;', 'media/file/FileCardView;', 'media/file/MediaFileProvider;',
                     'chat/live/ChatImageDraft;', 'chat/live/AttachmentView;'):
            if name == 'chat/live/ChatImageDraft;' and fixtures and not debug and PREFIX + name not in descriptors:
                # Benchmark always opens fixtures, making live image drafts unreachable.
                verify_removed_class((PREFIX + name)[1:-1], mapping_path)
            else:
                assert PREFIX + name in descriptors, f'Missing {name}'
        for name in ('ui/ImagePreviewActivity;', 'chat/render/CoreMediaClient;',
                     'chat/render/CoreMediaLoader;', 'chat/render/ChatImageStore;'):
            assert PREFIX + name not in descriptors, f'Retired media path still shipped: {name}'
        demo_videos = [name for name in archive.namelist() if 'media_demo_' in name]
        demo_video_resources = re.findall(r'raw/media_demo_\w+', resources)
        assert bool(demo_videos or demo_video_resources) == debug, f'Media demo samples present={demo_videos}, expected {debug}'
        # The settings' developer section (backend, build, session, network log) is debug-only.
        has_developer = DEVELOPER_PAGE in descriptors
        assert has_developer == debug, f'Settings developer page present={has_developer}, expected {debug}'
        developer_strings = re.findall(r'resource \S+ string/(settings_developer\w*)', resources)
        assert bool(developer_strings) == debug, f'Settings developer strings present={developer_strings}, expected {debug}'
        manifest = subprocess.run([str(dexdump.with_name('aapt2')), 'dump', 'xmltree', '--file',
                                   'AndroidManifest.xml', str(apk)],
                                  check=True, capture_output=True, text=True).stdout
        assert ('TasksDemoActivity' in manifest) == debug, 'Task demo manifest entry mismatch'
        assert ('MediaDemoActivity' in manifest) == debug, 'Media demo manifest entry mismatch'
        assert 'ImagePreviewActivity' not in manifest, 'Retired viewer still registered'
        assert 'ImageViewerActivity' in manifest and 'MediaFileProvider' in manifest, 'Missing media manifest entries'
        assert ('ComposerDemoActivity' in manifest) == debug, 'Composer demo manifest entry mismatch'
        badging = subprocess.run([str(dexdump.with_name('aapt2')), 'dump', 'badging', str(apk)],
                                 check=True, capture_output=True, text=True).stdout
        assert ('application-debuggable' in badging) == debug, 'APK debuggable flag mismatch'
        if internal:
            assert badging.startswith("package: name='surf.comma.android.staging' "), 'Internal application ID mismatch'
            assert 'profileable' not in manifest, 'Internal APK must not enable profiling'
        # ASR credentials are permitted only in debug or explicitly opted-in internal builds.
        config = build_config_values(''.join(dumps), mapping)
        asr_configured = all(config.get(field) for field in ASR_FIELDS)
        if internal:
            assert config.get('BACKEND_BASE_URL') == 'https://salix-staging.cue.surf', 'Internal backend mismatch'
            assert config.get('BUILD_TYPE') == 'internal', 'Internal build type mismatch'
        allow_asr = debug or (internal and allow_internal_asr)
        if not allow_asr:
            for field in ASR_FIELDS:
                assert config.get(field) == '', f'{field} is not empty in {apk.name}'
        key = local_asr_key()
        key_in_apk = bool(key) and any(key.encode() in archive.read(name) for name in archive.namelist())
        if not allow_asr:
            assert not key_in_apk, f'The local ASR key leaked into {apk.name}'
        return dict(apk=str(apk.relative_to(ROOT)), dex_files=len(dex_files),
                    classes=len(descriptors), mapping_id=mapping.id if mapping else None,
                    frame_telemetry_classes=len(telemetry),
                    fixture_classes=len(fixture_classes), metrics_classes=len(metrics),
                    fixture_pngs=len(images), composer_demo=has_demo, task_demo_classes=len(demo_classes),
                    media_demo_classes=len(media_demo), settings_developer=has_developer,
                    asr_configured=asr_configured, asr_key_bytes_in_apk=key_in_apk, result='PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dexdump', type=Path, required=True)
    parser.add_argument('--skip-benchmark', action='store_true',
                        help='Skip devBenchmark when only the debug and release APKs were built.')
    parser.add_argument('--all-variants', action='store_true',
                        help='Also check devRelease, stagingRelease and prodDebug after assemble.')
    parser.add_argument('--internal-only', action='store_true',
                        help='Check only stagingInternal; used by build-internal.sh.')
    parser.add_argument('--include-internal', action='store_true',
                        help='Require stagingInternal alongside the original regression matrix.')
    parser.add_argument('--variant', action='append', default=[],
                        help='Check only this variant (flavor/buildType, e.g. prod/release); repeatable. '
                             'For a CI job that built only some of the APKs.')
    parser.add_argument('--allow-internal-asr', action='store_true',
                        help='Allow credentials only in internal when it was built with explicit ASR opt-in.')
    args = parser.parse_args()
    variants = [('prod/release/app-prod-release-unsigned.apk', False, False),
                ('dev/debug/app-dev-debug.apk', True, True),
                ('staging/debug/app-staging-debug.apk', True, True),
                ('dev/benchmark/app-dev-benchmark.apk', True, False)]
    internal_variant = ('staging/internal/app-staging-internal.apk', False, False)
    if args.all_variants:
        variants += [('dev/release/app-dev-release-unsigned.apk', False, False),
                     ('staging/release/app-staging-release-unsigned.apk', False, False),
                     ('prod/debug/app-prod-debug.apk', True, True)]
    if args.internal_only:
        variants = [internal_variant]
    elif args.include_internal or (ROOT / 'app/build/outputs/apk' / internal_variant[0]).exists():
        variants.append(internal_variant)
    for variant, fixtures, debug in variants:
        if args.skip_benchmark and 'benchmark' in variant:
            continue
        flavor, build_type, _ = variant.split('/')
        if args.variant and f'{flavor}/{build_type}' not in args.variant:
            continue
        mapping_path = ROOT / 'app/build/outputs/mapping' / (flavor + build_type.title()) / 'mapping.txt'
        print(json.dumps(inspect(ROOT / 'app/build/outputs/apk' / variant, args.dexdump, fixtures, debug,
                                 internal=variant == internal_variant[0],
                                 allow_internal_asr=args.allow_internal_asr, mapping_path=mapping_path)))


if __name__ == '__main__':
    main()
