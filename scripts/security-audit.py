#!/usr/bin/env python3
"""Audit pinned dependencies, vendored integrity and publishable source; never scan user data."""
import argparse, hashlib, json, re, subprocess, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def request(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', 'User-Agent': 'Chatter-security-audit'})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)

def run(output, offline=False):
    packages = json.loads((ROOT / 'Vendor/dependencies.json').read_text())['packages']
    queries, names = [], []
    for package in packages:
        queries.append({'commit': package['revision']}); names.append(package['name'])
        if 'version' in package:
            # OSV's Swift identifiers conventionally omit the https scheme and .git suffix.
            name = package['url'].removeprefix('https://').removesuffix('.git')
            queries.append({'package': {'ecosystem': 'SwiftURL', 'name': name}, 'version': package['version']})
            names.append(package['name'] + ' version')
    # These native components are nested snapshots in MLX/Swift Crypto, not Swift packages.
    native = json.loads((ROOT / 'scripts/security-native-components.json').read_text())
    for package in native:
        queries.append({'commit': package['revision']}); names.append(package['name'])
    issues = []
    fmt = (ROOT/'Vendor/Packages/mlx-swift/Source/Cmlx/fmt/include/fmt/base.h').read_text()
    json_header = (ROOT/'Vendor/Packages/mlx-swift/Source/Cmlx/json/include/nlohmann/detail/abi_macros.hpp').read_text()
    boring = (ROOT/'Vendor/Packages/swift-crypto/Sources/CCryptoBoringSSL/hash.txt').read_text()
    for component in native:
        if component['name'] == 'fmt':
            version = tuple(map(int, component['version'].split('.')))
            valid = '#define FMT_VERSION ' + str(version[0]*10000+version[1]*100+version[2]) in fmt
        elif component['name'] == 'nlohmann-json': valid = 'version ' + component['version'] in json_header
        else: valid = component['revision'] in boring
        if not valid: issues.append({'type':'stale-native-inventory','component':component['name']})
    for line in (ROOT / 'Vendor/SHA256SUMS').read_text().splitlines():
        expected, path = line.split('  ', 1)
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != expected:
            issues.append({'type': 'vendored-integrity', 'path': path})
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    credential = re.compile(rb'(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-proj-[A-Za-z0-9_-]{40,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
    for path in filter(None, tracked):
        p = Path(path)
        if path.startswith('Vendor/'): continue  # upstream cryptographic test keys are public fixtures
        if p.name in ('api-token', 'clients.json', 'voices.json', 'identity-key.bin') or p.suffix in ('.safetensors', '.gguf', '.p12'):
            issues.append({'type': 'private-runtime-file', 'path': path})
        if p.suffix.lower() in ('.wav', '.mp3', '.m4a', '.flac', '.aac', '.aiff', '.caf', '.ogg', '.opus') and not path.startswith('Tests/ChatterAudioKitTests/Fixtures/'):
            issues.append({'type': 'unexpected-audio', 'path': path})
        if (ROOT / path).is_file() and credential.search((ROOT / path).read_bytes()):
            issues.append({'type': 'credential-pattern', 'path': path})
    results = [] if offline else request('https://api.osv.dev/v1/querybatch', {'queries': queries})['results']
    for name, result in zip(names, results):
        if result.get('next_page_token'): raise RuntimeError('Advisory results require pagination; audit is incomplete')
        for vulnerability in result.get('vulns', []): issues.append({'type': 'advisory', 'component': name, 'id': vulnerability['id']})
    sbom = {'bomFormat':'CycloneDX','specVersion':'1.5','version':1,'components':[
        {'type':'library','name':p['name'],'version':p.get('version',p['revision']),
         'externalReferences':[{'type':'vcs','url':p['url'] + '#' + p['revision']}]} for p in packages + native]}
    output.mkdir(parents=True, exist_ok=True)
    (output/'sbom.cdx.json').write_text(json.dumps(sbom, indent=2))
    report = {'advisoryQueries':len(results),'offline':offline,'issues':issues,'coverage':'Pinned source commits and Swift package identifiers; advisory coverage is not exhaustive.'}
    (output/'security-audit.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return bool(issues)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--output',type=Path,default=ROOT/'artifacts/security-audit');parser.add_argument('--offline',action='store_true')
    args=parser.parse_args(); raise SystemExit(run(args.output,args.offline))
