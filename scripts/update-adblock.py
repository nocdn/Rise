import json,re,hashlib,pathlib,shutil,subprocess,tempfile,datetime,platform
root=pathlib.Path(__file__).resolve().parents[1]
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
 raise SystemExit('The pinned AdGuard converter requires an Apple Silicon Mac.')
workspace=tempfile.TemporaryDirectory(prefix='rise-blocking-');work=pathlib.Path(workspace.name)
def download(url, target):
 subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','2','--max-time','120',url,'-o',str(target)],check=True)
tool=work/'ConverterTool'
download('https://github.com/AdguardTeam/SafariConverterLib/releases/download/v4.3.0/ConverterTool',tool)
if hashlib.sha256(tool.read_bytes()).hexdigest() != '6687be9f1a77abd5299299086c5fbffd0d1b5baec755eb4808aa2f53e275d3c0':
 raise SystemExit('Converter checksum mismatch.')
tool.chmod(0o755)
# The upstream release executable needs its Swift PSL resource bundle alongside it.
psl=work/'swift-psl_PublicSuffixList.bundle';psl.mkdir()
for file in ['common.bin','asterisk.bin','negated.bin','version.txt']:
 download('https://raw.githubusercontent.com/ameshkov/swift-psl/7ccee9d576d4ca45219440e346f61117f44c816f/Sources/PublicSuffixList/Resources/'+file,psl/file)
for name,url in [('easylist','https://easylist.to/easylist/easylist.txt'),('easyprivacy','https://easylist.to/easylist/easyprivacy.txt'),('hagezi-mini','https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.mini.txt')]:
 download(url,work/(name+'.txt'))
 if name!='hagezi-mini':
  subprocess.run([str(tool),'convert','--safari-version','17.0','--input-path',str(work/(name+'.txt')),'--safari-rules-json-path',str(work/(name+'.json'))],check=True)

out=root/'Sources/Rise/Resources/Blocking';out.mkdir(parents=True,exist_ok=True)
source=root/'Filters/Sources';source.mkdir(parents=True,exist_ok=True)
for name in ['easylist.txt','easyprivacy.txt','hagezi-mini.txt']: shutil.copyfile(work/name,source/name)
# Reduce redundant subdomains; all domains are from the general HaGeZi list.
hosts={l[2:-1] for l in (work/'hagezi-mini.txt').read_text().splitlines() if re.fullmatch(r'\|\|[a-z0-9.-]+\^',l)}
hosts=sorted(h for h in hosts if not any('.'.join(h.split('.')[i:]) in hosts for i in range(1,len(h.split('.'))-1)))
rules=[]
for host in hosts:
 rules.append({'trigger':{'url-filter':r'^https?://([a-z0-9-]+\.)*'+re.escape(host)+r'[:/]','resource-type':['image','style-sheet','script','font','media','svg-document','raw','popup']},'action':{'type':'block'}})
network_count=len(rules)
supplement=[
 {'trigger':{'url-filter':r'/ads(\.min)?\.js([?].*)?$','resource-type':['script'],'unless-domain':['*localhost','*127.0.0.1']},'action':{'type':'block'}},
 {'trigger':{'url-filter':r'/pagead(\.min)?\.js([?].*)?$','resource-type':['script'],'unless-domain':['*localhost','*127.0.0.1']},'action':{'type':'block'}},
 {'trigger':{'url-filter':r'[./_-]ads[./_-]banner[./_-]'},'action':{'type':'block'}},
 {'trigger':{'url-filter':r'[./_-]ad[./_-]banner[./_-]'},'action':{'type':'block'}},
 {'trigger':{'url-filter':'.*','unless-domain':['*localhost','*127.0.0.1']},'action':{'type':'css-display-none','selector':'.textads, .adsbox, .banner_ads, .banner-ads, .afs_ads, .ad-zone, .ad-space, .ad-banner, .ad_banner, .ad-unit, img[src*="ads_banner"], object[data*="ads_banner"]'}}
]
# Each source keeps its own exception scope. An EasyList allow rule must not
# accidentally whitelist a tracker from the independent HaGeZi privacy list.
groups=[('hagezi',rules),('easylist',json.loads((work/'easylist.json').read_text())),('easyprivacy',json.loads((work/'easyprivacy.json').read_text())),('rise',supplement)]
parts=[]
for old in out.glob('rules-*.json'):old.unlink()
for label, group in groups:
 positions=[i for i,r in enumerate(group) if r['action']['type']!='ignore-previous-rules']
 for n,start in enumerate(range(0,len(positions),40000)):
  keep=set(positions[start:start+40000]);part=[r for i,r in enumerate(group) if i in keep or r['action']['type']=='ignore-previous-rules']
  data=json.dumps(part,separators=(',',':'),ensure_ascii=False).encode()
  name=f'rules-{label}-{n+1}.json';(out/name).write_bytes(data)
  parts.append({'file':name,'sha256':hashlib.sha256(data).hexdigest(),'rules':len(part)})
manifest={'format':1,'generated':datetime.datetime.now(datetime.timezone.utc).date().isoformat(),'converter':'AdGuard SafariConverterLib 4.3.0 (Safari 17 syntax)','lists':parts,'hostDomains':len(hosts),'sources':[{'file':name,'sha256':hashlib.sha256((source/name).read_bytes()).hexdigest()} for name in ['easylist.txt','easyprivacy.txt','hagezi-mini.txt']]}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Domain rules:',network_count,'domains',len(hosts));print('Native lists:',parts)
workspace.cleanup()
