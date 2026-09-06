import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from import_folder_job import import_folder
from mtag.organize import plan, apply, target_folder

class ImportFilingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lib = self.root/'library'; self.lib.mkdir()
        self.src = self.root/'pack'; self.src.mkdir()
        (self.src/'hit.wav').write_bytes(b'audio')
        (self.src/'.ts').mkdir()
        (self.src/'.ts'/'hit.wav.json').write_text('{"musicTaggerKind":"sfx"}')
    def copy(self, **kw):
        return import_folder(self.src,self.lib,carry_cache=False,**kw)
    def test_copy_sidecar_source_and_repeat(self):
        dest=self.copy(effects=True)
        self.assertEqual(dest.parent,self.lib/'SFX'/'Unsorted')
        self.assertEqual((dest/'hit.wav').read_bytes(),b'audio')
        self.assertTrue((dest/'.ts'/'hit.wav.json').exists())
        self.assertTrue((self.src/'hit.wav').exists())
        self.assertEqual(self.copy(effects=True),dest)
    def test_collision_preserves_existing(self):
        dest=self.copy()
        (self.src/'hit.wav').write_bytes(b'changed audio')
        second=self.copy()
        self.assertNotEqual(dest,second)
        self.assertEqual((dest/'hit.wav').read_bytes(),b'audio')
    def test_internal_and_ancestor(self):
        self.assertEqual(import_folder(self.lib,self.lib),self.lib)
        with self.assertRaises(ValueError): import_folder(self.root,self.lib)
    def test_failed_copy_not_published(self):
        with patch('import_folder_job.shutil.copy2',side_effect=OSError('full disk')):
            with self.assertRaises(OSError): self.copy()
        self.assertEqual(list((self.lib/'Untagged').iterdir()),[])
        self.assertEqual(list((self.lib/'.music-tagger-imports').iterdir()),[])
        self.assertTrue((self.src/'hit.wav').exists())
    def test_filing_sfx_and_sidecar_collision(self):
        entry=plan(self.src/'hit.wav',self.lib,'SFX/Impacts')
        dest=Path(entry['dst'])
        (dest.parent/'.ts').mkdir(parents=True)
        (dest.parent/'.ts'/'hit.wav.json').write_text('existing')
        self.assertEqual(plan(self.src/'hit.wav',self.lib,'SFX/Impacts')['status'],'collision')
        self.assertFalse(apply(entry)['moved'])
        self.assertTrue((self.src/'hit.wav').exists())
    def test_categories_cannot_escape(self):
        with self.assertRaises(ValueError): target_folder(self.lib,'SFX/../../outside')
        self.assertEqual(target_folder(self.lib,'Untagged'),self.lib/'Untagged')

if __name__=='__main__': unittest.main()
