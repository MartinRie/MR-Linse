import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import publish_release as release

class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dist = Path(self.temp.name)
        for name in release.FILES:
            (self.dist / name).write_bytes(b'test-artifact')

    def test_new_release_targets_exact_commit_and_all_files(self):
        with patch.object(release, 'api', return_value=None), patch.object(release, 'gh') as gh:
            release.publish('0.3.0', 'sha', self.dist)
            args = gh.call_args.args
            self.assertEqual(args[:2], ('create', 'v0.3.0'))
            self.assertIn('sha', args)
            for name in release.FILES:
                self.assertIn(str(self.dist / name), args)

    def test_published_version_is_untouched(self):
        existing = {'draft': False, 'assets': [{'name': n, 'size': 1} for n in release.FILES]}
        with patch.object(release, 'api', return_value=existing), patch.object(release, 'gh') as gh:
            release.publish('0.3.0', 'different-commit', self.dist)
            gh.assert_not_called()

    def test_conflicting_tag_is_rejected(self):
        with patch.object(release, 'api', side_effect=[None, {'object': {'sha': 'old', 'type': 'commit'}}]), patch.object(release, 'gh') as gh:
            with self.assertRaises(ValueError): release.publish('0.3.0', 'new', self.dist)
            gh.assert_not_called()

    def test_resume_draft_uploads_before_publication(self):
        with patch.object(release, 'api', side_effect=[{'draft': True, 'target_commitish': 'sha'}, {'object': {'sha': 'sha', 'type': 'commit'}}]), patch.object(release, 'gh') as gh:
            release.publish('0.3.0', 'sha', self.dist)
            self.assertEqual([call.args[0] for call in gh.call_args_list], ['upload', 'edit'])

    def test_annotated_tag_is_resolved(self):
        with patch.object(release, 'api', side_effect=[None, {'object': {'type': 'tag', 'sha': 'tag-object'}}, {'object': {'type': 'commit', 'sha': 'sha'}}]), patch.object(release, 'gh') as gh:
            release.publish('0.3.0', 'sha', self.dist)
            self.assertEqual(gh.call_args.args[0], 'create')

    def test_missing_file_never_publishes(self):
        (self.dist / release.FILES[0]).unlink()
        with patch.object(release, 'gh') as gh:
            with self.assertRaises(ValueError): release.publish('0.3.0', 'sha', self.dist)
            gh.assert_not_called()

    def test_http_error_not_treated_as_absent_release(self):
        with patch.object(release, 'api', side_effect=RuntimeError('403')), patch.object(release, 'gh') as gh:
            with self.assertRaises(RuntimeError): release.publish('0.3.0', 'sha', self.dist)
            gh.assert_not_called()

if __name__ == '__main__': unittest.main()
