import importlib.util,json,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('migration',ROOT/'scripts/migrate_inspiration.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class MigrationTests(unittest.TestCase):
 def test_private_history_and_conflict(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);source=root/'source';source.mkdir();history=source/'LocalHistory';history.mkdir()
   record={'version':1,'entries':[{'id':'one','text':'私人中文记录','context':'原文','tag':'想法','createdAt':100,'additions':[{'id':'a','text':'补充','createdAt':101}],'archived':False}],'draft':{'text':'未提交草稿','tag':'草稿'},'selectedID':'one','supplementDrafts':{'one':'未提交补充'}}
   (source/'ideas-v1.json').write_text(json.dumps(record));(history/'.inspiration-local-history').write_text('Inspiration local history v1\n');(history/'灵感.md').write_text('历史里的私人文字')
   def git(*args):return subprocess.check_output(['/usr/bin/git','-C',str(history),'-c','user.name=Test','-c','user.email=test@localhost','-c','commit.gpgsign=false','-c','core.hooksPath=/dev/null',*args],stderr=subprocess.DEVNULL)
   git('init','--quiet','--template=');git('add','.');git('commit','--quiet','-m','first');head=git('rev-parse','HEAD')
   before=m.fingerprint(source);target=root/'target';result=m.migrate(source,target)
   self.assertTrue(result['historyPreserved']);self.assertEqual(before,m.fingerprint(source));self.assertEqual(record,json.loads((target/'ideas-v1.json').read_text()))
   self.assertEqual(head,subprocess.check_output(['/usr/bin/git','-C',str(target/'LocalHistory'),'rev-parse','HEAD']))
   self.assertEqual(0o700,target.stat().st_mode&0o777);self.assertEqual(0o600,(target/'ideas-v1.json').stat().st_mode&0o777)
   self.assertEqual('already-migrated',m.migrate(source,target)['status'])
   other=root/'other';other.mkdir();(other/'ideas-v1.json').write_text(json.dumps(record))
   with self.assertRaises(ValueError):m.migrate(source,other)
   self.assertEqual(record,json.loads((other/'ideas-v1.json').read_text()))
   bad=root/'bad';bad.mkdir();broken=dict(record);broken['entries']=[{'id':'bad','text':'missing fields'}];(bad/'ideas-v1.json').write_text(json.dumps(broken))
   with self.assertRaises(ValueError):m.migrate(bad,root/'must-not-create')
   self.assertFalse((root/'must-not-create').exists())
   (source/'escape').symlink_to(root)
   with self.assertRaises(ValueError):m.migrate(source,root/'unsafe')
   self.assertFalse((root/'unsafe').exists())
if __name__=='__main__':unittest.main()
