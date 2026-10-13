import sys,re
d=sys.stdin.buffer.read().decode('utf8','replace')
d=re.sub(r'\x1b\[[0-9;?<>=]*[ -/]*[@-~]','',d)
d=re.sub(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)','',d)
d=re.sub(r'\x1b[()][A-Z0-9]','',d)
d=d.replace('\r','')
d=re.sub(r'\n{3,}','\n\n',d)
print(d[-int(sys.argv[1]) if len(sys.argv)>1 else -3000:])
