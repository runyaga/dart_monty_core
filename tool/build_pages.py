#!/usr/bin/env python3
"""Assemble the GitHub Pages site from repository files alone.

The site is a static catalogue of the package's downloadable native
examples: one page -- docs/index.html as the shell -- plus a copy of each
catalogue entry's Dart source under site/examples/, linked from the page.
Nothing is compiled, fetched or served from outside the repository: the
versions the page shows are read from pubspec.yaml and
tool/upstream/upstream-pin.json, so the page cannot advertise a version
the tree does not carry, and every local link resolves to a file the
builder copied out of example/.

Usage:
  python3 -B tool/build_pages.py          # assemble site/ at the repo root
  python3 -B tool/build_pages.py --check  # build into a temporary
                                          # directory and verify it

--check never writes site/: it assembles into a temporary directory
and verifies what it assembled (every local link on the page resolves
inside the site; every examples/ copy is byte-identical to its
repository source; examples 15-18 are all present, described and
linked), then re-reads the deployment workflow
(.github/workflows/deploy-pages.yml must run this builder as exactly
`python3 -B tool/build_pages.py` in a `run:` step -- the builder's
plain mode, the only one that writes site/ -- and upload exactly
`site/` with actions/upload-pages-artifact, with no leftover
in-browser-demo toolchain), then throws the site away. That proves
assembly and local links only: the Pages upload, the
OIDC/environment authorization and live serving need a real workflow
run and stay unverified until one.

Scope, by owner decision: the check verifies honest edits, not
tampering. Its reads of the page and of the workflow are string and
line matching -- a link counts when it appears in the assembled page
outside an HTML comment, and a build step counts when its command
line is exactly the literal above -- so crafted bypasses (links
wrapped in hidden or inert elements, shell punctuation or quoting
around the command, interpreter flags such as -c, -m or -V) are out
of scope and are not defended against.

Standard library only. Exit 0 on pass, 1 on any failure, 2 on bad usage.
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

# Residual references to the retired in-browser demo, looked for in the
# page shell and in the deployment workflow: its pages, its toolchains,
# its asset copies. Lowercase; the scans lowercase their text.
RETIRED_DEMO_STRINGS = (
    'repl',
    'dart2js',
    'dart2wasm',
    'setup-node',
    'setup-dart',
    'dart pub get',
    'dart compile',
    'dart_monty_web',
    'lib/assets',
    'coi-serviceworker',
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

    for retired in RETIRED_DEMO_STRINGS:
        if retired in shell.lower():
            fail(
                findings,
                f'docs/index.html: residual reference to the retired demo: '
                f'{retired!r}',
            )
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
        elif not (out_dir / target).is_file():
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
    for retired in RETIRED_DEMO_STRINGS:
        if retired in text.lower():
            fail(
                findings,
                f'deploy-pages.yml still builds the retired demo: {retired!r}',
            )
    return findings


def main(argv: list[str]) -> int:
    if not argv:
        _, findings = build(SITE)
        if findings:
            return 1
        print(
            'OK:   site/index.html assembled; '
            f'{len(CATALOGUE)} example sources copied under site/examples/.'
        )
        return 0
    if argv == ['--check']:
        with tempfile.TemporaryDirectory() as temporary:
            _, findings = build(Path(temporary) / 'site')
        findings += workflow_findings()
        if findings:
            print(f'FAIL: {len(findings)} problem(s); the site check did not pass.')
            return 1
        print(
            'OK:   site assembles from repository files; examples 15-18 '
            'present, described and linked.'
        )
        print('OK:   every local page link and source copy verified in a '
              'temporary build.')
        print('OK:   deploy-pages.yml builds with tool/build_pages.py and '
              'uploads site/.')
        print('NOTE: the Pages upload, OIDC authorization and live serving '
              'need a workflow run; not verified here.')
        return 0
    print(__doc__)
    print('usage: python3 -B tool/build_pages.py [--check]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
