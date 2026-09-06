import contextlib
import io
import json
import math
import tempfile
import unittest
import wave
from pathlib import Path
import struct
from sfx_split_job import regions, plan, apply

class SplitTests(unittest.TestCase):
    def test_regions(self):
        self.assertEqual(regions(3, [(0,3)]), [])
        self.assertEqual(regions(3, []), [[0,3]])
        self.assertEqual(len(regions(3, [(1,2)])), 2)
    def test_real_audio_and_preservation(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'effects.wav'
            with wave.open(str(p),'wb') as w:
                w.setparams((1,2,8000,0,'NONE','not compressed'))
                w.writeframes(b''.join(struct.pack('<h', int(15000*math.sin(i*.4)) if (4000<i<8000 or 12000<i<16000) else 0) for i in range(20000)))
            original=p.read_bytes()
            (p.parent/'.ts').mkdir()
            (p.parent/'.ts'/(p.name+'.json')).write_text(json.dumps({'tags':[{'title':'Impact'}], 'description':'keep me','musicTaggerMarkers':[{'at':.7,'name':'hit'}]}))
            data=plan(p)
            self.assertEqual(len(data['clips']),2)
            with contextlib.redirect_stdout(io.StringIO()):
                out=apply(data)
                other=apply(data)
            self.assertNotEqual(out,other)
            self.assertEqual(len(list(out.glob('*.wav'))),2)
            self.assertEqual(p.read_bytes(),original)
            doc=json.loads(next((out/'.ts').glob('*.json')).read_text())
            self.assertEqual(doc['description'],'keep me')
            self.assertEqual(doc['tags'][0]['title'],'Impact')
            p.write_bytes(original+b'x')
            with self.assertRaisesRegex(RuntimeError,'Source changed'):
                apply(data)

if __name__=='__main__': unittest.main()
