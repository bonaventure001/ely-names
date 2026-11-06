# Adds the .ely logo to the website: tab icon, header mark, and a social preview image.
# Run from the project folder (~/ely-names) after unzipping. Safe to run more than once.
import glob, os, re, shutil

ASSETS = ['favicon.ico', 'favicon-16x16.png', 'favicon-32x32.png', 'apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'logo-96.png', 'og-image.png']
os.makedirs('docs', exist_ok=True)
for a in ASSETS:
    shutil.copy(os.path.join('brand', a), os.path.join('docs', a))

ICONS = '''<link rel="icon" href="favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="favicon-32x32.png">
<link rel="icon" type="image/png" sizes="16x16" href="favicon-16x16.png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta name="theme-color" content="#04181C">
'''
SOCIAL = '''<meta property="og:type" content="website">
<meta property="og:site_name" content=".ely Names">
<meta property="og:title" content=".ely Names: your name on Elysium">
<meta property="og:description" content="Register a readable .ely name, link it to your wallet and own it as an NFT.">
<meta property="og:image" content="https://elysiumnameservice.xyz/og-image.png">
<meta property="og:url" content="https://elysiumnameservice.xyz/">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://elysiumnameservice.xyz/og-image.png">
'''
CSS = '.logo{display:inline-flex;align-items:center;gap:8px}.logo .mark{width:30px;height:30px;border-radius:8px;flex:none}\n'
LOGO = re.compile(r'(<(?:a|span)\s+class="logo"[^>]*>)(\.<span>ely</span>)')

files = sorted(set(glob.glob('docs/*.html') + glob.glob('frontend/*.html')))
for path in files:
    s = open(path, encoding='utf-8').read()
    changed = []
    if 'rel="icon"' not in s and '</head>' in s:
        extra = ICONS + (SOCIAL if os.path.basename(path) == 'index.html' and path.startswith('docs') else '')
        s = s.replace('</head>', extra + '</head>', 1); changed.append('tab icon')
    if 'class="mark"' not in s and LOGO.search(s):
        s = LOGO.sub(r'\1<img class="mark" src="logo-96.png" alt="" width="30" height="30">\2', s, count=1)
        s = s.replace('</style>', CSS + '</style>', 1); changed.append('header logo')
    if changed:
        open(path, 'w', encoding='utf-8').write(s)
    print(f"{path}: {', '.join(changed) if changed else 'already done'}")
print('Done. Commit and push to publish.')
