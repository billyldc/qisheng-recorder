#!/usr/bin/env python3
"""Keep one local code-signing identity across builds; never export its private key."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import secrets
import shutil
import subprocess
import tempfile

SERVICE = 'io.github.billyldc.QishengRecorder.signing'
IDENTIFIER = 'io.github.billyldc.QishengRecorder'
DIRECTORY = Path.home() / 'Library/Application Support/QishengRecorder/Signing'
CONFIG = DIRECTORY / 'identity.json'
KEYCHAIN = Path.home() / 'Library/Keychains/QishengRecorder-signing.keychain-db'


def run(*args, **kwargs):
    try:
        return subprocess.check_output(args, stderr=subprocess.PIPE, **kwargs)
    except subprocess.CalledProcessError as error:
        action = Path(args[0]).name + ' ' + (args[1] if len(args) > 1 else '')
        raise RuntimeError(action + ': ' + (error.stderr or b'').decode(errors='replace').strip()) from None


def password():
    return run('/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', 'codesign', '-w').decode().strip()


def setup():
    if CONFIG.exists():
        trust_for_signing()
        sign_test()
        return
    if KEYCHAIN.exists():
        raise RuntimeError('Signing keychain already exists without its identity configuration; restore the configuration before continuing.')
    openssl = '/opt/homebrew/opt/openssl@3/bin/openssl'
    if not Path(openssl).exists():
        openssl = shutil.which('openssl')
    secret = secrets.token_urlsafe(36)
    with tempfile.TemporaryDirectory(prefix='qisheng-signing-') as folder:
        root = Path(folder)
        config = root / 'certificate.cnf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=signing\n'
                          '[subject]\nCN=Qisheng Recorder Local Signing\n'
                          '[signing]\nbasicConstraints=critical,CA:TRUE\n'
                          'keyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=critical,codeSigning\n')
        env = dict(os.environ, QISHENG_P12_PASSWORD=secret)
        run(openssl, 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '7300',
            '-config', str(config), '-keyout', str(root / 'key.pem'), '-out', str(root / 'certificate.pem'))
        run(openssl, 'pkcs12', '-export', '-legacy', '-inkey', str(root / 'key.pem'), '-in', str(root / 'certificate.pem'),
            '-out', str(root / 'identity.p12'), '-passout', 'env:QISHENG_P12_PASSWORD', env=env)
        der = run(openssl, 'x509', '-in', str(root / 'certificate.pem'), '-outform', 'DER')
        identity = hashlib.sha1(der).hexdigest().upper()
        run('/usr/bin/security', 'add-generic-password', '-U', '-s', SERVICE, '-a', 'codesign', '-w', secret, '-T', '/usr/bin/security')
        run('/usr/bin/security', 'create-keychain', '-p', secret, str(KEYCHAIN))
        run('/usr/bin/security', 'set-keychain-settings', '-lut', '3600', str(KEYCHAIN))
        run('/usr/bin/security', 'import', str(root / 'identity.p12'), '-k', str(KEYCHAIN), '-P', secret, '-T', '/usr/bin/codesign')
        run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', secret, str(KEYCHAIN))
        DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
        (DIRECTORY / 'certificate.cer').write_bytes(der)
        CONFIG.write_text(json.dumps({'identity': identity, 'keychain': str(KEYCHAIN)}, indent=2))
        CONFIG.chmod(0o600)
    trust_for_signing()
    sign_test()


def trust_for_signing():
    run('/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
        '-a', '/usr/bin/codesign', '-k', str(KEYCHAIN), str(DIRECTORY / 'certificate.cer'))


def sign(app):
    config = json.loads(CONFIG.read_text())
    run('/usr/bin/security', 'unlock-keychain', '-p', password(), config['keychain'])
    # codesign searches this list for the certificate chain even with --keychain.
    keychains = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user').decode())
    if config['keychain'] not in keychains:
        run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *keychains, config['keychain'])
    requirement = f'designated => identifier "{IDENTIFIER}" and certificate leaf = H"{config["identity"]}"'
    run('/usr/bin/codesign', '--force', '--deep', '--sign', config['identity'], '--keychain', config['keychain'],
        '--requirements', '=' + requirement, str(app))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))


def sign_test():
    requirements = []
    with tempfile.TemporaryDirectory(prefix='qisheng-signature-test-') as folder:
        for version in ('1.0', '2.0'):
            app = Path(folder) / f'{version}.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            shutil.copy('/usr/bin/true', app / 'Contents/MacOS/QishengRecorder')
            with (app / 'Contents/Info.plist').open('wb') as handle:
                plistlib.dump({'CFBundleIdentifier': IDENTIFIER, 'CFBundleExecutable': 'QishengRecorder',
                              'CFBundleShortVersionString': version, 'CFBundlePackageType': 'APPL'}, handle)
            sign(app)
            result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)], capture_output=True, check=True)
            output = (result.stdout + result.stderr).decode()
            requirements.append(next(line for line in output.splitlines() if line.startswith('designated =>')))
        assert requirements[0] == requirements[1]
    print('PASS: two different versions share the same certificate-bound signing identity. TCC inheritance still needs an installed-app test.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup', 'sign', 'test'])
    parser.add_argument('app', nargs='?', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'setup':
            setup()
        elif args.command == 'test':
            sign_test()
        elif args.app:
            sign(args.app)
        else:
            parser.error('sign needs an application path')
    except RuntimeError as error:
        raise SystemExit(f'Signing operation failed: {error}')
