import importlib.util
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('privacy_audit', Path(__file__).resolve().parents[2]/'scripts/privacy_audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class PrivacyAuditTests(unittest.TestCase):
    def test_binary_paths_and_tokens_are_not_skipped(self):
        data = b'\0\0' + b'/Users/' + b'private-user/project' + b'\0' + b'ghp_' + b'x'*30
        self.assertIn('local-home', audit.findings_for_data(data, artifact=True))
        self.assertIn('credential', audit.findings_for_data(data, artifact=True))

    def test_public_identity_and_fixture_addresses(self):
        self.assertEqual(audit.findings_for_data(b'fixture@example.invalid owner@users.noreply.github.com'), [])
        self.assertEqual(audit.findings_for_data(b'/Users/' + b'runner/work/project'), [])
        self.assertIn('personal-email', audit.findings_for_data(b'person@' + b'private.invalid'))
        self.assertNotIn('personal-email', audit.findings_for_data(b'\0compressed@' + b'pixels.invalid'))

    def test_custom_markers_are_reported_without_values(self):
        self.assertEqual(audit.findings_for_data(b'marker-123', deny=[b'marker-123']), ['private-marker'])

    def test_upstream_review_does_not_hide_new_or_user_markers(self):
        example = b'/home/' + b'upstream-example'
        review = {('local-home', hashlib.sha256(example).hexdigest())}
        self.assertEqual(audit.findings_for_data(example, artifact=True, reviewed=review), [])
        self.assertIn('local-home', audit.findings_for_data(example + b' /home/' + b'actual-user', artifact=True, reviewed=review))
        self.assertIn('private-marker', audit.findings_for_data(example, artifact=True, deny=[example], reviewed=review))

    def test_key_parser_labels_are_not_keys(self):
        header = b'-----BEGIN ' + b'PRIVATE KEY-----'
        self.assertNotIn('credential', audit.findings_for_data(header + b'\0'))
        self.assertIn('credential', audit.findings_for_data(header + b'\n' + b'A'*64))
        self.assertNotIn('credential', audit.findings_for_data(b'sk-' + b'ssh-ed25519-cert-v01'))
        self.assertIn('credential', audit.findings_for_data(b'sk-' + b'x'*30))

    def test_png_metadata_requires_review(self):
        data = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 0) + b'tEXt' + b'0000'
        self.assertEqual(audit.png_metadata(data), ['image-metadata'])

    def test_private_files_and_external_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'AGENTS.md').write_text('private notes')
            (root/'outside').symlink_to('/etc/hosts')
            (root/'safe.py').write_text('print("safe")')
            result = audit.scan_tree(root)
            self.assertEqual({item['category'] for item in result['findings']}, {'private-file','external-or-broken-symlink'})

    def test_public_ca_is_not_a_private_signing_key(self):
        self.assertFalse(audit.private_path(Path('Resources/certifi/cacert.pem'), artifact=True))
        self.assertTrue(audit.private_path(Path('Resources/signing.pem'), artifact=True))


if __name__ == '__main__':
    unittest.main()
