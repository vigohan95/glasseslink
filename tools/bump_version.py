import io, re, sys

ver = sys.argv[1]
p = 'ios/project.yml'
s = io.open(p, encoding='utf-8').read()
s = re.sub(r'CFBundleShortVersionString: "[^"]*"', 'CFBundleShortVersionString: "%s"' % ver, s)
s = re.sub(r'CFBundleVersion: "[^"]*"', 'CFBundleVersion: "%s"' % ver.split('.')[-1], s)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(ver)
