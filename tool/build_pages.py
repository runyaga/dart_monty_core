#!/usr/bin/env python3
"""Build the compiled Pages site offline with a preinstalled Dart SDK and pub cache.

--check-sources validates data, shells, links, versions and workflow without
compiling or writing site/. Plain mode resolves dependencies offline, compiles
both entry points with dart2js and dart2wasm and validates the assembled tree.
Browser execution and GitHub authorization require separate operator checks.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import tempfile
from html import escape
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / 'docs' / 'index.html'
WORKFLOW = ROOT / '.github' / 'workflows' / 'deploy-pages.yml'
PUBSPEC = ROOT / 'pubspec.yaml'
PIN = ROOT / 'tool' / 'upstream' / 'upstream-pin.json'
EXAMPLES = ROOT / 'example'
SITE = ROOT / 'site'

# Tokens substituted into the page shell. The shell carries no values of
# its own, so it cannot drift; a token the builder does not know, or a
# value the shell hardcodes, is a failure below.
PACKAGE_VERSION_TOKEN = '@dart_monty_core_version@'
UPSTREAM_VERSION_TOKEN = '@monty_version@'
EXAMPLE_COUNT_TOKEN = '@example_count@'
EXAMPLE_CARDS_TOKEN = '@example_cards@'

# The catalogue: the native example programs the page highlights, each
# with the run command and the local source copy its card carries. The
# descriptions are the programs' own contracts, as pinned by the expected
# output in test/integration/demos/*_test.dart.
CATALOGUE = [
    {
        'file': '15_host_module.dart',
        'title': '15 · host_module',
        'description': (
            'Hands Python one ExternalModule and walks every edge of its '
            'exposure boundary: import and dotted calls, the module id '
            'round trip, public attributes with private ones withheld, '
            'assignment to the module refused, the module itself not '
            'callable, missing and private attributes, unknown modules and '
            'submodules, forged names reaching nothing, a host exception '
            'raised by name, and hidden members never called. Prints one '
            'PASS line per check, then DEMO OK host_module.'
        ),
    },
    {
        'file': '16_step_debugger.dart',
        'title': '16 · step_debugger',
        'description': (
            'Runs a short script one step at a time and inspects every '
            'step event the debugger surfaces: value steps (kind, name, '
            'bytes, slice, and a UTF-16 off-by-one), call steps (function '
            'and argument), a pending step, and the completing step with '
            'its output. Prints one PASS line per check, then DEMO OK '
            'step_debugger.'
        ),
    },
    {
        'file': '17_restore_limits.dart',
        'title': '17 · restore_limits',
        'description': (
            'Dumps a session under each resource policy -- recursion '
            'depth, suspension count, memory, feed deadline, turn '
            'deadline, sleep budget and GC interval -- at the main, '
            'omitted, looser and tighter settings, then restores every '
            'dump, from an idle worker and from a snapshot, and shows the '
            'restored job keeps the stricter limits. Prints one PASS line '
            'per check plus OBS dump/restore/carry observations, then '
            'DEMO OK restore_limits.'
        ),
    },
    {
        'file': '18_durable_agent.dart',
        'title': '18 · durable_agent',
        'description': (
            'A durable agent that survives a host restart: search fan-out '
            'over module stubs, parking at an approval, the worker '
            'released, the host restarted, the worker restarted, the '
            'approval restored, the journal played back with effects '
            'applied exactly once, a restored tool error, a matching final '
            'report, and the dump limit retained against a loose-limit '
            'control. Prints one PASS line per check, then DEMO OK '
            'durable_agent.'
        ),
    },
]

REQUIRED_EXAMPLES = (
    '15_host_module.dart',
    '16_step_debugger.dart',
    '17_restore_limits.dart',
    '18_durable_agent.dart',
)

# A version literal in the shell would be a second place for versions to
# live; the builder is the only source.
VERSION_LITERAL = re.compile(r'\d+\.\d+\.\d+')

EXTERNAL_LINK = re.compile(r'^(?:[A-Za-z][A-Za-z0-9+.-]*:|//|#)')

# An HTML comment: nothing inside one reaches a visitor, so the page
# is read with every comment stripped and what remains is what the
# checks treat as shown. Plain string matching, deliberately simple:
# the check verifies honest edits, not tampering.
HTML_COMMENT = re.compile(r'<!--.*?-->', re.DOTALL)

# A link attribute in the page. Double or single quotes, either case:
# what the builder emits and what an honest hand edit uses.
LINK_ATTRIBUTE = re.compile(
    r'''(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')''', re.IGNORECASE
)

# How the workflow must execute this builder for a deploy: a `run:`
# command line that is exactly this literal -- the builder's plain
# mode, the only one that writes site/ to upload. Line matching,
# deliberately: anything else (a step that only mentions the builder,
# extra arguments such as --check, interpreter flags, or the command
# embedded in a larger shell line) is not the deploy's build step.
BUILDER_COMMAND = 'python3 -B tool/build_pages.py'


def fail(findings: list[str], message: str) -> None:
    findings.append(message)
    print(f'FAIL: {message}')


def read(path: Path, findings: list[str]) -> str:
    """Read one input, reporting a missing input as a failure."""
    try:
        return path.read_text(encoding='utf-8')
    except OSError as error:
        fail(findings, f'missing input {path.relative_to(ROOT)}: {error}')
        return ''


def package_version(findings: list[str]) -> str:
    """Derive the package version shown on the page from pubspec.yaml."""
    match = re.search(r'^version:\s*(\S+)', read(PUBSPEC, findings), re.M)
    if not match:
        fail(findings, 'pubspec.yaml: no top-level version: field')
        return ''
    return match.group(1)


def upstream_version(findings: list[str]) -> str:
    """Derive the monty version shown on the page from the upstream pin."""
    try:
        pin = json.loads(read(PIN, findings))
    except ValueError as error:
        fail(findings, f'{PIN.relative_to(ROOT)} is not JSON: {error}')
        return ''
    version = pin.get('version')
    if not version:
        fail(findings, f'{PIN.relative_to(ROOT)}: no upstream version')
        return ''
    return str(version)


def example_card(entry: dict[str, str]) -> str:
    """Render one catalogue entry as an HTML card.

    Every interpolated value is escaped: the page is assembled from
    repository files, and a name, path or description must not be able to
    inject markup.
    """
    name = entry['file']
    return '\n'.join([
        '      <article class="card">',
        '        <span class="card-badge badge-native">native example</span>',
        f'        <h2 class="card-title">{escape(entry["title"])}</h2>',
        f'        <p class="card-desc">{escape(entry["description"])}</p>',
        f'        <code class="card-cmd">dart run example/{escape(name)}</code>',
        '        <a class="card-src" href="examples/'
        f'{escape(name)}" download>Download {escape(name)}</a>',
        '      </article>',
    ])


def page_contents(html_text: str) -> tuple[set[str], str]:
    """The page's link targets (fragment stripped) and its shown text.

    The page is read as text, not with an HTML parser: comments are
    stripped whole, so a link or a run command that lives only inside
    one counts as absent, and the href/src values of what remains are
    the page's links. That is plain string matching, deliberately so:
    the check verifies honest edits, not tampering, and an honest page
    quotes its attributes -- anything stranger is out of scope.
    """
    shown = HTML_COMMENT.sub('', html_text)
    links: set[str] = set()
    for match in LINK_ATTRIBUTE.finditer(shown):
        value = match.group(1) if match.group(1) is not None else match.group(2)
        links.add(value.split('#', 1)[0].strip())
    return links, shown


def substitute(shell: str, token: str, value: str, findings: list[str]) -> str:
    """Replace exactly one occurrence of [token]; anything else is a drift."""
    if shell.count(token) != 1:
        fail(findings, f'docs/index.html: expected exactly one {token}')
        return shell
    return shell.replace(token, value)


def build(out_dir: Path) -> tuple[str, list[str]]:
    """Assemble the site into [out_dir]; return the page and its findings."""
    findings: list[str] = []
    shell = read(PAGE, findings)

    for literal in VERSION_LITERAL.findall(shell):
        fail(
            findings,
            f'docs/index.html: hardcoded version {literal!r} -- the builder '
            'derives every version shown on the page',
        )

    package = package_version(findings)
    upstream = upstream_version(findings)

    # Every catalogue entry's source must exist in the repository; the
    # page links to a local copy, so a missing source is a missing input.
    sources: dict[str, Path] = {}
    for entry in CATALOGUE:
        source = EXAMPLES / entry['file']
        if source.is_file():
            sources[entry['file']] = source
        else:
            fail(findings, f'missing input {source.relative_to(ROOT)}')
    listed = {entry['file'] for entry in CATALOGUE}
    for name in REQUIRED_EXAMPLES:
        if name not in listed:
            fail(findings, f'the catalogue no longer highlights {name}')
    if findings:
        return '', findings

    page = shell
    page = substitute(page, PACKAGE_VERSION_TOKEN, escape(package), findings)
    page = substitute(page, UPSTREAM_VERSION_TOKEN, escape(upstream), findings)
    count = len([path for path in EXAMPLES.glob('*.dart') if path.is_file()])
    page = substitute(page, EXAMPLE_COUNT_TOKEN, escape(str(count)), findings)
    cards = '\n'.join(example_card(entry) for entry in CATALOGUE)
    page = substitute(page, EXAMPLE_CARDS_TOKEN, cards, findings)
    if findings:
        return '', findings

    examples_dir = out_dir / 'examples'
    if examples_dir.exists():
        # Copies from an earlier build must not ship beside the new ones.
        shutil.rmtree(examples_dir)
    examples_dir.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(sources.items()):
        (examples_dir / name).write_bytes(source.read_bytes())
    (out_dir / 'index.html').write_text(page, encoding='utf-8')

    # Verify what was just built, from the page on disk, read as text
    # with its HTML comments stripped: a card that lives only inside
    # a comment is not on the page and must not count as present.
    written = (out_dir / 'index.html').read_text(encoding='utf-8')
    links, shown_text = page_contents(written)
    for value in sorted(links):
        if not value or EXTERNAL_LINK.match(value):
            continue
        target = PurePosixPath(value)
        if target.is_absolute() or '..' in target.parts:
            fail(findings, f'link escapes the site: {value}')
        elif not (out_dir / target).is_file() and not str(target).startswith('repl/'):
            fail(findings, f'broken local link: {value}')
    for entry in CATALOGUE:
        name = entry['file']
        copy = examples_dir / name
        if not copy.is_file() or copy.read_bytes() != sources[name].read_bytes():
            fail(findings, f'source copy drifted: examples/{name}')
        if f'examples/{name}' not in links:
            fail(
                findings,
                f'the page does not carry a link to the source copy of '
                f'{name}: examples/{name} must appear as a link outside '
                'an HTML comment',
            )
        if f'dart run example/{name}' not in shown_text:
            fail(
                findings,
                f'the page does not show the run command for {name} '
                'outside an HTML comment',
            )
    return page, findings


def _workflow_lines(text: str) -> list[str]:
    """The workflow's lines with YAML comments removed.

    A builder invocation or upload path that lives only in a comment
    deploys nothing, so the checks below read the workflow the way a
    runner would: without its comments.
    """
    lines: list[str] = []
    for line in text.splitlines():
        quote: str | None = None
        cut = len(line)
        for index, char in enumerate(line):
            if quote is not None:
                if char == quote:
                    quote = None
            elif char in ('"', "'"):
                quote = char
            elif char == '#' and (index == 0 or line[index - 1] in ' \t'):
                cut = index
                break
        lines.append(line[:cut])
    return lines


def _run_commands(lines: list[str]) -> list[str]:
    """The command text of every `run:` step, including block scalars."""
    commands: list[str] = []
    for index, line in enumerate(lines):
        match = re.match(r'\s*(?:-\s+)?run:\s*(.*)$', line)
        if not match:
            continue
        first = match.group(1).strip()
        if first not in ('|', '>', '|-', '>-', '|+', '>+'):
            if first:
                commands.append(first)
            continue
        indent = len(line) - len(line.lstrip())
        body: list[str] = []
        for follow in lines[index + 1:]:
            if not follow.strip():
                body.append('')
                continue
            if len(follow) - len(follow.lstrip()) <= indent:
                break
            body.append(follow.strip())
        command = '\n'.join(body).strip()
        if command:
            commands.append(command)
    return commands


def _upload_paths(lines: list[str]) -> list[list[str]]:
    """The `path:` values of every upload-pages-artifact step's block."""
    steps: list[list[str]] = []
    for index, line in enumerate(lines):
        if not re.match(
            r'\s*(?:-\s+)?uses:\s*actions/upload-pages-artifact@', line
        ):
            continue
        indent = len(line) - len(line.lstrip())
        paths: list[str] = []
        for follow in lines[index + 1:]:
            if not follow.strip():
                continue
            if len(follow) - len(follow.lstrip()) <= indent:
                break
            match = re.match(r'\s*path:\s*(.*?)\s*$', follow)
            if match:
                paths.append(match.group(1).strip('\"\''))
        steps.append(paths)
    return steps


def workflow_findings() -> list[str]:
    """Check that Pages deploys this builder's site and nothing else."""
    findings: list[str] = []
    try:
        text = WORKFLOW.read_text(encoding='utf-8')
    except OSError as error:
        fail(findings, f'missing input {WORKFLOW.relative_to(ROOT)}: {error}')
        return findings
    if not text.strip():
        # Present but empty reads as '' without any OSError, so read()
        # would report nothing: fail here instead of letting an empty
        # workflow skip the build-step and upload checks below.
        fail(findings, 'deploy-pages.yml is empty: nothing builds or uploads')
        return findings
    lines = _workflow_lines(text)

    # The deploy must really build: a `run:` step whose command line
    # is exactly the builder's plain invocation, the only mode that
    # writes site/. Line matching, by owner decision: the check
    # verifies honest edits, so anything short of that literal line --
    # a step that only mentions the builder, extra arguments such as
    # --check, interpreter flags, or the command embedded in a larger
    # shell line -- is simply not the build step and does not count.
    command_lines = [
        stripped
        for command in _run_commands(lines)
        for stripped in (line.strip() for line in command.splitlines())
        if stripped
    ]
    if BUILDER_COMMAND not in command_lines:
        fail(
            findings,
            'deploy-pages.yml does not run the builder as its build step: '
            'a `run:` command line must be exactly '
            f'`{BUILDER_COMMAND}`',
        )

    # The deploy must upload exactly the directory the builder writes.
    upload_steps = _upload_paths(lines)
    if not upload_steps:
        fail(
            findings,
            'deploy-pages.yml does not upload with '
            'actions/upload-pages-artifact',
        )
    for paths in upload_steps:
        if paths != ['site']:
            shown = paths[0] if paths else 'none'
            fail(
                findings,
                'deploy-pages.yml must upload exactly `path: site` with '
                f'actions/upload-pages-artifact, found path: {shown}',
            )
    for action in (
        'actions/checkout@',
        'actions/configure-pages@',
        'actions/upload-pages-artifact@',
        'actions/deploy-pages@',
    ):
        if not re.search(action + r'[0-9a-f]{40}', text):
            fail(findings, f'deploy-pages.yml lost its SHA-pinned {action[:-1]}')
    for key in ('workflow_dispatch:', 'permissions:', 'environment:', 'concurrency:'):
        if key not in text:
            fail(findings, f'deploy-pages.yml lost its {key[:-1]} block')
    if "if: github.ref == 'refs/heads/main'" not in text or 'needs: build' not in text:
        fail(findings, 'deployment must require the build and be restricted to main')
    if 'persist-credentials: false' not in text:
        fail(findings, 'checkout must disable persisted credentials')
    return findings


WEB = ROOT / 'packages/dart_monty_web/web'
SHELLS = ('index_js.html', 'index_wasm.html', 'matrix_js.html', 'matrix_wasm.html')


def assemble(out: Path, compile_code: bool) -> list[str]:
    import subprocess
    findings = []
    try:
        data = json.loads((WEB / 'examples.json').read_text())
        ids = set()
        for item in data:
            assert all(item.get(k) for k in ('id', 'title', 'description', 'source', 'setup', 'expected'))
            assert item['id'] not in ids
            ids.add(item['id'])
            assert item['setup'] in ('default', 'tools', 'files', 'typing')
            assert set(item['expected']) & {'result', 'error'}
        assert len(data) >= 7
    except (ValueError, AssertionError, KeyError, OSError) as e:
        fail(findings, f'invalid examples.json: {e}')
    _, native_findings = build(out)
    findings += native_findings
    repl = out / 'repl'
    repl.mkdir(parents=True, exist_ok=True)
    for name in (*SHELLS, 'pages.css', 'examples.json', 'bootstrap.mjs', 'coi-serviceworker.js'):
        text = read(WEB / name, findings)
        if name in SHELLS:
            if 'bridge' in text or "bootstrap('" not in text:
                fail(findings, f'{name}: missing COI bootstrap or obsolete bridge')
            for token in (PACKAGE_VERSION_TOKEN, UPSTREAM_VERSION_TOKEN):
                if text.count(token) != 1: fail(findings, f'{name}: missing version token {token}')
            text = text.replace(PACKAGE_VERSION_TOKEN, package_version(findings)).replace(UPSTREAM_VERSION_TOKEN, upstream_version(findings))
        (repl / name).write_text(text)
    assets = repl / 'packages/dart_monty_core/assets'
    assets.mkdir(parents=True, exist_ok=True)
    for ext in ('js', 'wasm'):
        shutil.copy2(ROOT / f'lib/assets/dart_monty_core_worker.{ext}', assets)
    if compile_code and not findings:
        import os
        env = dict(os.environ)
        if (ROOT / '.cache/pub').is_dir():
            env.setdefault('PUB_CACHE', str(ROOT / '.cache/pub'))
        for directory in (ROOT, WEB.parent):
            subprocess.run(['dart', '--suppress-analytics', 'pub', 'get', '--offline'], cwd=directory, env=env, check=True)
        for entry in ('repl_demo', 'feature_matrix'):
            for compiler, ext, flags in [('js', 'js', ['-O2', '--no-source-maps']), ('wasm', 'wasm', [])]:
                subprocess.run(['dart', '--suppress-analytics', 'compile', compiler, *flags, f'web/{entry}.dart', '-o', str(repl / f'{entry}.{ext}')], cwd=WEB.parent, env=env, check=True)
        for entry in ('repl_demo', 'feature_matrix'):
            for ext in ('js', 'wasm', 'mjs'):
                if not (repl / f'{entry}.{ext}').is_file(): fail(findings, f'missing compiler artifact {entry}.{ext}')
    for page in (out / 'index.html', *(repl / name for name in SHELLS)):
        text = page.read_text()
        if re.search(r'@[a-z_]+@', text): fail(findings, f'unsubstituted token in {page.name}')
        links, _ = page_contents(text)
        for link in links:
            if not link or EXTERNAL_LINK.match(link): continue
            target = (page.parent / link).resolve()
            if not target.is_relative_to(out.resolve()) or not target.is_file():
                fail(findings, f'broken or escaping local link: {page.name}: {link}')
    return findings


def main(argv: list[str]) -> int:
    if argv not in ([], ['--check-sources']):
        print('usage: python3 -B tool/build_pages.py [--check-sources]')
        return 2
    if argv:
        with tempfile.TemporaryDirectory() as temp:
            findings = assemble(Path(temp) / 'site', False)
    else:
        if SITE.exists(): shutil.rmtree(SITE)
        findings = assemble(SITE, True)
    findings += workflow_findings()
    if findings: return 1
    print('OK: Pages sources, examples, shells, local links, versions and workflow verified.')
    if not argv: print('OK: site/ compiled with dart2js and dart2wasm; worker assets and runtime companions assembled.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
